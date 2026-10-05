import AppKit
import Combine
import PDFKit

/// Scrolls and zooms the page editor. Zoom is the scroll view's magnification, so 100%
/// shows a page at its printed size in points.
@MainActor
final class DocumentCanvas: NSScrollView {
    enum Fit { case page, width }

    let editor = PageEditor()
    /// Kept while the user has not chosen a zoom of their own; reapplied on resize.
    private(set) var fit: Fit? = .page
    /// Called when the zoom or the page in view changes.
    var onViewChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = editor
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.25
        maxMagnification = 4
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(viewChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(userMagnified), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func bind(_ model: HwpDocument) { editor.bind(model) }

    override func tile() {
        super.tile()
        applyFit()
        if !sizedWindow, window != nil, frame.height > 0, editor.frame(ofPage: 0) != nil {
            sizedWindow = true
            DispatchQueue.main.async { [weak self] in self?.fitWindowToPage() }
        }
    }
    @objc private func viewChanged() { onViewChange?() }
    @objc private func userMagnified() { fit = nil }

    /// ⌘ or ⌃ with the scroll wheel zooms around the pointer.
    override func scrollWheel(with event: NSEvent) {
        guard !event.modifierFlags.intersection([.command, .control]).isEmpty else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        guard delta != 0 else { return }
        fit = nil
        let value = min(maxMagnification, max(minMagnification, magnification * exp(delta)))
        setMagnification(value, centeredAt: editor.convert(event.locationInWindow, from: nil))
    }

    /// Sizes a new window once so the first page fills it at the fit-page zoom.
    private var sizedWindow = false
    private func fitWindowToPage() {
        guard let window, let screen = window.screen ?? NSScreen.main, let page = editor.frame(ofPage: 0) else { return }
        let visible = screen.visibleFrame
        let chrome = NSSize(width: window.frame.width - frame.width, height: window.frame.height - frame.height)
        let height = (visible.height * 0.9).rounded()
        let scale = (height - chrome.height) / (page.height + PageEditor.margin * 2)
        let width = min(visible.width, ((page.width + PageEditor.margin * 2) * scale + chrome.width).rounded())
        var rect = NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: width, height: height)
        rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - width)
        rect.origin.y = max(rect.minY, visible.minY)
        window.setFrame(rect, display: true)
    }

    // MARK: Zoom

    var zoom: CGFloat { magnification }
    func setZoom(_ value: CGFloat) {
        fit = nil
        setMagnification(value, centeredAt: visibleCenter)
    }
    func fit(_ mode: Fit) {
        fit = mode
        applyFit()
    }
    /// Pages side by side (한 쪽, 두 쪽, 세 쪽). Changing it fits the new spread to the window.
    var columns: Int {
        get { editor.columns }
        set {
            guard newValue != editor.columns else { return }
            editor.columns = newValue
            fit(.page)
        }
    }
    private func applyFit() {
        guard let fit, let size = editor.spread, size.width > 0 else { return }
        let space = contentSize
        let margin = PageEditor.margin * 2
        let width = space.width / (size.width + margin)
        let value = fit == .width ? width : min(width, space.height / (size.height + margin))
        if abs(value - magnification) > 0.001 { magnification = value }
    }
    private var visibleCenter: NSPoint {
        let visible = documentVisibleRect
        return NSPoint(x: visible.midX, y: visible.midY)
    }
    @objc func zoomIn(_ sender: Any?) { setZoom(min(maxMagnification, magnification * 1.25)) }
    @objc func zoomOut(_ sender: Any?) { setZoom(max(minMagnification, magnification / 1.25)) }
    @objc func zoomToActualSize(_ sender: Any?) { setZoom(1) }
    @objc func zoomToFit(_ sender: Any?) { fit(.page) }

    // MARK: Pages

    /// Zero-based page at the middle of the view.
    var currentPage: Int { editor.page(near: visibleCenter) }
    func go(to page: Int) {
        guard let frame = editor.frame(ofPage: page) else { return }
        let origin = NSPoint(x: contentView.bounds.minX, y: frame.minY - PageEditor.gap)
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }

    // MARK: File menu

    /// Prints the PDF the engine exports, which embeds the same fonts the pages are drawn with.
    @objc func printDocument(_ sender: Any?) {
        guard let window, let model = editor.model else { return }
        Task {
            do {
                guard let pages = PDFDocument(data: try await model.pdf()),
                      let operation = pages.printOperation(for: .shared, scalingMode: .pageScaleNone, autoRotate: true)
                else { return NSSound.beep() }
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } catch { NSApp.presentError(error) }
        }
    }

    @objc func exportAsPDF(_ sender: Any?) {
        guard let window, let model = editor.model else { return }
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
}

