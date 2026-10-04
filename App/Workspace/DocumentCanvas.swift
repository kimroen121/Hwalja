import AppKit
import Combine
import PDFKit

/// Shows the document's rendered pages and edits the underlying document in place: clicks
/// place the caret, and typing and IME composition go to the engine, which re-renders only
/// the pages an edit changed.
@MainActor
final class DocumentCanvas: PDFView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    private(set) var model: HwpDocument?
    private var observers: Set<AnyCancellable> = []
    private let caret = NSTextInsertionIndicator(frame: .zero)
    private let highlight = SelectionHighlight()
    /// The input method's composing text as last reported; the document already shows it.
    private var markedText = ""
    /// Engine geometry of the current selection, re-placed on zoom and layout changes.
    private var caretRect: PageRect?
    private var selectionRects: [PageRect] = []
    private var markedRects: [PageRect] = []
    private var dragging = false
    private var fitted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoScales = true
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        backgroundColor = .underPageBackgroundColor
        minScaleFactor = 0.25
        maxScaleFactor = 4
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func bind(_ model: HwpDocument) {
        guard model !== self.model else { return }
        self.model = model
        document = model.pages
        observers.removeAll()
        NotificationCenter.default.publisher(for: .PDFViewScaleChanged, object: self)
            .sink { [weak self] _ in self?.placeOverlay() }
            .store(in: &observers)
        model.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in self?.sync() }
            .store(in: &observers)
        sync()
    }

    private var shownRevision: UInt64?
    private var shownSelection: EditSelection?
    private var shownMarked: EditSelection?
    /// Re-places the caret and highlight when an edit, move or composition changed them.
    private func sync() {
        guard let model, (model.revision, model.selection, model.marked) != (shownRevision, shownSelection, shownMarked) else { return }
        (shownRevision, shownMarked) = (model.revision, model.marked)
        refreshSelection()
    }

    override func layout() {
        super.layout()
        // Open documents a whole page at a time.
        if !fitted, bounds.width > 0, document?.pageCount ?? 0 > 0 {
            fitted = true
            zoomToFitPage()
        }
        placeOverlay()
    }

    // MARK: Selection overlay

    private func refreshSelection() {
        shownSelection = model?.selection
        guard let model, let selection = model.selection else {
            (caretRect, selectionRects, markedRects) = (nil, [], [])
            return placeOverlay()
        }
        let (revision, marked) = (model.revision, model.marked)
        Task {
            let caret = try? await model.caret(at: selection.focus)
            let rects = selection.anchor == selection.focus ? [] : ((try? await model.selectionRects(selection)) ?? [])
            var markedRects: [PageRect] = []
            if let marked { markedRects = (try? await model.selectionRects(marked)) ?? [] }
            guard model.revision == revision, model.selection == selection else { return }
            (caretRect, selectionRects, self.markedRects) = (caret, rects, markedRects)
            placeOverlay()
        }
    }

    private func viewRect(_ rect: PageRect) -> NSRect? {
        guard let page = document?.page(at: Int(rect.page)), let documentView else { return nil }
        let pageRect = PageGeometry.pageRect(rect, in: page.bounds(for: displayBox))
        return documentView.convert(convert(pageRect, from: page), from: self)
    }

    private func placeOverlay() {
        guard let documentView else { return }
        for view in [highlight, caret] where view.superview !== documentView {
            documentView.addSubview(view)
        }
        highlight.frame = documentView.bounds
        highlight.rects = selectionRects.compactMap(viewRect)
        highlight.underlines = markedRects.compactMap(viewRect)
        if selectionRects.isEmpty, let rect = caretRect.flatMap(viewRect) {
            caret.frame = NSRect(x: rect.minX - 1, y: rect.minY, width: 2, height: rect.height)
            caret.displayMode = window?.firstResponder === self ? .automatic : .hidden
        } else {
            caret.displayMode = .hidden
        }
    }

    override func becomeFirstResponder() -> Bool {
        defer { placeOverlay() }
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        commitComposition()
        defer { placeOverlay() }
        return super.resignFirstResponder()
    }

    // MARK: Mouse

    /// Engine page index and point under the event, or nil off-page or on a rotated page.
    private func enginePoint(_ event: NSEvent) -> (page: Int, point: CGPoint)? {
        let location = convert(event.locationInWindow, from: nil)
        guard let document, let page = page(for: location, nearest: true), page.rotation == 0 else { return nil }
        let point = PageGeometry.enginePoint(convert(location, to: page), in: page.bounds(for: displayBox))
        return (document.index(for: page), point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, let hit = enginePoint(event) else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        commitComposition()
        let extend = event.modifierFlags.contains(.shift)
        model.select { model in
            let position = try await model.hitTest(page: hit.page, x: hit.point.x, y: hit.point.y)
            guard extend, let anchor = model.selection?.anchor else { return .caret(position) }
            return EditSelection(anchor: anchor, focus: position)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, !dragging, let hit = enginePoint(event) else { return }
        dragging = true
        model.select { [weak self] model in
            defer { self?.dragging = false }
            guard let anchor = model.selection?.anchor else { return nil }
            let position = try await model.hitTest(page: hit.page, x: hit.point.x, y: hit.point.y)
            return EditSelection(anchor: anchor, focus: position)
        }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard model?.selection != nil else { return super.keyDown(with: event) }
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)): replaceSelection(with: "\n")
        case #selector(insertTab(_:)): replaceSelection(with: "\t")
        case #selector(deleteBackward(_:)): delete(forward: false)
        case #selector(deleteForward(_:)): delete(forward: true)
        case #selector(moveLeft(_:)), #selector(moveBackward(_:)): moveHorizontally(by: -1, extend: false)
        case #selector(moveRight(_:)), #selector(moveForward(_:)): moveHorizontally(by: 1, extend: false)
        case #selector(moveLeftAndModifySelection(_:)): moveHorizontally(by: -1, extend: true)
        case #selector(moveRightAndModifySelection(_:)): moveHorizontally(by: 1, extend: true)
        case #selector(moveUp(_:)): moveVertically(up: true, extend: false)
        case #selector(moveDown(_:)): moveVertically(up: false, extend: false)
        case #selector(moveUpAndModifySelection(_:)): moveVertically(up: true, extend: true)
        case #selector(moveDownAndModifySelection(_:)): moveVertically(up: false, extend: true)
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)): moveToLineEdge(end: false, extend: false)
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)): moveToLineEdge(end: true, extend: false)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)), #selector(moveToLeftEndOfLineAndModifySelection(_:)):
            moveToLineEdge(end: false, extend: true)
        case #selector(moveToEndOfLineAndModifySelection(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:)):
            moveToLineEdge(end: true, extend: true)
        case #selector(moveToBeginningOfParagraph(_:)): moveToParagraphEdge(end: false)
        case #selector(moveToEndOfParagraph(_:)): moveToParagraphEdge(end: true)
        case #selector(cancelOperation(_:)): discardComposition()
        default:
            if responds(to: selector) { perform(selector, with: nil) } else { NSSound.beep() }
        }
    }

    private func replaceSelection(with text: String) {
        model?.edit(undoManager) { selection in selection.map { .replace($0, text: text) } }
    }

    /// Deletes the selection, or the grapheme next to the caret, or joins paragraphs at an edge.
    private func delete(forward: Bool) {
        guard let model else { return }
        model.select { model in
            guard let selection = model.selection, selection.anchor == selection.focus else { return nil }
            let caret = selection.focus
            let bounds = try await model.paragraph(caret.target).text.graphemeBoundaries
            let next = forward ? bounds.first { $0 > caret.scalar } : bounds.last { $0 < caret.scalar }
            return next.map { EditSelection(anchor: caret, focus: EditPosition(target: caret.target, scalar: $0)) }
        }
        model.edit(undoManager) { selection in
            guard let selection else { return nil }
            if selection.anchor != selection.focus { return .replace(selection, text: "") }
            if forward { return .mergePrevious(EditPosition(target: selection.focus.target.offset(by: 1), scalar: 0)) }
            return selection.focus.scalar == 0 && selection.focus.target.index > 0 ? .mergePrevious(selection.focus) : nil
        }
    }

    private func moveHorizontally(by step: Int, extend: Bool) {
        model?.select { model in
            guard let selection = model.selection else { return nil }
            if !extend, selection.anchor != selection.focus {
                let ordered = [selection.anchor, selection.focus].sorted { $0.precedes($1) }
                return .caret(step < 0 ? ordered[0] : ordered[1])
            }
            let focus = selection.focus
            let bounds = try await model.paragraph(focus.target).text.graphemeBoundaries
            let next: EditPosition
            if let scalar = step < 0 ? bounds.last(where: { $0 < focus.scalar }) : bounds.first(where: { $0 > focus.scalar }) {
                next = EditPosition(target: focus.target, scalar: scalar)
            } else if step < 0, focus.target.index > 0 {
                let previous = focus.target.offset(by: -1)
                next = EditPosition(target: previous, scalar: try await model.paragraph(previous).text.graphemeBoundaries.last ?? 0)
            } else if step > 0, (try? await model.paragraph(focus.target.offset(by: 1))) != nil {
                next = EditPosition(target: focus.target.offset(by: 1), scalar: 0)
            } else {
                return nil
            }
            return extend ? EditSelection(anchor: selection.anchor, focus: next) : .caret(next)
        }
    }

    private func moveVertically(up: Bool, extend: Bool) {
        model?.select { model in
            guard let selection = model.selection else { return nil }
            let rect = try await model.caret(at: selection.focus)
            let y = up ? rect.y - rect.height / 2 : rect.y + rect.height * 1.5
            let next = try await model.hitTest(page: Int(rect.page), x: rect.x + 0.5, y: y)
            return extend ? EditSelection(anchor: selection.anchor, focus: next) : .caret(next)
        }
    }

    private func moveToLineEdge(end: Bool, extend: Bool) {
        model?.select { [weak self] model in
            guard let selection = model.selection, let self, let width = self.pageWidth(selection) else { return nil }
            let rect = try await model.caret(at: selection.focus)
            let next = try await model.hitTest(page: Int(rect.page), x: end ? width : 0, y: rect.y + rect.height / 2)
            return extend ? EditSelection(anchor: selection.anchor, focus: next) : .caret(next)
        }
    }

    private func pageWidth(_ selection: EditSelection) -> Double? {
        guard let page = caretRect.flatMap({ document?.page(at: Int($0.page)) }) else { return nil }
        return page.bounds(for: displayBox).width / PageGeometry.pointsPerPixel
    }

    private func moveToParagraphEdge(end: Bool) {
        model?.select { model in
            guard let focus = model.selection?.focus else { return nil }
            let scalar = end ? (try await model.paragraph(focus.target).text.graphemeBoundaries.last ?? 0) : 0
            return .caret(EditPosition(target: focus.target, scalar: scalar))
        }
    }

    // MARK: Edit menu

    override func copy(_ sender: Any?) { copySelection(cut: false) }
    @objc func cut(_ sender: Any?) { copySelection(cut: true) }
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
        replaceSelection(with: text)
    }
    @objc func delete(_ sender: Any?) { replaceSelection(with: "") }
    /// Selects all text of the body or of the cell holding the caret.
    override func selectAll(_ sender: Any?) {
        guard model?.selection != nil else { return super.selectAll(sender) }
        model?.select { model in
            guard let target = model.selection?.focus.target else { return nil }
            let count = try await model.paragraph(target).count
            let last = target.offset(by: Int(count) - 1 - Int(target.index))
            let end = try await model.paragraph(last).text.graphemeBoundaries.last ?? 0
            return EditSelection(anchor: EditPosition(target: target.offset(by: -Int(target.index)), scalar: 0),
                                 focus: EditPosition(target: last, scalar: end))
        }
    }

    private func copySelection(cut: Bool) {
        guard let model, let selection = model.selection, selection.anchor != selection.focus else { return NSSound.beep() }
        Task {
            guard let text = try? await model.text(of: selection) else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if cut { replaceSelection(with: "") }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasRange = model?.selection.map { $0.anchor != $0.focus } ?? false
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): return hasRange
        case #selector(paste(_:)): return model?.selection != nil && NSPasteboard.general.string(forType: .string) != nil
        default: return responds(to: item.action)
        }
    }

    // MARK: Format

    private func toggle(_ flag: KeyPath<CharStyle, Bool?>, _ make: (Bool) -> CharStyle) {
        model?.formatText(make(!(model?.format?.text[keyPath: flag] ?? false)), undoManager)
    }
    func toggleBold() { toggle(\.bold) { CharStyle(bold: $0) } }
    func toggleItalic() { toggle(\.italic) { CharStyle(italic: $0) } }
    func toggleUnderline() { toggle(\.underline) { CharStyle(underline: $0) } }
    func toggleStrikethrough() { toggle(\.strikethrough) { CharStyle(strikethrough: $0) } }
    func stepFontSize(by step: Double) {
        guard let size = model?.format?.text.size else { return }
        setFontSize(max(1, size + step))
    }
    func setFont(_ name: String) { model?.formatText(CharStyle(font: name), undoManager) }
    func setFontSize(_ size: Double) { model?.formatText(CharStyle(size: size), undoManager) }
    func setTextColor(_ hex: String) { model?.formatText(CharStyle(color: hex), undoManager) }
    func setAlignment(_ alignment: Alignment) { model?.formatParagraphs(ParaStyle(alignment: alignment), undoManager) }
    func setLineSpacing(_ percent: Double) { model?.formatParagraphs(ParaStyle(lineSpacing: percent), undoManager) }

    // MARK: View menu

    @objc func zoomToActualSize(_ sender: Any?) {
        autoScales = false
        scaleFactor = 1
    }
    @objc func zoomToFit(_ sender: Any?) { zoomToFitPage() }
    /// Scales so a whole page is visible.
    func zoomToFitPage() {
        guard let page = currentPage else { return }
        let size = page.bounds(for: displayBox).size
        autoScales = false
        scaleFactor = min(bounds.width / size.width, bounds.height / size.height) * 0.95
    }

    // MARK: File menu

    @objc func printDocument(_ sender: Any?) {
        print(with: .shared, autoRotate: true)
    }

    @objc func exportAsPDF(_ sender: Any?) {
        guard let window, let model else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (window.representedURL?.deletingPathExtension().lastPathComponent ?? window.title) + ".pdf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do { try await model.pdf().write(to: url, options: .atomic) } catch { NSApp.presentError(error) }
            }
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        if !markedText.isEmpty {
            markedText = ""
            model?.compose(text, commit: true, undoManager)
        } else if !text.isEmpty {
            model?.type(text, undoManager)
        }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        guard text != markedText else { return }
        markedText = text
        model?.compose(text, commit: text.isEmpty, undoManager)
    }
    func unmarkText() { commitComposition() }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }
    func selectedRange() -> NSRange { NSRange(location: markedText.utf16.count, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let documentView, let rect = caretRect.flatMap(viewRect) else { return .zero }
        return window.convertToScreen(documentView.convert(rect, to: nil))
    }

    /// Keeps composed-but-unconfirmed text as typed, so it is never silently lost.
    private func commitComposition() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        inputContext?.discardMarkedText()
        model?.endComposition()
    }
    private func discardComposition() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        inputContext?.discardMarkedText()
        model?.compose("", commit: true, undoManager)
    }
}

