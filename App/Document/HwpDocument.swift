import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import OSLog

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
    /// The selected object's frame; the caret hides while an object is selected.
    var object: PageRect?
}

/// What menus and bars depend on. It changes far less often than the caret, so SwiftUI
/// views observe only this (plus `format` and `thumbnails`), never each keystroke.
struct EditingContext: Equatable {
    var hasSelection = false
    /// The selection covers text.
    var hasRange = false
    /// The caret is in a table cell.
    var inTable = false
    /// The caret is in a 각주 or 미주.
    var inNote = false
    var pageCount = 0
    var canUndo = false
    var canRedo = false
    /// The selection is a block of table cells.
    var cellBlock = false
    /// The kind of the selected object.
    var object: ObjectKind?
    /// The caret is in the body text, where objects and breaks go.
    var inBody: Bool { hasSelection && !inTable && !inNote }
    /// Formats can be read and changed here (not yet inside notes).
    var canFormat: Bool { hasSelection && !inNote }
}

/// One open HWP/HWPX document: the engine session plus the state views render.
/// Edits and moves run one at a time in submission order; each sees the result of the
/// previous one, and each ends by publishing a `Presentation` to `presented`.
@MainActor
final class HwpDocument: @preconcurrency ReferenceFileDocument {
    static let readableContentTypes = UTType.hwpFamily
    /// New documents are HWPX, like Hancom Office Web.
    static let writableContentTypes = [UTType.hwpx] + UTType.hwpFamily.filter { $0 != .hwpx }
    /// Undo depth kept by the engine (`HISTORY_LIMIT`).
    static let undoLimit = 20

    private let sessionResult: Result<EditSession, Error>
    private nonisolated var session: EditSession { get throws { try sessionResult.get() } }
    let creationError: String?
    /// Rendered pages as shown, replaced only when a presentation is published.
    private(set) var pages: [RenderedPage]
    // Plain stored properties (not @Published) so the nonisolated file-reading init can set them.
    private(set) var reply: EditReply
    var selection: EditSelection?
    /// The picture or equation selected as an object.
    var object: PlacedObject?
    /// Text the input method is still composing; it is already in the document.
    private(set) var marked: EditSelection?
    private(set) var presentation = Presentation()
    /// Sent after each new `presentation`, for the canvas and the find bar.
    let presented = PassthroughSubject<Void, Never>()

    /// Format at the caret (or at the end of the selection), with any pending style.
    private(set) var format: Format? { willSet { objectWillChange.send() } }
    /// A character format chosen at a caret, for the next text typed there.
    private var pendingStyle: (at: EditPosition, style: CharStyle)?
    private(set) var context = EditingContext() { willSet { objectWillChange.send() } }
    /// Pages for the thumbnails, updated once typing pauses.
    private(set) var thumbnails: [RenderedPage] = [] { willSet { objectWillChange.send() } }
    private var thumbnailUpdate: Task<Void, Never>?

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