/// Centers a document view smaller than the viewport instead of pinning it to the corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = document.midX - rect.width / 2 }
        if rect.height > document.height { rect.origin.y = document.midY - rect.height / 2 }
        return rect
    }
}

/// Draws the document's pages and edits them in place: clicks place the caret, keys move
/// it through the engine's layout, and typing and IME composition go to the engine, which
/// re-renders only the pages an edit changed. Pages are drawn synchronously, so a changed
/// page appears in the same frame as the caret that moved with it.
@MainActor
final class PageEditor: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    static let margin: CGFloat = 24
    static let gap: CGFloat = 16

    private(set) var model: HwpDocument?
    private var observer: AnyCancellable?
    private var pageFrames: [NSRect] = []
    private var shown = Presentation()
    private let caret = NSTextInsertionIndicator(frame: .zero)
    /// The input method's composing text as last reported; the document already shows it.
    private var markedText = ""
    /// Latest drag point waiting for the hit test in flight.
    private var pendingDrag: NSPoint?
    private var hitTesting = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        // Pages are white paper in any mode, so highlight and caret use light-mode colors.
        appearance = NSAppearance(named: .aqua)
        addSubview(caret)
        caret.displayMode = .hidden
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func bind(_ model: HwpDocument) {
        guard model !== self.model else { return }
        self.model = model
        shown = model.presentation
        observer = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.sync() }
        layoutPages(force: true)
        needsDisplay = true
    }

    // MARK: Pages

    /// Pages per row.
    var columns = 1 {
        didSet { layoutPages() }
    }
    /// Size of one row of pages, for fitting it to the window.
    var spread: NSSize? {
        guard !pageFrames.isEmpty else { return nil }
        let width = pageFrames.map(\.width).max()!, n = CGFloat(min(columns, pageFrames.count))
        return NSSize(width: width * n + Self.gap * (n - 1), height: pageFrames.map(\.height).max()!)
    }
    func frame(ofPage index: Int) -> NSRect? {
        pageFrames.indices.contains(index) ? pageFrames[index] : nil
    }
    func page(near point: NSPoint) -> Int {
        pageFrames.enumerated().min { distance($0.element, point) < distance($1.element, point) }?.offset ?? 0
    }
    private func distance(_ frame: NSRect, _ point: NSPoint) -> CGFloat {
        let dy = point.y < frame.minY ? frame.minY - point.y : max(0, point.y - frame.maxY)
        let dx = point.x < frame.minX ? frame.minX - point.x : max(0, point.x - frame.maxX)
        return hypot(dx, dy)
    }

    /// Lays the pages out in rows of `columns`, each centered in a slot as wide as the
    /// widest page. The clip view centers the whole stack, so the layout never depends on
    /// the viewport.
    func layoutPages(force: Bool = false) {
        guard let pages = model?.pages else { return }
        let sizes = pages.map(\.size)
        let slot = sizes.map(\.width).max() ?? 0
        let columns = max(1, min(columns, sizes.count))
        let width = slot * CGFloat(columns) + Self.gap * CGFloat(columns - 1) + Self.margin * 2
        var frames: [NSRect] = []
        var y = Self.margin
        for row in stride(from: 0, to: sizes.count, by: columns) {
            let rowSizes = sizes[row..<min(row + columns, sizes.count)]
            for (column, size) in rowSizes.enumerated() {
                let x = Self.margin + CGFloat(column) * (slot + Self.gap) + (slot - size.width) / 2
                frames.append(NSRect(x: x.rounded(), y: y, width: size.width, height: size.height))
            }
            y += rowSizes.map(\.height).max()! + Self.gap
        }
        let size = NSSize(width: width, height: y - Self.gap + Self.margin)
        guard force || frames != pageFrames || size != frame.size else { return }
        pageFrames = frames
        setFrameSize(size)
        window?.invalidateCursorRects(for: self)
        placeCaret()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        let pages = model.pages
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        for (index, frame) in pageFrames.enumerated() where frame.insetBy(dx: -4, dy: -4).intersects(dirtyRect) {
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setFill()
            frame.fill()
            NSGraphicsContext.restoreGraphicsState()
            if pages.indices.contains(index) { pages[index].draw(in: context, rect: frame) }
        }
        let active = window?.isKeyWindow == true && window?.firstResponder === self
        (active ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor).setFill()
        for rect in highlightRects where rect.intersects(dirtyRect) {
            rect.fill(using: .multiply)
        }
    }

    override func resetCursorRects() {
        pageFrames.forEach { addCursorRect($0, cursor: .iBeam) }
    }

    // MARK: Presentation

    private var highlightRects: [NSRect] { shown.highlight.compactMap(viewRect) }
    private var caretRect: NSRect? { shown.caret.flatMap(viewRect) }

    private func viewRect(_ rect: PageRect) -> NSRect? {
        frame(ofPage: Int(rect.page)).map { PageGeometry.viewRect(rect, in: $0) }
    }

    /// Applies a new presentation: redraws the pages it changed and moves the highlight
    /// and caret in the same pass.
    private func sync() {
        guard let model, model.presentation.serial != shown.serial else { return }
        let old = highlightRects
        shown = model.presentation
        if shown.reflowed {
            layoutPages(force: true)
        } else {
            shown.changedPages.forEach { index in frame(ofPage: index).map { setNeedsDisplay($0) } }
        }
        (old + highlightRects).forEach { setNeedsDisplay($0.insetBy(dx: -1, dy: -1)) }
        placeCaret()
        if let caretRect { scrollToVisible(caretRect.insetBy(dx: -24, dy: -24)) }
    }

    private func placeCaret() {
        guard let rect = caretRect, shown.highlight.isEmpty else {
            caret.displayMode = .hidden
            return
        }
        caret.frame = NSRect(x: rect.minX - 1, y: rect.minY, width: 2, height: rect.height)
        caret.displayMode = window?.isKeyWindow == true && window?.firstResponder === self ? .automatic : .hidden
    }

    override func becomeFirstResponder() -> Bool {
        defer { focusChanged() }
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        commitComposition()
        defer { focusChanged() }
        return super.resignFirstResponder()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(focusChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(focusChanged), name: NSWindow.didResignKeyNotification, object: window)
    }
    @objc private func focusChanged() {
        placeCaret()
        highlightRects.forEach { setNeedsDisplay($0) }
    }

    // MARK: Mouse

    /// Engine page index and point under a view point, clamped to the nearest page.
    private func enginePoint(_ point: NSPoint) -> (page: Int, point: CGPoint)? {
        guard !pageFrames.isEmpty else { return nil }
        let index = page(near: point)
        let frame = pageFrames[index]
        let clamped = NSPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
        return (index, PageGeometry.enginePoint(clamped, in: frame))
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, let hit = enginePoint(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        commitComposition()
        let extend = event.modifierFlags.contains(.shift)
        let clicks = event.clickCount
        model.select { model in
            let position = try await model.hitTest(page: hit.page, x: hit.point.x, y: hit.point.y)
            switch clicks {
            case 2:
                let start = try await model.navigate(from: position, .wordStart).position
                let end = try await model.navigate(from: position, .wordEnd).position
                return EditSelection(anchor: start, focus: end)
            case 3...:
                let end = UInt32(try await model.paragraph(position.target).text.unicodeScalars.count)
                return EditSelection(anchor: EditPosition(target: position.target, scalar: 0),
                                     focus: EditPosition(target: position.target, scalar: end))
            default:
                guard extend, let anchor = model.selection?.anchor else { return .caret(position) }
                return EditSelection(anchor: anchor, focus: position)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        pendingDrag = convert(event.locationInWindow, from: nil)
        extendToDrag()
    }
    /// Extends the selection to the latest drag point, one hit test at a time, so a fast
    /// drag never queues stale points.
    private func extendToDrag() {
        guard let model, !hitTesting, let point = pendingDrag, let hit = enginePoint(point) else { return }
        pendingDrag = nil
        hitTesting = true
        model.select { [weak self] model in
            defer {
                self?.hitTesting = false
                self?.extendToDrag()
            }
            guard let anchor = model.selection?.anchor else { return nil }
            let position = try await model.hitTest(page: hit.page, x: hit.point.x, y: hit.point.y)
            return EditSelection(anchor: anchor, focus: position)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard model?.selection != nil else { return super.keyDown(with: event) }
        NSCursor.setHiddenUntilMouseMoves(true)
        interpretKeyEvents([event])
    }

    private static let motions: [Selector: (motion: Motion, extend: Bool)] = [
        #selector(moveLeft(_:)): (.left, false), #selector(moveBackward(_:)): (.left, false),
        #selector(moveRight(_:)): (.right, false), #selector(moveForward(_:)): (.right, false),
        #selector(moveLeftAndModifySelection(_:)): (.left, true), #selector(moveBackwardAndModifySelection(_:)): (.left, true),
        #selector(moveRightAndModifySelection(_:)): (.right, true), #selector(moveForwardAndModifySelection(_:)): (.right, true),
        #selector(moveWordLeft(_:)): (.wordLeft, false), #selector(moveWordBackward(_:)): (.wordLeft, false),
        #selector(moveWordRight(_:)): (.wordRight, false), #selector(moveWordForward(_:)): (.wordRight, false),
        #selector(moveWordLeftAndModifySelection(_:)): (.wordLeft, true),
        #selector(moveWordBackwardAndModifySelection(_:)): (.wordLeft, true),
        #selector(moveWordRightAndModifySelection(_:)): (.wordRight, true),
        #selector(moveWordForwardAndModifySelection(_:)): (.wordRight, true),
        #selector(moveUp(_:)): (.up, false), #selector(moveDown(_:)): (.down, false),
        #selector(moveUpAndModifySelection(_:)): (.up, true), #selector(moveDownAndModifySelection(_:)): (.down, true),
        #selector(moveToBeginningOfLine(_:)): (.lineStart, false), #selector(moveToLeftEndOfLine(_:)): (.lineStart, false),
        #selector(moveToEndOfLine(_:)): (.lineEnd, false), #selector(moveToRightEndOfLine(_:)): (.lineEnd, false),
        #selector(moveToBeginningOfLineAndModifySelection(_:)): (.lineStart, true),
        #selector(moveToLeftEndOfLineAndModifySelection(_:)): (.lineStart, true),
        #selector(moveToEndOfLineAndModifySelection(_:)): (.lineEnd, true),
        #selector(moveToRightEndOfLineAndModifySelection(_:)): (.lineEnd, true),
        #selector(moveToBeginningOfParagraph(_:)): (.paragraphStart, false),
        #selector(moveToEndOfParagraph(_:)): (.paragraphEnd, false),
        #selector(moveToBeginningOfParagraphAndModifySelection(_:)): (.paragraphStart, true),
        #selector(moveToEndOfParagraphAndModifySelection(_:)): (.paragraphEnd, true),
        #selector(moveParagraphBackwardAndModifySelection(_:)): (.paragraphStart, true),
        #selector(moveParagraphForwardAndModifySelection(_:)): (.paragraphEnd, true),
        #selector(moveToBeginningOfDocument(_:)): (.documentStart, false),
        #selector(moveToEndOfDocument(_:)): (.documentEnd, false),
        #selector(moveToBeginningOfDocumentAndModifySelection(_:)): (.documentStart, true),
        #selector(moveToEndOfDocumentAndModifySelection(_:)): (.documentEnd, true),
    ]
    private static let deletions: [Selector: Motion] = [
        #selector(deleteBackward(_:)): .left, #selector(deleteBackwardByDecomposingPreviousCharacter(_:)): .left,
        #selector(deleteForward(_:)): .right,
        #selector(deleteWordBackward(_:)): .wordLeft, #selector(deleteWordForward(_:)): .wordRight,
        #selector(deleteToBeginningOfLine(_:)): .lineStart, #selector(deleteToEndOfLine(_:)): .lineEnd,
        #selector(deleteToBeginningOfParagraph(_:)): .paragraphStart,
        #selector(deleteToEndOfParagraph(_:)): .paragraphEnd,
    ]

    override func doCommand(by selector: Selector) {
        if let move = Self.motions[selector] {
            model?.move(move.motion, extend: move.extend)
        } else if let motion = Self.deletions[selector] {
            model?.delete(motion, undoManager)
        } else {
            switch selector {
            case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)), #selector(insertParagraphSeparator(_:)):
                replaceSelection(with: "\n")
            case #selector(insertTab(_:)): replaceSelection(with: "\t")
            case #selector(pageUp(_:)): movePage(up: true, extend: false)
            case #selector(pageDown(_:)): movePage(up: false, extend: false)
            case #selector(pageUpAndModifySelection(_:)): movePage(up: true, extend: true)
            case #selector(pageDownAndModifySelection(_:)): movePage(up: false, extend: true)
            case #selector(scrollPageUp(_:)), #selector(scrollPageDown(_:)),
                 #selector(scrollToBeginningOfDocument(_:)), #selector(scrollToEndOfDocument(_:)):
                enclosingScrollView?.doCommand(by: selector)
            case #selector(cancelOperation(_:)): discardComposition()
            default:
                if responds(to: selector) { perform(selector, with: nil) } else { NSSound.beep() }
            }
        }
    }

    private func replaceSelection(with text: String) {
        model?.edit(undoManager) { selection in selection.map { .replace($0, text: text) } }
    }

    /// Moves the caret a screenful up or down, scrolling with it.
    private func movePage(up: Bool, extend: Bool) {
        guard let model, let caret = caretRect, let clip = enclosingScrollView?.contentView else { return }
        let step = clip.bounds.height * 0.9 * (up ? -1 : 1)
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: step)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        guard let hit = enginePoint(NSPoint(x: caret.midX, y: caret.midY + step)) else { return }
        model.select { model in
            let position = try await model.hitTest(page: hit.page, x: hit.point.x, y: hit.point.y)
            guard extend, let anchor = model.selection?.anchor else { return .caret(position) }
            return EditSelection(anchor: anchor, focus: position)
        }
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { copySelection(cut: false) }
    @objc func cut(_ sender: Any?) { copySelection(cut: true) }
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
        replaceSelection(with: text)
    }
    @objc func delete(_ sender: Any?) { replaceSelection(with: "") }
    /// Selects all text of the body or of the cell holding the caret.
    override func selectAll(_ sender: Any?) {
        model?.select { model in
            guard let focus = model.selection?.focus else { return nil }
            let start = try await model.navigate(from: focus, .documentStart).position
            let end = try await model.navigate(from: focus, .documentEnd).position
            return EditSelection(anchor: start, focus: end)
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

    /// Character format taken by 모양 복사, shared by all windows like the font pasteboard.
    private(set) static var copiedStyle: CharStyle?
    @objc func copyFont(_ sender: Any?) {
        guard let style = model?.format?.text else { return NSSound.beep() }
        Self.copiedStyle = style
    }
    @objc func pasteFont(_ sender: Any?) {
        guard let style = Self.copiedStyle else { return NSSound.beep() }
        model?.formatText(style, undoManager)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasRange = model?.selection.map { $0.anchor != $0.focus } ?? false
        switch item.action {
        case #selector(copyFont(_:)): return model?.format != nil
        case #selector(pasteFont(_:)): return hasRange && Self.copiedStyle != nil
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): return hasRange
        case #selector(paste(_:)): return model?.selection != nil && NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)): return model?.selection != nil
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
        guard let window, let rect = caretRect else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
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
