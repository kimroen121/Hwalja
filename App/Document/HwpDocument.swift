import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let hwp = UTType(importedAs: "app.hwpstudio.hwp")
    static let hwpx = UTType(importedAs: "app.hwpstudio.hwpx")
    /// Our declarations plus whatever type another installed app (e.g. Hancom) owns
    /// for the same extensions, which the system may prefer over ours.
    static let hwpFamily: [UTType] = Array(Set([hwpx, hwp] + ["hwpx", "hwp"].flatMap {
        UTType.types(tag: $0, tagClass: .filenameExtension, conformingTo: nil)
    }))
}

/// One open HWP/HWPX document: the engine session plus the state views render.
/// Edits run one at a time in submission order; each sees the result of the previous one.
/// `pages` is patched in place with the pages each edit re-rendered.
@MainActor
final class HwpDocument: @preconcurrency ReferenceFileDocument {
    static let readableContentTypes = UTType.hwpFamily
    /// New documents are HWPX, like Hancom Office Web.
    static let writableContentTypes = [UTType.hwpx] + UTType.hwpFamily.filter { $0 != .hwpx }
    /// Undo depth kept by the engine (`HISTORY_LIMIT`).
    static let undoLimit = 20

    private let session: EditSession
    /// Rendered pages, shown and printed as is. Built on the main actor from the opening PDF.
    private(set) lazy var pages = PDFDocument(data: openingPDF) ?? PDFDocument()
    private let openingPDF: Data
    // Plain stored properties (not @Published) so the nonisolated file-reading init can set them.
    private(set) var reply: EditReply { willSet { objectWillChange.send() } }
    var selection: EditSelection? { willSet { objectWillChange.send() } }
    private var queue: Task<Void, Never>?
    /// Number of works ever queued; identifies the latest one.
    private var queued = 0
    /// The latest queued work while it is unstarted typing, with the text it will insert.
    private var typing: (work: Int, text: Typed)?
    private final class Typed { var text: String; init(_ text: String) { self.text = text } }

    nonisolated init() {
        // ponytail: blank-document failure is unrecoverable (engine bug), so it traps.
        let (session, output) = try! EditSession.open(nil)
        self.session = session
        openingPDF = output.pdf
        reply = output.reply
    }
    nonisolated convenience init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(data: data)
    }
    nonisolated init(data: Data) throws {
        let (session, output) = try EditSession.open(data)
        self.session = session
        openingPDF = output.pdf
        reply = output.reply
    }

    nonisolated func snapshot(contentType: UTType) throws -> Data {
        try session.export(contentType.preferredFilenameExtension == "hwp" ? .hwp : .hwpx)
    }
    nonisolated func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    var revision: UInt64 { reply.revision }

    /// Queues an edit built from the selection current when it runs. Successful edits
    /// become one undo step on `undoManager`; refused edits beep.
    func edit(_ undoManager: UndoManager?, _ make: @escaping @MainActor (EditSelection?) -> EditCommand?) {
        enqueue { document in
            guard let command = make(document.selection) else { return }
            try await document.run(command)
            document.registerHistory(.undo, undoManager)
        }
    }

    /// Replaces the selection with typed text. Keystrokes that arrive while earlier work is
    /// still running join one edit, so typing never falls behind the engine.
    func type(_ text: String, _ undoManager: UndoManager?) {
        if let typing, typing.work == queued {
            typing.text.text += text
            return
        }
        let typed = Typed(text)
        edit(undoManager) { [unowned self] selection in
            if typing?.text === typed { typing = nil }
            return selection.map { .replace($0, text: typed.text) }
        }
        typing = (queued, typed)
    }

    /// Queues a selection change computed after earlier edits and moves have finished.
    func select(_ make: @escaping @MainActor (HwpDocument) async throws -> EditSelection?) {
        enqueue { document in
            if let selection = try await make(document) { document.selection = selection }
        }
    }
    /// Waits for queued edits and moves.
    func settle() async { await queue?.value }

    func hitTest(page: Int, x: Double, y: Double) async throws -> EditPosition {
        try await session.hitTest(revision: revision, page: UInt32(page), x: x, y: y)
    }
    func caret(at position: EditPosition) async throws -> PageRect {
        try await session.caret(revision: revision, at: position)
    }
    func selectionRects(_ selection: EditSelection) async throws -> [PageRect] {
        try await session.selectionRects(revision: revision, for: selection)
    }
    func paragraph(_ target: EditTarget) async throws -> ParagraphInfo {
        try await session.paragraph(target)
    }
    /// The whole document as PDF, after queued edits.
    func pdf() async throws -> Data {
        await settle()
        return try await session.pdf()
    }
    /// Plain text of a selection within one container; paragraphs are joined with newlines.
    func text(of selection: EditSelection) async throws -> String {
        let (start, end) = selection.anchor.precedes(selection.focus)
            ? (selection.anchor, selection.focus) : (selection.focus, selection.anchor)
        var lines: [String] = []
        for index in start.target.index...end.target.index {
            let target = start.target.offset(by: Int(index) - Int(start.target.index))
            let text = try await session.paragraph(target).text
            let lower = index == start.target.index ? start.scalar : 0
            let upper = index == end.target.index ? end.scalar : UInt32(text.unicodeScalars.count)
            lines.append(text.scalars(lower..<max(lower, upper)))
        }
        return lines.joined(separator: "\n")
    }

    private func enqueue(_ work: @escaping @MainActor (HwpDocument) async throws -> Void) {
        queued += 1
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await work(self) } catch { NSSound.beep() }
        }
    }
    private func run(_ command: EditCommand) async throws {
        let output = try await session.apply(command, at: revision)
        if !pages.replace(output.reply.changedPages, with: output.pdf, pageCount: output.reply.pageCount),
           let whole = PDFDocument(data: try await session.pdf()) {
            pages.replace(Array(0..<output.reply.pageCount), with: whole, pageCount: output.reply.pageCount)
        }
        reply = output.reply
        if let selection = output.reply.selection { self.selection = selection }
    }

    private enum Step { case undo, redo }
    /// Registers the engine step that reverses the change just made. Running it registers
    /// the opposite step, which is how `UndoManager` builds its redo stack.
    private func registerHistory(_ step: Step, _ undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.levelsOfUndo = Self.undoLimit
        undoManager.registerUndo(withTarget: self) { document in
            document.registerHistory(step == .undo ? .redo : .undo, undoManager)
            document.enqueue { try await $0.run(step == .undo ? .undo : .redo) }
        }
    }
}

private extension PDFDocument {
    /// Swaps in re-rendered pages and drops pages past `pageCount`. False if `pdf` does not
    /// hold exactly the listed pages.
    @discardableResult
    func replace(_ indices: [UInt32], with pdf: Data, pageCount: UInt32) -> Bool {
        guard let patch = indices.isEmpty ? PDFDocument() : PDFDocument(data: pdf) else { return false }
        return replace(indices, with: patch, pageCount: pageCount)
    }
    @discardableResult
    func replace(_ indices: [UInt32], with patch: PDFDocument, pageCount count: UInt32) -> Bool {
        guard patch.pageCount == indices.count else { return false }
        for (offset, index) in indices.map(Int.init).enumerated() {
            guard let page = patch.page(at: offset), index <= pageCount else { return false }
            if index < pageCount { removePage(at: index) }
            insert(page, at: index)
        }
        while pageCount > Int(count) { removePage(at: pageCount - 1) }
        return true
    }
}
