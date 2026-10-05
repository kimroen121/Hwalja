import AppKit
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

/// What the canvas shows, published once per finished edit or move so the pages, the caret
/// and the highlight always change in the same frame.
struct Presentation: Equatable {
    /// Increments with every presentation.
    var serial = 0
    /// Pages replaced in `HwpDocument.pages` since the previous presentation.
    var changedPages = IndexSet()
    /// Whether the number of pages changed.
    var reflowed = false
    var caret: PageRect?
    var highlight: [PageRect] = []
}

/// One open HWP/HWPX document: the engine session plus the state views render.
/// Edits and moves run one at a time in submission order; each sees the result of the
/// previous one, and each ends by publishing a `Presentation`.
@MainActor
final class HwpDocument: @preconcurrency ReferenceFileDocument {
    static let readableContentTypes = UTType.hwpFamily
    /// New documents are HWPX, like Hancom Office Web.
    static let writableContentTypes = [UTType.hwpx] + UTType.hwpFamily.filter { $0 != .hwpx }
    /// Undo depth kept by the engine (`HISTORY_LIMIT`).
    static let undoLimit = 20

    private let session: EditSession
    /// Rendered pages as shown, replaced only when a presentation is published.
    private(set) var pages: [RenderedPage]
    // Plain stored properties (not @Published) so the nonisolated file-reading init can set them.
    private(set) var reply: EditReply { willSet { objectWillChange.send() } }
    var selection: EditSelection? { willSet { objectWillChange.send() } }
    /// Text the input method is still composing; it is already in the document.
    private(set) var marked: EditSelection? { willSet { objectWillChange.send() } }
    /// Format at the caret (or at the end of the selection).
    private(set) var format: Format? { willSet { objectWillChange.send() } }
    private(set) var presentation = Presentation() { willSet { objectWillChange.send() } }

    private var queue: Task<Void, Never>?
    /// Number of works ever queued; identifies the latest one.
    private var queued = 0
    /// Re-rendered pages waiting for the next presentation.
    private var staged: [EditSession.Output] = []
    /// Column that consecutive up/down moves keep.
    private var goalX: Double?
    /// The latest queued work while it is unstarted typing, with the text it will insert.
    private var typing: (work: Int, text: Typed)?
    private final class Typed { var text: String; init(_ text: String) { self.text = text } }
    /// The latest queued work while it is an unstarted, uncommitted composition update.
    private var composing: (work: Int, text: Typed)?