    /// New-document failures remain a recovery window, never a process trap.
    nonisolated convenience init() {
        self.init(blankUsing: EditSession.open)
    }
    nonisolated init(blankUsing open: (Data?) throws -> (EditSession, EditSession.Output)) {
        do {
            let (session, output) = try open(nil)
            sessionResult = .success(session)
            creationError = nil
            pages = output.pages
            reply = output.reply
            thumbnails = output.pages
            context.pageCount = output.pages.count
        } catch {
            sessionResult = .failure(error)
            creationError = "새 문서를 만들지 못했습니다. 다시 시도하거나 다른 문서를 열어 주세요."
            pages = []
            reply = EditReply(revision: 0, pageCount: 0, changedPages: [], canUndo: false, canRedo: false, dirty: false)
            // EditError contains only a category, never document text or bytes.
            Logger(subsystem: "app.hwpstudio.mac", category: "Document").error("Blank document creation failed: \(String(describing: error), privacy: .public)")
        }
    }
    nonisolated convenience init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(data: data)
    }
    nonisolated init(data: Data?) throws {
        let (session, output) = try EditSession.open(data)
        self.sessionResult = .success(session)
        self.creationError = nil
        pages = output.pages
        reply = output.reply
        thumbnails = output.pages
        context.pageCount = output.pages.count
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

    /// Applies a character format to the selected text. At a caret, it applies to the
    /// next text typed there, as part of that edit.
    func formatText(_ style: CharStyle, _ undoManager: UndoManager?) {
        enqueue { document in
            guard let selection = document.selection else { return }
            if selection.anchor == selection.focus {
                let earlier = document.pendingStyle.flatMap { $0.at == selection.focus ? $0.style : nil }
                document.pendingStyle = (selection.focus, (earlier ?? CharStyle()).merging(style))
                return
            }
            document.goalX = nil
            try await document.run(.formatText(selection, style))
            document.registerHistory(.undo, undoManager)
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
            document.object = nil
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
                document.object = nil
            }
        }
    }
    /// Lets go of the selected object, keeping the caret where it was.
    func deselectObject() {
        enqueue { $0.object = nil }
    }
    /// Shows or hides 문단 부호 and 조판 부호 on the pages, after queued edits.
    func showMarks(paragraph: Bool, control: Bool) {
        enqueue { document in
            let output = try await document.session.showMarks(paragraph: paragraph, control: control)
            document.staged.append(output)
            document.reply = output.reply
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
    /// Format at `position` in the current revision.
    func session(formatAt position: EditPosition) async throws -> Format {
        try await session.format(revision: revision, at: position)
    }
    func pageSetup(section: UInt32) async throws -> PageSetup {
        try await session.pageSetup(section: section)
    }
    func objectAt(page: Int, x: Double, y: Double) async throws -> PlacedObject? {
        try await session.objectAt(revision: revision, page: UInt32(page), x: x, y: y)
    }
    func objectProps(_ object: ObjectRef) async throws -> ObjectProps {
        try await session.objectProps(object)
    }
    func cellProps(_ cell: EditTarget) async throws -> CellProps {
        try await session.cellProps(cell)
    }
    func equationPreview(_ script: String, fontSize: UInt32, color: UInt32) async throws -> PageDisplay {
        try await session.equationPreview(script, fontSize: fontSize, color: color)
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
            if case .deleteObject = command { document.object = nil }
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
        try await apply(command, amend: amend)
        // Text typed (or composed) where a style is pending takes that style.
        if case let .replace(range, text) = command, let pending = pendingStyle, range.ordered.start == pending.at,
           !text.isEmpty, !text.contains(where: \.isNewline) {
            let start = pending.at
            let end = EditPosition(target: start.target, scalar: start.scalar + UInt32(text.unicodeScalars.count))
            try await apply(.formatText(EditSelection(anchor: start, focus: end), pending.style), amend: true)
            selection = .caret(end)
        }
    }
    private func apply(_ command: EditCommand, amend: Bool) async throws {
        let output = try await session.apply(command, at: revision, amend: amend)
        staged.append(output)
        reply = output.reply
        if let selection = output.reply.selection, selection != self.selection {
            self.selection = selection
            object = nil
        }
    }
    /// Gathers the caret, highlight and format for the current selection, then swaps in the
    /// staged pages and publishes everything at once.
    private func present() async {
        var caret: PageRect?, highlight: [PageRect] = [], format: Format?
        if let placed = object {
            // Edits may move it, or take it away with an undo.
            object = try? await session.place(revision: revision, placed.object, page: placed.rect.page)
        }
        if let selection {
            caret = reply.selection == selection ? reply.caret : nil
            if caret == nil { caret = try? await session.caret(revision: revision, at: selection.focus) }
            if selection.anchor != selection.focus {
                highlight = (try? await session.selectionRects(revision: revision, for: selection)) ?? []
            }
            format = try? await session.format(revision: revision, at: selection.ordered.end)
        }
        // A pending style lasts while the caret stays put or composition continues there.
        if let pending = pendingStyle {
            if marked == nil && selection != .caret(pending.at) {
                pendingStyle = nil
            } else {
                let text = format?.text.merging(pending.style) ?? pending.style
                format?.text = text
            }
        }
        var next = Presentation(serial: presentation.serial + 1, caret: caret, highlight: highlight, object: object?.rect)
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
        presentation = next
        presented.send()
        if format != self.format { self.format = format }
        let block = selection?.isCellBlock ?? false
        let context = EditingContext(hasSelection: selection != nil,
                              hasRange: !block && selection.map { $0.anchor != $0.focus } ?? false,
                              inTable: selection?.focus.target.cell != nil, inNote: selection?.focus.target.note != nil,
                              pageCount: pages.count,
                              canUndo: reply.canUndo, canRedo: reply.canRedo, cellBlock: block, object: object?.object.kind)
        if context != self.context { self.context = context }
        if !next.changedPages.isEmpty { scheduleThumbnails() }
    }
    private func scheduleThumbnails() {
        thumbnailUpdate?.cancel()
        thumbnailUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            thumbnails = pages
        }
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