/// Draws the selection highlight and the composing-text underline without intercepting
/// mouse events.
private final class SelectionHighlight: NSView {
    var rects: [NSRect] = [] { didSet { if rects != oldValue { needsDisplay = true } } }
    var underlines: [NSRect] = [] { didSet { if underlines != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { superview?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let active = window?.isKeyWindow == true
        (active ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor).withAlphaComponent(0.6).setFill()
        rects.forEach { $0.fill(using: .sourceOver) }
        NSColor.textColor.setFill()
        for rect in underlines {
            NSRect(x: rect.minX, y: isFlipped ? rect.maxY - 1 : rect.minY, width: rect.width, height: 1).fill()
        }
    }
}

extension EditTarget {
    /// Index of the paragraph within its container (body or cell).
    var index: UInt32 { cell?.paragraph ?? paragraph }
    func offset(by delta: Int) -> EditTarget {
        var target = self
        let value = UInt32(max(0, Int(index) + delta))
        if target.cell != nil { target.cell?.paragraph = value } else { target.paragraph = value }
        return target
    }
}

extension EditPosition {
    func precedes(_ other: EditPosition) -> Bool {
        (target.index, scalar) < (other.target.index, other.scalar)
    }
}

extension EditSelection {
    /// The ends in document order.
    var ordered: (start: EditPosition, end: EditPosition) {
        anchor.precedes(focus) ? (anchor, focus) : (focus, anchor)
    }
}
