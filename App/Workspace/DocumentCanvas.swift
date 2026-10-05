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
    @objc private func viewChanged() {
        editor.placeCaret()
        onViewChange?()
    }
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
    /// A thin bar, one screen point wide at any zoom.
    private let caret = NSView()
    /// Called after each presentation is applied.
    var onPresent: (() -> Void)?
    /// Called to open the properties of an object (double-click or Return).
    var onOpenObject: ((PlacedObject) -> Void)?
    /// Hancom's keys for a block of cells: 셀 합치기 (M), 셀 나누기 (S), and 셀 높이 (H)
    /// or 너비 (W)를 같게. Called with the key.
    var onCellBlockKey: ((Character) -> Bool)?
    /// The 빠른 메뉴 for the selection, shown on a right click.
    var onContextMenu: (() -> [Choice?])?
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
        caret.wantsLayer = true
        caret.layer?.backgroundColor = NSColor.black.cgColor
        caret.isHidden = true
        addSubview(caret)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func bind(_ model: HwpDocument) {
        guard model !== self.model else { return }
        self.model = model
        shown = model.presentation
        observer = model.presented.sink { [weak self] in self?.sync() }
        layoutPages(force: true)
        needsDisplay = true
    }

    // MARK: Pages

    /// The 그리기 개체 being drawn (`textbox`, `rectangle`, `ellipse`, `line`, `arc`): the
    /// next drag on a page draws it. Esc stops.
    var drawingShape: String? {
        didSet {
            if drawingShape == nil { setRubber(nil) }
            updateCursor()
        }
    }
    /// The drag drawing a shape, in view points.
    private var rubber: (start: NSPoint, end: NSPoint)?
    private func setRubber(_ new: (start: NSPoint, end: NSPoint)?) {
        for band in [rubber, new].compactMap({ $0 }) {
            setNeedsDisplay(NSRect(points: band.start, band.end).insetBy(dx: -4, dy: -4))
        }
        rubber = new
    }
    /// 격자 보기: a 5 mm grid over the pages.
    var showsGrid = false {
        didSet { needsDisplay = true }
    }
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
            if showsGrid { drawGrid(in: frame, dirty: dirtyRect) }
        }
        let active = window?.isKeyWindow == true && window?.firstResponder === self
        (active ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor).setFill()
        for rect in highlightRects where rect.intersects(dirtyRect) {
            rect.fill(using: .multiply)
        }
        if let rect = objectRect, rect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) {
            drawHandles(around: rect)
        }
        if let rubber {
            let band = NSBezierPath()
            if drawingShape == "line" || { if case .border = drag { true } else { false } }() {
                band.move(to: rubber.start)
                band.line(to: rubber.end)
            } else if drawingShape == "ellipse" {
                band.appendOval(in: NSRect(points: rubber.start, rubber.end))
            } else {
                band.appendRect(NSRect(points: rubber.start, rubber.end))
            }
            band.lineWidth = 1 / (enclosingScrollView?.magnification ?? 1)
            NSColor.controlAccentColor.setStroke()
            band.stroke()
        }
    }
    private func drawGrid(in frame: NSRect, dirty: NSRect) {
        // ponytail: fixed 5 mm spacing; make it a setting when 격자 설정 is added.
        let step = 5 / 25.4 * 72
        let dot = 1.2 / (enclosingScrollView?.magnification ?? 1)
        let dots = NSBezierPath()
        // Only the dots in the dirty area, so typing redraws a few, not the whole page.
        let first = { (lower: CGFloat, origin: CGFloat) in origin + max(1, ((lower - origin) / step).rounded(.down)) * step }
        for x in stride(from: first(dirty.minX, frame.minX), to: min(frame.maxX, dirty.maxX + step), by: step) {
            for y in stride(from: first(dirty.minY, frame.minY), to: min(frame.maxY, dirty.maxY + step), by: step) {
                dots.appendRect(NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
            }
        }
        NSColor.systemIndigo.withAlphaComponent(0.6).setFill()
        dots.fill()
    }
    /// The frame and eight sizing handles of a selected object, one screen point thick.
    private func drawHandles(around rect: NSRect) {
        let scale = 1 / (enclosingScrollView?.magnification ?? 1)
        NSColor.controlAccentColor.setStroke()
        let frame = NSBezierPath(rect: rect)
        frame.lineWidth = scale
        frame.stroke()
        let side = 6 * scale
        for x in [rect.minX, rect.midX, rect.maxX] {
            for y in [rect.minY, rect.midY, rect.maxY] where x != rect.midX || y != rect.midY {
                let handle = NSBezierPath(rect: NSRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
                handle.lineWidth = scale
                NSColor.white.setFill()
                handle.fill()
                handle.stroke()
            }
        }
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    /// Points at what a press would do here: draw, size or move the selected object, move a
    /// table border, or place the caret.
    private func updateCursor(at point: NSPoint? = nil) {
        guard drag == nil, let point = point ?? window.map({ convert($0.mouseLocationOutsideOfEventStream, from: nil) })
        else { return }
        let cursor: NSCursor
        if drawingShape != nil {
            cursor = .crosshair
        } else if let rect = objectRect, let handle = handle(at: point, of: rect) {
            cursor = Self.resizeCursor(handle.x, handle.y)
        } else if let rect = objectRect, movable, rect.contains(point) {
            cursor = .arrow
        } else if let line = border(at: point) {
            cursor = Self.borderCursor(row: line.line.row)
        } else {
            cursor = pageFrames.contains { $0.contains(point) } ? .iBeam : .arrow
        }
        cursor.set()
    }
    private static func borderCursor(row: Bool) -> NSCursor {
        if #available(macOS 15, *) { return row ? .rowResize : .columnResize }
        return row ? .resizeUpDown : .resizeLeftRight
    }

    // MARK: Presentation

    private var highlightRects: [NSRect] { shown.highlight.compactMap(viewRect) }
    private var caretRect: NSRect? { shown.caret.flatMap(viewRect) }
    private var objectRect: NSRect? { shown.object.flatMap(viewRect) }

    private func viewRect(_ rect: PageRect) -> NSRect? {
        frame(ofPage: Int(rect.page)).map { PageGeometry.viewRect(rect, in: $0) }
    }

    /// Applies a new presentation: redraws the pages it changed and moves the highlight
    /// and caret in the same pass.
    private func sync() {
        guard let model, model.presentation.serial != shown.serial else { return }
        let oldObject = objectRect
        let old = highlightRects + [oldObject].compactMap { $0 }
        shown = model.presentation
        if shown.reflowed {
            layoutPages(force: true)
        } else {
            shown.changedPages.forEach { index in frame(ofPage: index).map { setNeedsDisplay($0) } }
        }
        (old + highlightRects + [objectRect].compactMap { $0 }).forEach { setNeedsDisplay($0.insetBy(dx: -6, dy: -6)) }
        if shown.reflowed || !shown.changedPages.isEmpty {
            (tableLines, loadingLines) = ([:], [])
            linesGeneration += 1
        }
        if oldObject != objectRect { updateCursor() }
        placeCaret()
        if let caretRect { scrollToVisible(caretRect.insetBy(dx: -24, dy: -24)) }
        onPresent?()
    }

    /// Shows the caret where the presentation puts it, solid for a moment, then blinking.
    func placeCaret() {
        let active = window?.isKeyWindow == true && window?.firstResponder === self
        guard active, let rect = caretRect, shown.highlight.isEmpty, shown.object == nil else {
            caret.isHidden = true
            return
        }
        let width = 1 / (enclosingScrollView?.magnification ?? 1)
        let frame = NSRect(x: rect.minX - width / 2, y: rect.minY, width: width, height: rect.height)
        guard caret.isHidden || caret.frame != frame else { return }
        caret.frame = frame
        caret.isHidden = false
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0]
        blink.keyTimes = [0, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1.06
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + 0.5
        caret.layer?.add(blink, forKey: "blink")
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
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        if drawingShape != nil { return setRubber((point, point)) }
        guard let model, let hit = enginePoint(point) else { return }
        window?.makeFirstResponder(self)
        commitComposition()
        let clicks = event.clickCount, extend = event.modifierFlags.contains(.shift)
        if clicks == 1, !extend {
            if let rect = objectRect, let handle = handle(at: point, of: rect) {
                drag = .resize(handle: handle, from: rect)
                return setRubber((rect.origin, NSPoint(x: rect.maxX, y: rect.maxY)))
            }
            if let rect = objectRect, movable, rect.contains(point) {
                // Moves once dragged; a plain click still clicks (into a 글상자's text).
                drag = .move(start: point, from: rect, moved: false, click: hit)
                return
            }
            if let found = border(at: point) {
                drag = .border(found.line, page: found.page, extent: found.extent, start: point, moved: false, click: hit)
                return
            }
        }
        click(model, hit, clicks: clicks, extend: extend, pressedAt: point)
    }

    /// A right click selects what is under it, unless it is inside the selection, then
    /// shows the 빠른 메뉴.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard drawingShape == nil, let model, let hit = enginePoint(point) else { return }
        window?.makeFirstResponder(self)
        commitComposition()
        if !(highlightRects + [objectRect].compactMap { $0 }).contains(where: { $0.contains(point) }) {
            click(model, hit, clicks: 1, extend: false)
        }
        Task { [weak self] in
            await model.settle()
            guard let self, let choices = onContextMenu?(), !choices.isEmpty else { return }
            NSMenu.popUpContextMenu(DropDown.menu(choices), with: event, for: self)
        }
    }

    private func click(_ model: HwpDocument, _ hit: (page: Int, point: CGPoint), clicks: Int, extend: Bool,
                       pressedAt point: NSPoint? = nil) {
        model.select { [weak self] model in
            let position = try? await model.hitTest(page: hit.page, x: hit.point.x, y: hit.point.y)
            // A click on an object selects it, except inside a 글상자, away from its edge,
            // where it places the caret in the box's text.
            if !extend, let object = try? await model.objectAt(page: hit.page, x: hit.point.x, y: hit.point.y),
               !(Self.inside(object.rect, hit.point) && position.map { Self.holds(object.object, $0) } == true) {
                model.object = object
                if clicks == 2 { self?.onOpenObject?(object) }
                // Still pressed: the drag that follows moves it.
                if clicks == 1, let self, let point, drag == nil, NSEvent.pressedMouseButtons & 1 == 1,
                   [.picture, .shape, .equation].contains(object.object.kind), let rect = viewRect(object.rect) {
                    drag = .move(start: point, from: rect, moved: false, click: nil)
                }
                return nil
            }
            guard let position else { throw EditError.unsupportedTarget }
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

    /// Whether `position` is in the text of the 글상자 `object`.
    private static func holds(_ object: ObjectRef, _ position: EditPosition) -> Bool {
        object.kind == .shape && position.target.paragraph == object.paragraph
            && position.target.cell?.control == object.control
    }
    /// Whether a point is inside a frame, away from its edge.
    private static func inside(_ rect: PageRect, _ point: CGPoint) -> Bool {
        let edge = 6.0
        return point.x > rect.x + edge && point.x < rect.x + rect.width - edge
            && point.y > rect.y + edge && point.y < rect.y + rect.height - edge
    }

    // MARK: Dragging objects and table borders

    /// A press on the selected object's handle (-1, 0 or 1 across and down), on the
    /// object itself, or on a table border, until the mouse goes up.
    private enum Drag {
        case resize(handle: (x: Int, y: Int), from: NSRect)
        /// `click` is where to click if it never moves.
        case move(start: NSPoint, from: NSRect, moved: Bool, click: (page: Int, point: CGPoint)?)
        /// `extent` is the table's span along the border, in view points.
        case border(TableLine, page: Int, extent: ClosedRange<CGFloat>, start: NSPoint, moved: Bool,
                    click: (page: Int, point: CGPoint))
    }
    private var drag: Drag?
    /// Table borders by page, loaded when the pointer first comes near; cleared on each change.
    private var tableLines: [Int: [TableLine]] = [:]
    private var loadingLines: Set<Int> = []
    /// Bumped when the borders are cleared, so a load started before then is dropped.
    private var linesGeneration = 0

    /// Pictures and 그리기 개체 have sizing handles; tables and equations size to their content.
    private var resizable: Bool { [.picture, .shape].contains(model?.object?.object.kind) }
    private var movable: Bool { [.picture, .shape, .equation].contains(model?.object?.object.kind) }

    private func handle(at point: NSPoint, of rect: NSRect) -> (x: Int, y: Int)? {
        guard resizable else { return nil }
        let reach = 5 / (enclosingScrollView?.magnification ?? 1)
        for x in -1...1 {
            for y in -1...1 where x != 0 || y != 0 {
                let center = NSPoint(x: rect.midX + CGFloat(x) * rect.width / 2, y: rect.midY + CGFloat(y) * rect.height / 2)
                if abs(point.x - center.x) <= reach, abs(point.y - center.y) <= reach { return (x, y) }
            }
        }
        return nil
    }
    private static func resizeCursor(_ x: Int, _ y: Int) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch (x, y) {
            case (-1, -1): .topLeft
            case (1, -1): .topRight
            case (-1, 1): .bottomLeft
            case (1, 1): .bottomRight
            case (_, -1): .top
            case (_, 1): .bottom
            case (-1, _): .left
            default: .right
            }
            return .frameResize(position: position, directions: .all)
        }
        return y == 0 ? .resizeLeftRight : x == 0 ? .resizeUpDown : .crosshair
    }

    /// The table border under a point, with the table's span along it. Loads the page's
    /// borders the first time and answers nil until they arrive.
    private func border(at point: NSPoint) -> (line: TableLine, page: Int, extent: ClosedRange<CGFloat>)? {
        guard !pageFrames.isEmpty else { return nil }
        let page = page(near: point), frame = pageFrames[page]
        guard frame.contains(point) else { return nil }
        guard let lines = tableLines[page] else {
            loadLines(page)
            return nil
        }
        let scale = PageGeometry.pointsPerPixel
        let reach = 3 / (enclosingScrollView?.magnification ?? 1)
        let (x, y) = (point.x - frame.minX, point.y - frame.minY)
        guard let line = lines.first(where: { line in
            let (across, along) = line.row ? (y, x) : (x, y)
            return abs(across - line.at * scale) <= reach && along >= line.from * scale && along <= line.to * scale
        }) else { return nil }
        let same = lines.filter { $0.table == line.table && $0.row == line.row && $0.line == line.line }
        let origin = line.row ? frame.minX : frame.minY
        let extent = origin + same.map(\.from).min()! * scale...origin + same.map(\.to).max()! * scale
        return (line, page, extent)
    }
    private func loadLines(_ page: Int) {
        guard let model, !loadingLines.contains(page) else { return }
        loadingLines.insert(page)
        let generation = linesGeneration
        Task { [weak self] in
            let lines = (try? await model.tableLines(page: page)) ?? []
            // Borders read before an edit landed would drag the wrong place.
            guard let self, generation == linesGeneration else { return }
            loadingLines.remove(page)
            tableLines[page] = lines
            updateCursor()
        }
    }
    /// The guide drawn while a border is dragged: the border at `at` (page pixels).
    private func guide(_ line: TableLine, page: Int, at: Double, extent: ClosedRange<CGFloat>) -> (start: NSPoint, end: NSPoint) {
        let frame = pageFrames[page], value = at * PageGeometry.pointsPerPixel
        return line.row
            ? (NSPoint(x: extent.lowerBound, y: frame.minY + value), NSPoint(x: extent.upperBound, y: frame.minY + value))
            : (NSPoint(x: frame.minX + value, y: extent.lowerBound), NSPoint(x: frame.minX + value, y: extent.upperBound))
    }
    /// Where a dragged border sits for a pointer: page pixels, at least 2 mm into its column (row).
    private func borderPosition(_ line: TableLine, page: Int, _ point: NSPoint) -> Double {
        let frame = pageFrames[page]
        let value = (line.row ? point.y - frame.minY : point.x - frame.minX) / PageGeometry.pointsPerPixel
        return max(value, line.start + 8)
    }

    /// The frame a handle drag gives: the opposite side stays; Shift on a corner keeps the ratio.
    private func resized(_ handle: (x: Int, y: Int), from: NSRect, to point: NSPoint, keepRatio: Bool) -> NSRect {
        var (minX, maxX, minY, maxY) = (from.minX, from.maxX, from.minY, from.maxY)
        if handle.x < 0 { minX = min(point.x, maxX - 1) } else if handle.x > 0 { maxX = max(point.x, minX + 1) }
        if handle.y < 0 { minY = min(point.y, maxY - 1) } else if handle.y > 0 { maxY = max(point.y, minY + 1) }
        var rect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if keepRatio, handle.x != 0, handle.y != 0, from.width > 0, from.height > 0 {
            let scale = max(rect.width / from.width, rect.height / from.height)
            let size = NSSize(width: from.width * scale, height: from.height * scale)
            rect = NSRect(x: handle.x < 0 ? from.maxX - size.width : from.minX,
                          y: handle.y < 0 ? from.maxY - size.height : from.minY, width: size.width, height: size.height)
        }
        return rect
    }
    /// Gives the selected object the frame `rect` (view points) it was dragged or sized to.
    /// A floating object placed from the left (top) moves by its offset; one placed
    /// otherwise, or a 글자처럼 취급 one, is placed on the paper where it was dropped.
    private func place(_ rect: NSRect, from: NSRect) {
        guard let model, let placed = model.object, rect != from,
              let frame = frame(ofPage: Int(placed.rect.page)) else { return }
        // View points are 1/72 inch; HWPUNIT is 1/7200 inch.
        let hwp = { (v: CGFloat) in Int32((v * 100).rounded()) }
        let undoManager = undoManager
        Task {
            guard let props = try? await model.objectProps(placed.object) else { return NSSound.beep() }
            var change = ObjectProps()
            if rect.size != from.size {
                (change.width, change.height) = (UInt32(max(1, hwp(rect.width))), UInt32(max(1, hwp(rect.height))))
            }
            let inline = props.treatAsChar == true
            if inline, rect.origin != from.origin {
                (change.treatAsChar, change.textWrap) = (false, "TopAndBottom")
            }
            if rect.minX != from.minX {
                if !inline, (props.horzAlign ?? "Left") == "Left" {
                    change.horzOffset = (props.horzOffset ?? 0) + hwp(rect.minX - from.minX)
                } else {
                    (change.horzRelTo, change.horzAlign, change.horzOffset) = ("Paper", "Left", hwp(rect.minX - frame.minX))
                }
            }
            if rect.minY != from.minY {
                if !inline, (props.vertAlign ?? "Top") == "Top" {
                    change.vertOffset = (props.vertOffset ?? 0) + hwp(rect.minY - from.minY)
                } else {
                    (change.vertRelTo, change.vertAlign, change.vertOffset) = ("Paper", "Top", hwp(rect.minY - frame.minY))
                }
            }
            model.edit(undoManager) { _ in .setObject(placed.object, change) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let current = drag {
            drag = nil
            setRubber(nil)
            defer { updateCursor(at: point) }
            switch current {
            case let .resize(handle, from):
                place(resized(handle, from: from, to: point, keepRatio: event.modifierFlags.contains(.shift)), from: from)
            case let .move(start, from, moved, click):
                if moved {
                    place(from.offsetBy(dx: point.x - start.x, dy: point.y - start.y), from: from)
                } else if let click, let model {
                    self.click(model, click, clicks: 1, extend: false)
                }
            case let .border(line, page, _, _, moved, click):
                guard let model else { return }
                guard moved else { return self.click(model, click, clicks: 1, extend: false) }
                let size = (borderPosition(line, page: page, point) - line.start) * 75
                model.edit(undoManager) { _ in .resizeTable(line.table, row: line.row, line: line.line, size: UInt32(size.rounded())) }
            }
            return
        }
        guard let shape = drawingShape, let band = rubber, let model, !pageFrames.isEmpty else { return }
        drawingShape = nil
        let index = page(near: band.start)
        let frame = pageFrames[index]
        let start = PageGeometry.enginePoint(band.start, in: frame)
        var end = PageGeometry.enginePoint(band.end, in: frame)
        // A click without a drag draws Hancom's default size, 30 × 20 mm.
        if hypot(end.x - start.x, end.y - start.y) < 4 {
            end = CGPoint(x: start.x + 113, y: start.y + (shape == "line" ? 0 : 76))
        }
        model.insertShape(shape, page: index, from: start, to: end, undoManager)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case let .resize(handle, from):
            let rect = resized(handle, from: from, to: point, keepRatio: event.modifierFlags.contains(.shift))
            return setRubber((rect.origin, NSPoint(x: rect.maxX, y: rect.maxY)))
        case let .move(start, from, moved, click):
            guard moved || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            drag = .move(start: start, from: from, moved: true, click: click)
            NSCursor.closedHand.set()
            let rect = from.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            return setRubber((rect.origin, NSPoint(x: rect.maxX, y: rect.maxY)))
        case let .border(line, page, extent, start, moved, click):
            guard moved || hypot(point.x - start.x, point.y - start.y) > 2 else { return }
            drag = .border(line, page: page, extent: extent, start: start, moved: true, click: click)
            return setRubber(guide(line, page: page, at: borderPosition(line, page: page, point), extent: extent))
        case nil:
            break
        }
        if let band = rubber {
            return setRubber((band.start, point))
        }
        autoscroll(with: event)
        pendingDrag = point
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
            // A press that selected an object drags the object, never the text.
            guard model.object == nil, let anchor = model.selection?.anchor else { return nil }
            let position = try await model.hitTest(page: hit.page, x: hit.point.x, y: hit.point.y)
            return EditSelection(anchor: anchor, focus: position)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard model?.selection != nil else { return super.keyDown(with: event) }
        NSCursor.setHiddenUntilMouseMoves(true)
        if model?.context.cellBlock == true, event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
           let key = event.charactersIgnoringModifiers?.lowercased().first, onCellBlockKey?(key) == true {
            return
        }
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
        if drawingShape != nil, selector == #selector(cancelOperation(_:)) {
            drawingShape = nil
            return
        }
        if let object = model?.object {
            switch selector {
            case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
                return model?.edit(undoManager) { _ in .deleteObject(object.object) } ?? ()
            case #selector(insertNewline(_:)): return onOpenObject?(object) ?? ()
            case #selector(cancelOperation(_:)): return model?.deselectObject() ?? ()
            default: break
            }
        }
        if let move = Self.motions[selector] {
            commitComposition()
            model?.move(move.motion, extend: move.extend)
        } else if let motion = Self.deletions[selector] {
            commitComposition()
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
        commitComposition()
        model?.edit(undoManager) { selection in selection.map { .replace($0, text: text) } }
    }

    /// Moves the caret a screenful up or down, scrolling with it.
    private func movePage(up: Bool, extend: Bool) {
        commitComposition()
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
    /// Pastes text, or else an image as a picture.
    @objc func paste(_ sender: Any?) {
        commitComposition()
        let board = NSPasteboard.general
        if let text = board.string(forType: .string) {
            replaceSelection(with: text)
        } else if let image = NSImage(pasteboard: board), let data = image.tiffRepresentation {
            model?.insertPicture(data, name: "", undoManager)
        } else {
            NSSound.beep()
        }
    }
    @objc func delete(_ sender: Any?) { replaceSelection(with: "") }
    /// Selects all text of the body or of the cell holding the caret.
    override func selectAll(_ sender: Any?) {
        commitComposition()
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
        case #selector(paste(_:)):
            return model?.selection != nil && (NSPasteboard.general.string(forType: .string) != nil || NSImage.canInit(with: .general))
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
        format(CharStyle(size: max(1, size + step)))
    }
    /// 한 수준 증가 (or 감소) for the selected list paragraphs.
    func stepLevel(by step: Int) {
        guard let level = model?.format?.paragraph.level else { return NSSound.beep() }
        format(ParaStyle(level: min(max(level + step, 0), 6)))
    }
    func format(_ style: CharStyle) { model?.formatText(style, undoManager) }
    func format(_ style: ParaStyle) { model?.formatParagraphs(style, undoManager) }

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
    /// Index of the paragraph within its container (body, cell or note).
    var index: UInt32 { cell?.paragraph ?? note?.paragraph ?? paragraph }
    func offset(by delta: Int) -> EditTarget {
        var target = self
        let value = UInt32(max(0, Int(index) + delta))
        if target.cell != nil {
            target.cell?.paragraph = value
        } else if target.note != nil {
            target.note?.paragraph = value
        } else {
            target.paragraph = value
        }
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

private extension NSRect {
    /// The rectangle with two opposite corners.
    init(points a: NSPoint, _ b: NSPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
