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
    /// The frames of the other objects chosen with it.
    var others: [PageRect] = []
    /// The selected object's size is protected (크기 고정).
    var objectLocked = false
    /// The selected object sits in the line (글자처럼 취급): dragging it moves it in the text.
    var objectInLine = false
    /// The selected 직선's ends (x, y, x, y in page pixels), dragged one at a time.
    var lineEnds: [Double]?
}

/// What menus and bars depend on. It changes far less often than the caret, so SwiftUI
/// views observe only this (plus `format` and `thumbnails`), never each keystroke.
struct EditingContext: Equatable {
    var hasSelection = false
    /// The selection covers text.
    var hasRange = false
    /// The caret is in a table cell (not a 글상자).
    var inTable = false
    /// The caret is in a 각주 or 미주.
    var inNote = false
    /// The caret is in a 머리말 or 꼬리말.
    var inHeaderFooter = false
    /// The caret is in the body text (not a cell, 글상자, note, 머리말 or 꼬리말), where objects and breaks go.
    var inBody = false
    /// The paragraph at the caret is a 글머리표, 문단 번호 or 개요 item.
    var inList = false
    var pageCount = 0
    var canUndo = false
    var canRedo = false
    /// The selection is a block of table cells.
    var cellBlock = false
    /// The kind of the selected object.
    var object: ObjectKind?
    /// How many objects are chosen; more than one for 개체 묶기.
    var objects = 0
    /// Formats can be read and changed here.
    var canFormat: Bool { hasSelection && !locked }
    /// 스타일 apply in the body and in cells, not in notes, 머리말 or 꼬리말.
    var canApplyStyle: Bool { canFormat && !inNote && !inHeaderFooter }
    /// The document is read-only (배포용 문서); editing commands are off.
    var locked = false
    /// A picture or an equation can be put at the caret: in the body or in a table cell.
    var canPicture: Bool { inBody || inTable }
    /// 캡션 넣기 applies: to a selected picture or table, or the table holding the caret.
    var canCaption: Bool {
        !locked && (object == .picture || object == .table || (inTable && object == nil))
    }
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
    private nonisolated let workBarrier = DocumentWorkBarrier()
    /// A new document could not be made; the window offers to try again.
    let creationFailed: Bool
    /// Rendered pages as shown, replaced only when a presentation is published.
    private(set) var pages: [RenderedPage]
    /// Each page's body area (쪽 윤곽 off shows only it).
    private(set) var bodies: [PageRect] = []
    // Plain stored properties (not @Published) so the nonisolated file-reading init can set them.
    private(set) var reply: EditReply
    /// Marks this document's copies on the pasteboard, so a paste here takes them from the engine.
    let copyID = UUID().uuidString
    var selection: EditSelection? {
        didSet {
            if let selection, !selection.focus.target.isHeaderFooter { bodySelection = selection }
        }
    }
    /// The selection before the caret went into a 머리말 or 꼬리말, where 닫기 returns.
    private var bodySelection: EditSelection?
    /// The picture or equation selected as an object; with others, the last one chosen (기준 개체).
    var object: PlacedObject? {
        didSet { if oldValue?.object != object?.object { others = [] } }
    }
    /// Objects chosen with <Shift> before `object`, for 개체 묶기.
    private(set) var others: [PlacedObject] = []
    /// <Shift> and a click: `placed` joins the chosen objects as the 기준 개체; chosen again, it leaves.
    func choose(_ placed: PlacedObject) {
        var kept = others + [object].compactMap { $0 }
        let had = kept.contains { $0.object == placed.object }
        kept.removeAll { $0.object == placed.object }
        object = had ? kept.popLast() : placed
        others = kept
    }
    /// Text the input method is still composing; it is already in the document.
    private(set) var marked: EditSelection?
    private(set) var presentation = Presentation()
    /// Sent after each new `presentation`, for the canvas and the find bar.
    let presented = PassthroughSubject<Void, Never>()