    nonisolated init() {
        // ponytail: blank-document failure is unrecoverable (engine bug), so it traps.
        let (session, output) = try! EditSession.open(nil)
        self.session = session
        pages = output.pages
        reply = output.reply
    }
    nonisolated convenience init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(data: data)
    }
    nonisolated init(data: Data) throws {
        let (session, output) = try EditSession.open(data)
        self.session = session
        pages = output.pages
        reply = output.reply
    }

    nonisolated func snapshot(contentType: UTType) throws -> Data {
        try session.export(contentType.preferredFilenameExtension == "hwp" ? .hwp : .hwpx)
    }
    nonisolated func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    var revision: UInt64 { reply.revision }

    // MARK: Edits

    /// Queues an edit built from the selection current when it runs. Successful edits
    /// become one undo step on `undoManager`; refused edits beep.
    func edit(_ undoManager: UndoManager?, _ make: @escaping @MainActor (EditSelection?) -> EditCommand?) {
        perform(undoManager) { make($0.selection) }
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

    /// Deletes the selection, or the text between the caret and where `motion` takes it.
    func delete(_ motion: Motion, _ undoManager: UndoManager?) {
        perform(undoManager) { document in
            guard let selection = document.selection else { return nil }
            if selection.anchor != selection.focus { return .replace(selection, text: "") }
            let end = try await document.navigate(from: selection.focus, motion).position
            return end == selection.focus ? nil : .replace(EditSelection(anchor: selection.focus, focus: end), text: "")
        }
    }

    /// Puts input-method composition into the document, replacing the previous composing
    /// text, so it is laid out in the document's own font. A composition is one undo step:
    /// its first update registers it and later updates fold into it. `commit` ends it.
    func compose(_ text: String, commit: Bool, _ undoManager: UndoManager?) {
        // Only an uncommitted update may be overtaken; a commit always runs.
        if !commit, let composing, composing.work == queued {
            composing.text.text = text
            return
        }
        let typed = Typed(text)
        enqueue { document in
            if document.composing?.text === typed { document.composing = nil }
            let continuing = document.marked != nil
            guard let range = document.marked ?? document.selection, continuing || !typed.text.isEmpty else { return }
            let start = range.ordered.start
            document.goalX = nil
            try await document.run(.replace(range, text: typed.text), amend: continuing)
            if !continuing { document.registerHistory(.undo, undoManager) }
            let end = EditPosition(target: start.target, scalar: start.scalar + UInt32(typed.text.unicodeScalars.count))
            document.marked = commit || typed.text.isEmpty ? nil : EditSelection(anchor: start, focus: end)
        }
        if !commit { composing = (queued, typed) }
    }
    /// Keeps the composing text as typed and ends the composition.
    func endComposition() {
        enqueue { $0.marked = nil }
    }

    /// Replaces every match of `query` as one undo step. Matches in paragraphs the editor
    /// cannot change are skipped.
    func replaceAll(_ query: String, with text: String, _ undoManager: UndoManager?) {
        enqueue { document in
            var replaced = false
            // Last first, so earlier matches keep their offsets.
            for match in try await document.find(query).reversed() {
                // ponytail: renders after every match; batch in the engine if large documents lag.
                guard (try? await document.run(.replace(match, text: text), amend: replaced)) != nil else { continue }
                replaced = true
            }
            guard replaced else { return NSSound.beep() }
            document.goalX = nil
            document.registerHistory(.undo, undoManager)
        }
    }

    /// Applies a character format to the selected text; does nothing without a selection.
    func formatText(_ style: CharStyle, _ undoManager: UndoManager?) {
        edit(undoManager) { selection in
            guard let selection, selection.anchor != selection.focus else { return nil }
            return .formatText(selection, style)
        }
    }
    /// Applies a paragraph format to every paragraph the selection touches.
    func formatParagraphs(_ style: ParaStyle, _ undoManager: UndoManager?) {
        edit(undoManager) { $0.map { .formatParagraphs($0, style) } }
    }

    // MARK: Moves

    /// Moves the caret, or extends the selection, the way `motion` says. Without `extend`,
    /// a selection collapses toward the motion's side first.
    func move(_ motion: Motion, extend: Bool) {
        enqueue { document in
            guard let selection = document.selection else { return }
            let backward: Set<Motion> = [.left, .wordLeft, .lineStart, .up, .paragraphStart, .documentStart]
            let ranged = selection.anchor != selection.focus
            if !extend, ranged, motion == .left || motion == .right {
                document.goalX = nil
                document.selection = .caret(backward.contains(motion) ? selection.ordered.start : selection.ordered.end)
                return
            }
            let from = extend || !ranged ? selection.focus
                : backward.contains(motion) ? selection.ordered.start : selection.ordered.end
            let moved = try await document.navigate(from: from, motion)
            document.selection = extend ? EditSelection(anchor: selection.anchor, focus: moved.position) : .caret(moved.position)
        }
    }

    /// Queues a selection change computed after earlier edits and moves have finished.
    func select(_ make: @escaping @MainActor (HwpDocument) async throws -> EditSelection?) {
        enqueue { document in
            if let selection = try await make(document) {
                document.goalX = nil
                document.selection = selection
            }
        }
    }
    /// Waits for queued edits and moves.
    func settle() async { await queue?.value }

    // MARK: Queries

    /// Where `motion` takes a caret, keeping the column across consecutive vertical moves.
    func navigate(from position: EditPosition, _ motion: Motion) async throws -> Navigation {
        let moved = try await session.navigate(revision: revision, from: position, motion,
                                               goalX: motion.isVertical ? goalX : nil)
        goalX = motion.isVertical ? moved.goalX : nil
        return moved
    }
    func hitTest(page: Int, x: Double, y: Double) async throws -> EditPosition {
        try await session.hitTest(revision: revision, page: UInt32(page), x: x, y: y)
    }
    func caret(at position: EditPosition) async throws -> PageRect {
        try await session.caret(revision: revision, at: position)
    }
    func paragraph(_ target: EditTarget) async throws -> ParagraphInfo {
        try await session.paragraph(target)
    }
    /// Matches of `query` in the current revision, in document order.
    func find(_ query: String) async throws -> [EditSelection] {
        try await session.find(query)
    }
    /// The whole document as PDF, after queued edits.
    func pdf() async throws -> Data {
        await settle()
        return try await session.pdf()
    }
    /// Plain text of a selection within one container; paragraphs are joined with newlines.
    func text(of selection: EditSelection) async throws -> String {
        let (start, end) = selection.ordered
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

    // MARK: Running

    private func perform(_ undoManager: UndoManager?, _ make: @escaping @MainActor (HwpDocument) async throws -> EditCommand?) {
        enqueue { document in
            guard let command = try await make(document) else { return }
            document.goalX = nil
            try await document.run(command)
            document.registerHistory(.undo, undoManager)
        }
    }
    private func enqueue(_ work: @escaping @MainActor (HwpDocument) async throws -> Void) {
        queued += 1
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await work(self) } catch { NSSound.beep() }
            await present()
        }
    }
    private func run(_ command: EditCommand, amend: Bool = false) async throws {
        let output = try await session.apply(command, at: revision, amend: amend)
        staged.append(output)
        reply = output.reply
        if let selection = output.reply.selection { self.selection = selection }
    }
    /// Gathers the caret, highlight and format for the current selection, then swaps in the
    /// staged pages and publishes everything at once.
    private func present() async {
        var caret: PageRect?, highlight: [PageRect] = [], format: Format?
        if let selection {
            caret = reply.selection == selection ? reply.caret : nil
            if caret == nil { caret = try? await session.caret(revision: revision, at: selection.focus) }
            if selection.anchor != selection.focus {
                highlight = (try? await session.selectionRects(revision: revision, for: selection)) ?? []
            }
            format = try? await session.format(revision: revision, at: selection.ordered.end)
        }
        var next = Presentation(serial: presentation.serial + 1, caret: caret, highlight: highlight)
        for output in staged {
            let count = pages.count
            for (index, page) in zip(output.reply.changedPages.map(Int.init), output.pages) where index <= pages.count {
                if index < pages.count { pages[index] = page } else { pages.append(page) }
            }
            pages.removeLast(max(0, pages.count - Int(output.reply.pageCount)))
            next.changedPages.formUnion(IndexSet(output.reply.changedPages.map(Int.init)))
            next.reflowed = next.reflowed || pages.count != count
        }
        staged = []
        if format != self.format { self.format = format }
        presentation = next
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