    /// Format at the caret (or at the end of the selection), with any pending style.
    private(set) var format: Format? { willSet { objectWillChange.send() } }
    /// The document's styles, read once.
    private(set) var styles: [StyleInfo] = [] {
        didSet { objectWillChange.send() }
    }
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
        self.init(blankUsing: { try EditSession.open($0) })
    }
    nonisolated init(blankUsing open: (Data?) throws -> (EditSession, EditSession.Output)) {
        do {
            let (session, output) = try open(nil)
            sessionResult = .success(session)
            creationFailed = false
            pages = output.pages
            bodies = output.reply.bodies ?? []
            reply = output.reply
            thumbnails = output.pages
            context.pageCount = output.pages.count
        } catch {
            sessionResult = .failure(error)
            creationFailed = true
            pages = []
            reply = EditReply(revision: 0, pageCount: 0, changedPages: [], canUndo: false, canRedo: false, dirty: false)
            // EditError contains only a category, never document text or bytes.
            Logger(subsystem: "app.hwpstudio.mac", category: "Document").error("Blank document creation failed: \(String(describing: error), privacy: .public)")
        }
    }
    nonisolated convenience init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let name = configuration.file.filename ?? ""
        try self.init(data: data) { again in Self.askPassword(name, again: again) }
    }
    /// `password` is asked for a document locked with one, again after a wrong one; nil cancels.
    nonisolated init(data: Data?, password: ((_ again: Bool) -> String?)? = nil) throws {
        var opened: (EditSession, EditSession.Output)?
        var given: String?
        while opened == nil {
            do {
                opened = try EditSession.open(data, password: given)
            } catch EditError.passwordRequired where password != nil {
                guard let next = password?(given != nil) else { throw CocoaError(.userCancelled) }
                given = next
            }
        }
        let (session, output) = opened!
        self.sessionResult = .success(session)
        self.creationFailed = false
        pages = output.pages
        bodies = output.reply.bodies ?? []
        reply = output.reply
        thumbnails = output.pages
        context.pageCount = output.pages.count
    }

    /// A lock and a secure field, titled with the file's name.
    private nonisolated static func askPassword(_ name: String, again: Bool) -> String? {
        let ask = { @MainActor () -> String? in
            if again { NSSound.beep() }
            let alert = NSAlert()
            alert.icon = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            alert.messageText = name
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
            alert.accessoryView = field
            alert.addButton(withTitle: "확인")
            alert.addButton(withTitle: "취소")
            alert.window.initialFirstResponder = field
            return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
        return Thread.isMainThread ? MainActor.assumeIsolated(ask) : DispatchQueue.main.sync { MainActor.assumeIsolated(ask) }
    }

    nonisolated func snapshot(contentType: UTType) throws -> Data {
        // ReferenceFileDocument asks for snapshots away from the main actor. Refuse an
        // accidental main-thread flush instead of deadlocking the tasks that must finish it.
        if Thread.isMainThread && workBarrier.hasPendingWork { throw EditError.saveFailed }
        workBarrier.waitUntilIdle()
        return try session.export(contentType.preferredFilenameExtension == "hwp" ? .hwp : .hwpx)
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
            let matches = try await document.find(query)
            guard !matches.isEmpty else { return NSSound.beep() }
            try await document.run(.replaceAll(matches, text: text))
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
    /// Draws a 그리기 개체 from `start` to `end` (engine points on `page`), anchored to the
    /// paragraph there, and selects it.
    func insertShape(_ shape: String, page: Int, from start: CGPoint, to end: CGPoint, _ undoManager: UndoManager?) {
        let units = { (pixels: Double) in Int32((pixels * 75).rounded()) }
        let (x, y) = (min(start.x, end.x), min(start.y, end.y))
        let (width, height) = (abs(end.x - start.x), abs(end.y - start.y))
        perform(undoManager) { document in
            let position = try await document.hitTest(page: page, x: start.x, y: start.y)
            guard position.target.cell == nil, position.target.note == nil else { return nil }
            return .insertShape(position, shape: shape, x: units(x), y: units(y),
                                width: UInt32(units(width)), height: UInt32(units(height)),
                                flip: shape == "line" && (end.x - start.x) * (end.y - start.y) < 0)
        }
        enqueue { document in
            document.object = try? await document.objectAt(page: page, x: x + width / 2, y: y + height / 2)
        }
    }
    /// Applies 스타일 `style` to every paragraph the selection touches.
    func applyStyle(_ style: UInt32, _ undoManager: UndoManager?) {
        edit(undoManager) { $0.map { .applyStyle($0, style: style) } }
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
    /// The selection's text, and where the engine can say it, its HTML and copy number,
    /// after queued edits. The plain text leaves objects out.
    func copy(_ selection: EditSelection) async throws -> (text: String, copied: Copied?) {
        await settle()
        let text = try await text(of: selection)
        return (text, try? await session.copy(revision: revision, selection))
    }
    /// Copies the selected object to the engine's clipboard, after queued edits.
    func copyObject(_ object: ObjectRef) async throws -> Copied {
        await settle()
        return try await session.copyObject(object)
    }
    /// Pastes copy `copy` of this document while the engine holds it, else `html`, else `text`,
    /// each keeping what formats it carries.
    func paste(copy: UInt64?, html: String?, text: String?, _ undoManager: UndoManager?) {
        enqueue { document in
            guard let selection = document.selection else { return }
            document.goalX = nil
            let tries: [EditCommand] = [copy.map { .paste(selection, copy: $0, html: nil) },
                                        html.map { .paste(selection, copy: nil, html: $0) },
                                        text.map { .replace(selection, text: $0) }].compactMap { $0 }
            guard !tries.isEmpty else { return }
            for (index, command) in tries.enumerated() {
                do {
                    try await document.run(command)
                    break
                } catch where index < tries.count - 1 {
                    continue
                }
            }
            document.registerHistory(.undo, undoManager)
        }
    }
    /// 닫기: from a 머리말 or 꼬리말 back to where the caret was before.
    func closeHeaderFooter() {
        select { $0.bodySelection }
    }
    /// 머리말/꼬리말 지우기 for the one holding the caret, which goes back where it was before.
    func deleteHeaderFooter(_ undoManager: UndoManager?) {
        enqueue { document in
            guard let target = document.selection?.focus.target, target.isHeaderFooter else { return }
            try await document.run(.deleteHeaderFooter(target))
            if let body = document.bodySelection { document.selection = body }
            document.registerHistory(.undo, undoManager)
        }
    }
    /// Lets go of the selected object, keeping the caret where it was.
    func deselectObject() {
        enqueue { $0.object = nil }
    }
    /// Shows or hides 문단 부호, 조판 부호 and 투명 선 on the pages, after queued edits.
    func showMarks(paragraph: Bool, control: Bool, borders: Bool) {
        enqueue { document in
            let output = try await document.session.showMarks(paragraph: paragraph, control: control, borders: borders)
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
    func hitTest(page: Int, x: Double, y: Double, includeHeaderFooter: Bool = false) async throws -> EditPosition {
        try await session.hitTest(revision: revision, page: UInt32(page), x: x, y: y,
                                  includeHeaderFooter: includeHeaderFooter)
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
    func pageHide(_ target: EditTarget) async throws -> PageHide {
        try await session.pageHide(target)
    }
    func bookmarks() async throws -> [Bookmark] {
        try await session.bookmarks()
    }
    func statistics() async throws -> Statistics {
        try await session.statistics()
    }
    /// Reads the document's styles the first time they are wanted.
    func loadStyles() async {
        if styles.isEmpty, let list = try? await session.styles() { styles = list }
    }
    /// 상황 선 for `position` in the current revision.
    func status(at position: EditPosition) async throws -> CaretStatus {
        try await session.status(revision: revision, at: position)
    }
    func pageSetup(section: UInt32) async throws -> PageSetup {
        try await session.pageSetup(section: section)
    }
    func objectAt(page: Int, x: Double, y: Double) async throws -> PlacedObject? {
        try await session.objectAt(revision: revision, page: UInt32(page), x: x, y: y)
    }
    /// The table borders on a page that can be dragged.
    func tableLines(page: Int) async throws -> [TableLine] {
        try await session.tableLines(revision: revision, page: UInt32(page))
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
    func convertEquation(_ text: String, fromLatex: Bool) async throws -> String {
        try await session.convertEquation(text, fromLatex: fromLatex)
    }
    /// The whole document as PDF, after queued edits.
    func pdf() async throws -> Data {
        await settle()
        return try pdfData(drawing: pages)
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
        // Objects in the line (U+FFFC) and 머리말·꼬리말 fields (U+0015–0017) stand in the
        // text; copied text leaves them out.
        return lines.joined(separator: "\n").filter { !"\u{FFFC}\u{15}\u{16}\u{17}".contains($0) }
    }

    // MARK: Running

    private func perform(_ undoManager: UndoManager?, _ make: @escaping @MainActor (HwpDocument) async throws -> EditCommand?) {
        enqueue { document in
            guard let command = try await make(document) else { return }
            document.goalX = nil
            try await document.run(command)
            if case .deleteObject = command { document.object = nil }
            if case .moveObject = command { document.object = nil }
            if case .group = command { document.object = nil }
            document.registerHistory(.undo, undoManager)
        }
    }
    private func enqueue(_ work: @escaping @MainActor (HwpDocument) async throws -> Void) {
        let token = workBarrier.begin()
        queued += 1
        let previous = queue
        queue = Task { [weak self] in
            defer { token.finish() }
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
        // Changing an object leaves the text caret where it was.
        var objectChange = false
        if case .setObject = command { objectChange = true }
        if !objectChange, let selection = output.reply.selection, selection != self.selection {
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
            format = try? await session.format(revision: revision, at: selection.ordered.end,
                                               from: selection.anchor == selection.focus ? nil : selection.ordered.start)
        }
        await loadStyles()
        // A pending style lasts while the caret stays put or composition continues there.
        if let pending = pendingStyle {
            if marked == nil && selection != .caret(pending.at) {
                pendingStyle = nil
            } else {
                let text = format?.text.merging(pending.style) ?? pending.style
                format?.text = text
            }
        }
        var (locked, inLine) = (false, object?.object.kind == .equation)
        if let placed = object, [.picture, .shape].contains(placed.object.kind) {
            let props = try? await session.objectProps(placed.object)
            (locked, inLine) = (props?.sizeProtect == true, props?.treatAsChar == true)
        }
        var next = Presentation(serial: presentation.serial + 1, caret: caret, highlight: highlight, object: object?.rect,
                                others: others.map(\.rect), objectLocked: locked, objectInLine: inLine, lineEnds: object?.ends)
        for output in staged {
            let count = pages.count
            for (index, page) in zip(output.reply.changedPages.map(Int.init), output.pages) where index <= pages.count {
                if index < pages.count { pages[index] = page } else { pages.append(page) }
            }
            for (index, body) in zip(output.reply.changedPages.map(Int.init), output.reply.bodies ?? []) where index <= bodies.count {
                if index < bodies.count { bodies[index] = body } else { bodies.append(body) }
            }
            pages.removeLast(max(0, pages.count - Int(output.reply.pageCount)))
            bodies.removeLast(max(0, bodies.count - Int(output.reply.pageCount)))
            next.changedPages.formUnion(IndexSet(output.reply.changedPages.map(Int.init)))
            next.reflowed = next.reflowed || pages.count != count
        }
        staged = []
        presentation = next
        presented.send()
        if format != self.format { self.format = format }
        let block = selection?.isCellBlock ?? false
        // A 배포용 문서 has no body or table to edit.
        let editable = reply.locked != true
        let context = EditingContext(hasSelection: selection != nil,
                              hasRange: !block && selection.map { $0.anchor != $0.focus } ?? false,
                              inTable: editable && selection?.focus.target.cell != nil && format?.textBox != true,
                              inNote: selection?.focus.target.note != nil,
                              inHeaderFooter: selection?.focus.target.headerFooter != nil,
                              inBody: editable && (selection.map {
                                  $0.focus.target.cell == nil && $0.focus.target.note == nil && $0.focus.target.headerFooter == nil
                              } ?? false),
                              inList: ["Number", "Bullet", "Outline"].contains(format?.paragraph.head ?? ""),
                              pageCount: pages.count,
                              canUndo: reply.canUndo, canRedo: reply.canRedo, cellBlock: editable && block, object: object?.object.kind,
                              objects: others.count + (object == nil ? 0 : 1),
                              locked: reply.locked == true)
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
