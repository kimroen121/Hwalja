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
        center.addObserver(self, selector: #selector(startedMagnifying), name: NSScrollView.willStartLiveMagnifyNotification, object: self)
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
        // AppKit can scale what was drawn at the old zoom instead of drawing it again,
        // which blurs it until something redraws (as a click does).
        if !magnifying, magnification != drawnMagnification {
            drawnMagnification = magnification
            editor.needsDisplay = true
        }
        editor.placeCaret()
        if showsRuler { needsRulers() }
        onViewChange?()
    }

    /// 눈금자: rulers counting from the page in view, its body's edges and the caret
    /// paragraph's 들여쓰기 marked; dragging a mark changes them.
    var showsRuler: Bool {
        get { showsHorizontalRuler || showsVerticalRuler }
        set { (showsHorizontalRuler, showsVerticalRuler) = (newValue, newValue) }
    }
    /// 가로 눈금자 and 세로 눈금자, shown apart as 보기 › 문서 창 does.
    var showsHorizontalRuler = false {
        didSet { rulersChanged() }
    }
    var showsVerticalRuler = false {
        didSet { rulersChanged() }
    }
    private func rulersChanged() {
        hasHorizontalRuler = showsHorizontalRuler
        hasVerticalRuler = showsVerticalRuler
        rulersVisible = showsRuler
        // Since macOS 14 views draw past their bounds; the ruler's edge line would run up over the tools.
        horizontalRulerView?.clipsToBounds = true
        verticalRulerView?.clipsToBounds = true
        needsRulers()
    }
    /// Without 쪽 윤곽 the rulers show the margins but cannot change them, as in 한글.
    var showsMargins = true {
        didSet { needsRulers() }
    }
    private var rulersPending = false
    /// Places the rulers once, after the layout that asked: changing them lays the view out again.
    func needsRulers() {
        guard !rulersPending else { return }
        rulersPending = true
        DispatchQueue.main.async { [weak self] in
            self?.rulersPending = false
            self?.placeRulers()
        }
    }
    /// The page setup the markers show, with the section and revision it was read at.
    private var rulerPage: (section: UInt32, revision: UInt64, page: PageSetup)?

    private func placeRulers() {
        guard showsRuler, let model = editor.model else { return }
        let across = showsHorizontalRuler ? horizontalRulerView : nil, down = showsVerticalRuler ? verticalRulerView : nil
        let visible = documentVisibleRect
        guard let page = editor.frame(ofPage: editor.page(near: NSPoint(x: visible.midX, y: visible.midY))) else { return }
        // Markers need the view they measure.
        if let across, across.clientView !== editor { across.clientView = editor }
        if let down, down.clientView !== editor { down.clientView = editor }
        across?.originOffset = page.minX
        down?.originOffset = page.minY
        let section = model.selection?.focus.target.section ?? 0
        guard let setup = rulerPage, setup.section == section, setup.revision == model.revision else {
            across?.markers = nil
            down?.markers = nil
            let revision = model.revision
            Task { [weak self] in
                guard let setup = try? await model.pageSetup(section: section) else { return }
                self?.rulerPage = (section, revision, setup)
                self?.needsRulers()
            }
            return
        }
        // Markers sit in the editor's coordinates; HWPUNIT to points. The body starts below
        // the 머리말 and ends above the 꼬리말.
        let points = { (units: UInt32) in CGFloat(units) / 100 }
        let p = setup.page
        let left = page.minX + points(p.marginLeft + p.marginGutter), right = page.maxX - points(p.marginRight)
        func marker(_ ruler: NSRulerView, _ at: CGFloat, _ symbol: String, _ mark: RulerMark) -> NSRulerMarker? {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .regular)) else { return nil }
            let marker = NSRulerMarker(rulerView: ruler, markerLocation: at, image: image,
                                       imageOrigin: NSPoint(x: image.size.width / 2, y: 0))
            marker.isMovable = !model.context.locked && (showsMargins || ![.left, .right, .top, .bottom].contains(mark))
            marker.representedObject = mark.rawValue as NSString
            return marker
        }
        if let across {
            var marks = [marker(across, left, "arrowtriangle.down.fill", .left),
                         marker(across, right, "arrowtriangle.down.fill", .right)]
            // The caret paragraph's 왼쪽·오른쪽 여백 and 첫 줄 들여쓰기 (내어쓰기 when negative).
            if let para = model.format?.paragraph, let start = para.marginLeft, let end = para.marginRight, let first = para.indent {
                marks += [marker(across, left + start + first, "arrowtriangle.down", .firstLine),
                          marker(across, left + start, "arrowtriangle.up", .indentLeft),
                          marker(across, right - end, "arrowtriangle.up", .indentRight)]
            }
            across.markers = marks.compactMap { $0 }
        }
        if let down {
            down.markers = [marker(down, page.minY + points(p.marginTop + p.marginHeader), "arrowtriangle.right.fill", .top),
                            marker(down, page.maxY - points(p.marginBottom + p.marginFooter), "arrowtriangle.right.fill", .bottom)]
                .compactMap { $0 }
        }
    }
    enum RulerMark: String { case left, right, top, bottom, firstLine, indentLeft, indentRight }

    /// A dragged mark changes the page's 여백 or the paragraphs' 들여쓰기.
    fileprivate func moved(_ marker: NSRulerMarker) {
        guard let raw = marker.representedObject as? String, let mark = RulerMark(rawValue: raw), let model = editor.model,
              let setup = rulerPage, let page = editor.frame(ofPage: editor.page(near: NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)))
        else { return }
        let at = marker.markerLocation
        let units = { (points: CGFloat) in UInt32(max(0, (points * 100).rounded())) }
        var p = setup.page
        let left = page.minX + CGFloat(p.marginLeft + p.marginGutter) / 100, right = page.maxX - CGFloat(p.marginRight) / 100
        // Half a point, as 한글's 문단 모양 shows them.
        let half = { (points: CGFloat) in Double((points * 2).rounded() / 2) }
        switch mark {
        case .left: p.marginLeft = units(at - page.minX) - min(p.marginGutter, units(at - page.minX))
        case .right: p.marginRight = units(page.maxX - at)
        case .top: p.marginTop = units(at - page.minY) - min(p.marginHeader, units(at - page.minY))
        case .bottom: p.marginBottom = units(page.maxY - at) - min(p.marginFooter, units(page.maxY - at))
        case .firstLine, .indentLeft, .indentRight:
            guard let para = model.format?.paragraph, let start = para.marginLeft, let first = para.indent else { return }
            switch mark {
            case .firstLine: editor.format(ParaStyle(indent: half(at - left - start)))
            // The first line stays where it was.
            case .indentLeft: editor.format(ParaStyle(marginLeft: half(at - left), indent: half(left + start + first - at)))
            default: editor.format(ParaStyle(marginRight: half(right - at)))
            }
            return
        }
        guard p != setup.page else { return }
        model.edit(editor.undoManager) { _ in .setPage(section: setup.section, p) }
    }
    /// The zoom the pages were last drawn at, and whether a pinch is under way.
    private var drawnMagnification: CGFloat = 0
    private var magnifying = false
    @objc private func startedMagnifying() { magnifying = true }
    @objc private func userMagnified() {
        fit = nil
        magnifying = false
        viewChanged()
    }

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
        guard let frame = editor.clip(ofPage: page) else { return }
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
    /// Between pages without 쪽 윤곽: white, a dashed line across.
    static let draftGap: CGFloat = 8

    private(set) var model: HwpDocument?
    private var observer: AnyCancellable?
    /// Each page's frame, its origin where the page's top-left corner is drawn.
    private var pageFrames: [NSRect] = []
    /// The part of each page in view: the whole page, or its body without 쪽 윤곽.
    private var pageClips: [NSRect] = []
    private var shown = Presentation()
    /// A thin bar, one screen point wide at any zoom.
    private let caret = NSView()
    /// Where the object in the line being dragged would land, shown as a faint caret.
    private let dropCaret = NSView()
    private var pendingDrop: NSPoint?
    private var findingDrop = false
    /// Called after each presentation is applied.
    var onPresent: (() -> Void)?
    /// Called to open the properties of an object (double-click or Return).
    var onOpenObject: ((PlacedObject) -> Void)?
    /// Hancom's keys for a block of cells: 셀 합치기 (M), 셀 나누기 (S), and 셀 높이 (H)
    /// or 너비 (W)를 같게. Called with the key.
    var onKey: ((NSEvent) -> Bool)?
    /// The 빠른 메뉴 for the selection, shown on a right click.
    var onContextMenu: (() async -> [Choice?])?
    /// The input method's composing text as last reported; the document already shows it.
    private var markedText = ""
    /// Latest drag point waiting for the hit test in flight.
    private var pendingDrag: NSPoint?
    /// Last pointer position whose hit belongs to the selection anchor's container.
    private var selectionDragPoint: NSPoint?
    private var hitTesting = false
    /// Injectable so editor tests never overwrite the user's system clipboard.
    var pasteboard = NSPasteboard.general

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func rulerView(_ ruler: NSRulerView, didMove marker: NSRulerMarker) {
        (enclosingScrollView as? DocumentCanvas)?.moved(marker)
    }

    init() {
        super.init(frame: .zero)
        // Pages are white paper in any mode, so highlight and caret use light-mode colors.
        appearance = NSAppearance(named: .aqua)
        caret.wantsLayer = true
        caret.layer?.backgroundColor = NSColor.black.cgColor
        caret.isHidden = true
        addSubview(caret)
        dropCaret.wantsLayer = true
        dropCaret.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dropCaret.isHidden = true
        addSubview(dropCaret)
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
    /// next drag on a page draws it; with `select` (개체 선택) it chooses the objects inside
    /// it instead. Esc stops.
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
    /// 쪽 윤곽: whole pages apart; off, only their bodies, one after another.
    var showsOutline = true {
        didSet { layoutPages(force: true) }
    }
    /// Size of one row of pages, for fitting it to the window.
    var spread: NSSize? {
        guard !pageClips.isEmpty else { return nil }
        let width = pageClips.map(\.width).max()!, n = CGFloat(min(columns, pageClips.count))
        return NSSize(width: width * n + Self.gap * (n - 1), height: pageClips.map(\.height).max()!)
    }
    func frame(ofPage index: Int) -> NSRect? {
        pageFrames.indices.contains(index) ? pageFrames[index] : nil
    }
    /// The part of the page in view.
    func clip(ofPage index: Int) -> NSRect? {
        pageClips.indices.contains(index) ? pageClips[index] : nil
    }
    func page(near point: NSPoint) -> Int {
        pageClips.enumerated().min { distance($0.element, point) < distance($1.element, point) }?.offset ?? 0
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
        guard let model else { return }
        // The shown part of each page, in page points.
        let parts = model.pages.indices.map { index in
            let size = model.pages[index].size
            guard !showsOutline, model.bodies.indices.contains(index) else { return NSRect(origin: .zero, size: size) }
            return PageGeometry.viewRect(model.bodies[index], in: .zero)
        }
        let slot = parts.map(\.width).max() ?? 0
        let columns = max(1, min(columns, parts.count))
        let rowGap = showsOutline ? Self.gap : Self.draftGap
        let width = slot * CGFloat(columns) + Self.gap * CGFloat(columns - 1) + Self.margin * 2
        var frames: [NSRect] = [], clips: [NSRect] = []
        var y = Self.margin
        for row in stride(from: 0, to: parts.count, by: columns) {
            let rowParts = parts[row..<min(row + columns, parts.count)]
            for (column, part) in rowParts.enumerated() {
                let x = (Self.margin + CGFloat(column) * (slot + Self.gap) + (slot - part.width) / 2).rounded()
                clips.append(NSRect(x: x, y: y, width: part.width, height: part.height))
                let size = model.pages[row + column].size
                frames.append(NSRect(x: x - part.minX, y: y - part.minY, width: size.width, height: size.height))
            }
            y += rowParts.map(\.height).max()! + rowGap
        }
        let size = NSSize(width: width, height: y - rowGap + Self.margin)
        guard force || frames != pageFrames || clips != pageClips || size != frame.size else { return }
        (pageFrames, pageClips) = (frames, clips)
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
        for (index, clip) in pageClips.enumerated() where clip.insetBy(dx: -4, dy: -Self.draftGap).intersects(dirtyRect) {
            NSGraphicsContext.saveGraphicsState()
            if showsOutline { shadow.set() }
            NSColor.white.setFill()
            clip.fill()
            NSGraphicsContext.restoreGraphicsState()
            if pages.indices.contains(index) {
                context.saveGState()
                context.clip(to: clip)
                pages[index].draw(in: context, rect: pageFrames[index])
                context.restoreGState()
            }
            if !showsOutline, index >= columns {
                NSColor.white.setFill()
                NSRect(x: clip.minX, y: clip.minY - Self.draftGap, width: clip.width, height: Self.draftGap).fill()
                let line = NSBezierPath(), y = clip.minY - Self.draftGap / 2
                line.move(to: NSPoint(x: clip.minX, y: y))
                line.line(to: NSPoint(x: clip.maxX, y: y))
                // One device pixel at any zoom.
                line.lineWidth = 1 / ((window?.backingScaleFactor ?? 2) * (enclosingScrollView?.magnification ?? 1))
                line.setLineDash([3 * line.lineWidth, 3 * line.lineWidth], count: 2, phase: 0)
                NSColor.gray.setStroke()
                line.stroke()
            }
            if showsGrid { drawGrid(in: clip, dirty: dirtyRect) }
        }
        let active = window?.isKeyWindow == true && window?.firstResponder === self
        (active ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor).setFill()
        for rect in highlightRects where rect.intersects(dirtyRect) {
            rect.fill(using: .multiply)
        }
        if let rect = objectRect, rect.insetBy(dx: -8, dy: -8).intersects(dirtyRect) {
            drawHandles(around: rect)
        }
        // The other chosen objects: their frames, the handles being the 기준 개체's.
        for rect in otherRects where rect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) {
            let frame = NSBezierPath(rect: rect)
            frame.lineWidth = 1 / (enclosingScrollView?.magnification ?? 1)
            NSColor.controlAccentColor.setStroke()
            frame.stroke()
        }
        if let rubber {
            let band = NSBezierPath()
            if drawingShape == "line" || {
                switch drag {
                case .border, .lineEnd: true
                default: false
                }
            }() {
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
    /// The frame and eight sizing handles of a selected object, one screen point thick; a
    /// 직선 has a handle at each end instead.
    private func drawHandles(around rect: NSRect) {
        let scale = 1 / (enclosingScrollView?.magnification ?? 1)
        NSColor.controlAccentColor.setStroke()
        if let ends = lineEnds {
            let side = 6 * scale
            for end in [ends.start, ends.end] {
                let handle = NSBezierPath(rect: NSRect(x: end.x - side / 2, y: end.y - side / 2, width: side, height: side))
                handle.lineWidth = scale
                NSColor.white.setFill()
                handle.fill()
                handle.stroke()
            }
            return
        }
        let frame = NSBezierPath(rect: rect)
        frame.lineWidth = scale
        frame.stroke()
        let side = 6 * scale
        guard resizable else { return }
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
        } else if lineEnd(at: point) != nil {
            cursor = .crosshair
        } else if let rect = objectRect, let handle = handle(at: point, of: rect) {
            cursor = Self.resizeCursor(handle.x, handle.y)
        } else if let rect = objectRect, movable, rect.contains(point) {
            cursor = .arrow
        } else if let line = border(at: point) {
            cursor = Self.borderCursor(row: line.line.row)
        } else if object(at: point) != nil {
            cursor = .arrow
        } else {
            cursor = pageClips.contains { $0.contains(point) } ? .iBeam : .arrow
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
    private var otherRects: [NSRect] { shown.others.compactMap(viewRect) }
    /// The selected 직선's start and end in view points.
    private var lineEnds: (start: NSPoint, end: NSPoint)? {
        guard let ends = shown.lineEnds, ends.count == 4, let page = shown.object?.page,
              let frame = frame(ofPage: Int(page)) else { return nil }
        let point = { (x: Double, y: Double) in
            NSPoint(x: frame.minX + x * PageGeometry.pointsPerPixel, y: frame.minY + y * PageGeometry.pointsPerPixel)
        }
        return (point(ends[0], ends[1]), point(ends[2], ends[3]))
    }
    /// The 직선 end under a point: true for its end, false for its start.
    private func lineEnd(at point: NSPoint) -> Bool? {
        guard let ends = lineEnds, model?.presentation.objectLocked != true else { return nil }
        let reach = 5 / (enclosingScrollView?.magnification ?? 1)
        let near = { (end: NSPoint) in abs(point.x - end.x) <= reach && abs(point.y - end.y) <= reach }
        return near(ends.end) ? true : near(ends.start) ? false : nil
    }

    private func viewRect(_ rect: PageRect) -> NSRect? {
        frame(ofPage: Int(rect.page)).map { PageGeometry.viewRect(rect, in: $0) }
    }

    /// Applies a new presentation: redraws the pages it changed and moves the highlight
    /// and caret in the same pass.
    private func sync() {
        guard let model, model.presentation.serial != shown.serial else { return }
        let oldObject = objectRect
        let old = highlightRects + otherRects + [oldObject].compactMap { $0 }
        shown = model.presentation
        if shown.reflowed {
            layoutPages(force: true)
        } else {
            // A changed page may have a new size (용지 방향) or body.
            layoutPages()
            shown.changedPages.forEach { index in clip(ofPage: index).map { setNeedsDisplay($0) } }
        }
        (old + highlightRects + otherRects + [objectRect].compactMap { $0 }).forEach { setNeedsDisplay($0.insetBy(dx: -6, dy: -6)) }
        if shown.reflowed || !shown.changedPages.isEmpty {
            (tableLines, pageObjects, loadingLines) = ([:], [:], [])
            linesGeneration += 1
        }
        if oldObject != objectRect { updateCursor() }
        placeCaret()
        // A selected object's caret is at its anchor, which may be far from it: the view
        // moves only when none of the object shows.
        if let objectRect {
            if !visibleRect.intersects(objectRect) { scrollToVisible(objectRect) }
        } else if let caretRect {
            scrollToVisible(caretRect.insetBy(dx: -24, dy: -24))
        }
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
        selectionDragPoint = point
        if drawingShape != nil { return setRubber((point, point)) }
        guard let model, let hit = enginePoint(point) else { return }
        window?.makeFirstResponder(self)
        commitComposition()
        let clicks = event.clickCount, extend = event.modifierFlags.contains(.shift)
        if clicks == 1, event.modifierFlags.contains(.option) { return cycleObjects(model, hit) }
        if clicks == 1, !extend {
            if let end = lineEnd(at: point), let ends = lineEnds {
                let (from, other) = end ? (ends.end, ends.start) : (ends.start, ends.end)
                drag = .lineEnd(end: end, from: from, other: other)
                return setRubber((other, from))
            }
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
        if !(highlightRects + otherRects + [objectRect].compactMap { $0 }).contains(where: { $0.contains(point) }) {
            click(model, hit, clicks: 1, extend: false)
        }
        Task { [weak self] in
            await model.settle()
            guard let self, let choices = await onContextMenu?(), !choices.isEmpty else { return }
            NSMenu.popUpContextMenu(DropDown.menu(choices), with: event, for: self)
        }
    }

    private func click(_ model: HwpDocument, _ hit: (page: Int, point: CGPoint), clicks: Int, extend: Bool,
                       pressedAt point: NSPoint? = nil) {
        model.select { [weak self] model in
            let editingHeaderFooter = model.selection?.focus.target.isHeaderFooter == true
            let position = try? await model.hitTest(
                page: hit.page, x: hit.point.x, y: hit.point.y,
                includeHeaderFooter: clicks >= 2 || editingHeaderFooter
            )
            // A click on a 양식 개체 works it, as in 한/글 outside 양식 편집 상태.
            if clicks == 1, !extend, let form = try? await model.form(page: hit.page, x: hit.point.x, y: hit.point.y),
               form.enabled, form.kind != "PushButton" {
                self?.work(form, model)
                return nil
            }
            // A click on an object selects it, except inside a table or a 글상자, away from
            // its edge, where it places the caret in the cell or the box's text.
            // With <Shift>, a click on another object chooses it too.
            if position?.target.isHeaderFooter != true, !extend || model.object != nil,
               let object = try? await model.objectAt(page: hit.page, x: hit.point.x, y: hit.point.y),
               !(self?.inside(object.rect, hit.point) == true
                   && (object.object.kind == .table || position.map { Self.holds(object.object, $0) } == true)) {
                if extend {
                    model.choose(object)
                    return nil
                }
                model.object = object
                if clicks == 2 { self?.onOpenObject?(object) }
                // Still pressed: the drag that follows moves it.
                if clicks == 1, let self, let point, drag == nil, NSEvent.pressedMouseButtons & 1 == 1,
                   [.picture, .shape, .equation, .table].contains(object.object.kind), let rect = viewRect(object.rect) {
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

    /// 양식 개체: a 선택 상자 turns, a 라디오 단추 is chosen, a 콤보 상자 offers its items, and
    /// an 입력 상자 (or a 콤보 상자 without items) takes text.
    private func work(_ form: FormInfo, _ model: HwpDocument) {
        let set = { [weak self] (value: Int32?, text: String?) in
            model.edit(self?.undoManager) { _ in .setForm(form.form, value: value, text: text) }
        }
        switch form.kind {
        case "CheckBox": set(form.value == 0 ? 1 : 0, nil)
        case "RadioButton": if form.value == 0 { set(1, nil) }
        case "ComboBox" where !form.items.isEmpty:
            let menu = DropDown.menu(form.items.map { item in Choice(title: item, on: item == form.text) { set(nil, item) } })
            guard let rect = viewRect(form.rect) else { return }
            DispatchQueue.main.async { menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: self) }
        default:
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = form.name
                let field = NSTextField(string: form.text)
                field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
                alert.accessoryView = field
                alert.addButton(withTitle: "확인")
                alert.addButton(withTitle: "취소")
                alert.window.initialFirstResponder = field
                if alert.runModal() == .alertFirstButtonReturn { set(nil, field.stringValue) }
            }
        }
    }
    /// Whether `position` is in the text of the 글상자 `object`.
    private static func holds(_ object: ObjectRef, _ position: EditPosition) -> Bool {
        object.kind == .shape && position.target.paragraph == object.paragraph
            && position.target.cell?.control == object.control
    }
    /// Whether a point is inside a frame, away from its edge: 5 points on screen, at least 6 page pixels.
    private func inside(_ rect: PageRect, _ point: CGPoint) -> Bool {
        let edge = max(6, 5 / (enclosingScrollView?.magnification ?? 1) / PageGeometry.pointsPerPixel)
        return point.x > rect.x + edge && point.x < rect.x + rect.width - edge
            && point.y > rect.y + edge && point.y < rect.y + rect.height - edge
    }

    // MARK: Dragging objects and table borders

    /// A press on the selected object's handle (-1, 0 or 1 across and down), on the
    /// object itself, or on a table border, until the mouse goes up.
    private enum Drag {
        case resize(handle: (x: Int, y: Int), from: NSRect)
        /// A 직선's end (or start) dragged from `from`, the `other` end staying.
        case lineEnd(end: Bool, from: NSPoint, other: NSPoint)
        /// `click` is where to click if it never moves.
        case move(start: NSPoint, from: NSRect, moved: Bool, click: (page: Int, point: CGPoint)?)
        /// `extent` is the table's span along the border, in view points.
        case border(TableLine, page: Int, extent: ClosedRange<CGFloat>, start: NSPoint, moved: Bool,
                    click: (page: Int, point: CGPoint))
    }
    private var drag: Drag?
    /// Table borders by page, loaded when the pointer first comes near; cleared on each change.
    private var tableLines: [Int: [TableLine]] = [:]
    /// Objects by page, loaded with the borders.
    private var pageObjects: [Int: [PlacedObject]] = [:]
    private var loadingLines: Set<Int> = []
    /// Bumped when the borders are cleared, so a load started before then is dropped.
    private var linesGeneration = 0

    /// Pictures, 그리기 개체 and tables have sizing handles; equations size to their content.
    private var resizable: Bool {
        [.picture, .shape, .table].contains(model?.object?.object.kind) && model?.presentation.objectLocked != true && lineEnds == nil
    }
    /// An equation in a 미주 has only its properties to change.
    private var movable: Bool {
        [.picture, .shape, .equation, .table].contains(model?.object?.object.kind) && model?.object?.object.note == nil
    }

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
            loadLines(page, cursorAt: point)
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
    /// The object a press would choose under a point: not one of a table's cells or a
    /// 글상자's text, away from the edge. Answers nil until the page's objects arrive.
    private func object(at point: NSPoint) -> PlacedObject? {
        guard !pageFrames.isEmpty else { return nil }
        let page = page(near: point), frame = pageFrames[page]
        guard frame.contains(point), let objects = pageObjects[page] else { return nil }
        let at = PageGeometry.enginePoint(point, in: frame)
        guard let object = objects.last(where: {
            CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height).contains(at)
        }) else { return nil }
        let holdsText = object.object.kind == .table || object.textBox == true
        return holdsText && inside(object.rect, at) ? nil : object
    }
    private func loadLines(_ page: Int, cursorAt point: NSPoint) {
        guard let model, !loadingLines.contains(page) else { return }
        loadingLines.insert(page)
        let generation = linesGeneration
        Task { [weak self] in
            let lines = (try? await model.tableLines(page: page)) ?? []
            let objects = (try? await model.objects(page: page)) ?? []
            // Borders read before an edit landed would drag the wrong place.
            guard let self else { return }
            guard generation == linesGeneration else {
                updateCursor(at: point)
                return
            }
            loadingLines.remove(page)
            tableLines[page] = lines
            pageObjects[page] = objects
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

    /// A picture's corners keep its ratio and Shift frees them; a shape's corners are free and Shift keeps the ratio.
    private func keepsRatio(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.shift) != (model?.object?.object.kind == .picture)
    }
    /// The frame a handle drag gives: the opposite side stays.
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
    /// otherwise is placed on the paper where it was dropped. A 글자처럼 취급 equation moves
    /// into the text at `drop`; other 글자처럼 취급 objects only change size.
    private func place(_ rect: NSRect, from: NSRect, dropAt drop: NSPoint? = nil) {
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
            let inline = props.treatAsChar == true || placed.object.kind == .equation
            // An object in the line moves to the place in the text it is dropped on.
            if inline, rect.origin != from.origin, rect.size == from.size {
                guard let drop, let hit = enginePoint(drop) else { return }
                guard let target = try? await model.hitTest(page: hit.page, x: hit.point.x, y: hit.point.y) else {
                    return NSSound.beep()
                }
                model.edit(undoManager) { _ in .moveObject(placed.object, to: target) }
                return
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
            (pendingDrop, dropCaret.isHidden) = (nil, true)
            defer { updateCursor(at: point) }
            switch current {
            case let .resize(handle, from):
                place(resized(handle, from: from, to: point, keepRatio: keepsRatio(event)), from: from)
            case let .lineEnd(end, from, _):
                guard let model, let object = model.object?.object, hypot(point.x - from.x, point.y - from.y) > 1 else { return }
                // View points are 1/72 inch; HWPUNIT is 1/7200 inch.
                let (dx, dy) = (Int32(((point.x - from.x) * 100).rounded()), Int32(((point.y - from.y) * 100).rounded()))
                model.edit(undoManager) { _ in .moveLineEnd(object, end: end, dx: dx, dy: dy) }
            case let .move(start, from, moved, click):
                if moved {
                    place(from.offsetBy(dx: point.x - start.x, dy: point.y - start.y), from: from, dropAt: point)
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
        if drawingShape == nil, event.clickCount == 1, event.modifierFlags.intersection([.shift, .option, .command]).isEmpty {
            openLink()
        }
        guard let shape = drawingShape, let band = rubber, let model, !pageFrames.isEmpty else { return }
        drawingShape = nil
        if shape == "select" { return chooseObjects(in: band) }
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

    /// 하이퍼링크 이동: a click that left the caret in a link opens its web address.
    private func openLink() {
        guard let model else { return }
        Task {
            await model.settle()
            guard model.object == nil, let selection = model.selection, selection.anchor == selection.focus,
                  let link = try? await model.hyperlink(at: selection.focus),
                  Hyperlink.isWebAddress(link.uri), let url = URL(string: link.uri) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// 개체 선택: the objects wholly inside the drag (or touching it, by 설정) on the page where it ended, but tables
    /// and equations; a drag that does not move chooses what is under it.
    private func chooseObjects(in band: (start: NSPoint, end: NSPoint)) {
        guard let model, let hit = enginePoint(band.end) else { return }
        let frame = pageFrames[hit.page]
        let (a, b) = (PageGeometry.enginePoint(band.start, in: frame), PageGeometry.enginePoint(band.end, in: frame))
        let area = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        // In the selection queue, as a click, so the bars and frames follow.
        model.select { model in
            let all = try await model.objects(page: hit.page)
            if area.width < 2 && area.height < 2 {
                model.object = all.last { CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height).contains(b) }
                return nil
            }
            // 일부분 선택만으로 개체 전체 선택: an object the drag touches.
            let partial = UserDefaults.standard.bool(forKey: Saving.partialKey)
            let chosen = all.filter {
                let rect = CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height)
                return ![.table, .equation].contains($0.object.kind) && (partial ? area.intersects(rect) : area.contains(rect))
            }
            if chosen.isEmpty { NSSound.beep() } else { model.choose(all: chosen) }
            return nil
        }
    }
    /// <Alt> and a click: the objects under the point in turn, from the top down.
    private func cycleObjects(_ model: HwpDocument, _ hit: (page: Int, point: CGPoint)) {
        model.select { model in
            let under = try await model.objects(page: hit.page).reversed().filter {
                CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height).contains(hit.point)
            }
            guard !under.isEmpty else { return nil }
            let now = under.firstIndex { $0.object == model.object?.object }
            model.object = under[now.map { ($0 + 1) % under.count } ?? 0]
            return nil
        }
    }
    /// <Tab>: the next (or with <Shift>, previous) object on the selected one's page.
    private func nextObject(_ model: HwpDocument, _ current: PlacedObject, backward: Bool) {
        model.select { model in
            let all = try await model.objects(page: Int(current.rect.page))
            guard let at = all.firstIndex(where: { $0.object == current.object }), all.count > 1 else { return nil }
            model.object = all[(at + (backward ? all.count - 1 : 1)) % all.count]
            return nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case let .resize(handle, from):
            let rect = resized(handle, from: from, to: point, keepRatio: keepsRatio(event))
            return setRubber((rect.origin, NSPoint(x: rect.maxX, y: rect.maxY)))
        case let .lineEnd(_, _, other):
            return setRubber((other, point))
        case let .move(start, from, moved, click):
            guard moved || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            drag = .move(start: start, from: from, moved: true, click: click)
            NSCursor.closedHand.set()
            let rect = from.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            if shown.objectInLine {
                pendingDrop = point
                showDrop()
            }
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
    /// Moves the drop caret to the latest drag point, one hit test at a time.
    private func showDrop() {
        guard let model, !findingDrop, let point = pendingDrop, let hit = enginePoint(point) else { return }
        pendingDrop = nil
        findingDrop = true
        Task { @MainActor [weak self] in
            let position = try? await model.hitTest(page: hit.page, x: hit.point.x, y: hit.point.y)
            let rect = if let position { try? await model.caret(at: position) } else { PageRect?.none }
            guard let self else { return }
            findingDrop = false
            guard case .move = drag else { return }
            if let rect = rect.flatMap(viewRect) {
                let width = 1.5 / (enclosingScrollView?.magnification ?? 1)
                dropCaret.frame = NSRect(x: rect.minX - width / 2, y: rect.minY, width: width, height: rect.height)
                dropCaret.isHidden = false
            }
            showDrop()
        }
    }
    /// Extends the selection to the latest drag point, one hit test at a time, so a fast
    /// drag never queues stale points.
    private func extendToDrag() {
        guard let model, !hitTesting, let point = pendingDrag, let hit = enginePoint(point) else { return }
        let previousPoint = selectionDragPoint ?? point
        pendingDrag = nil
        hitTesting = true
        model.select { [weak self] model in
            defer {
                self?.hitTesting = false
                self?.extendToDrag()
            }
            // A press that selected an object drags the object, never the text.
            guard model.object == nil, let anchor = model.selection?.anchor else { return nil }
            let position = try await model.hitTest(
                page: hit.page, x: hit.point.x, y: hit.point.y,
                includeHeaderFooter: anchor.target.isHeaderFooter
            )
            let selection = EditSelection(anchor: anchor, focus: position)
            if selection.reaches(position) {
                self?.selectionDragPoint = point
                return selection
            }
            // A fast pointer can jump across the edge between the body, a table cell,
            // a note or a header. Find the last reachable hit on that path rather than
            // leaving the focus behind at an arbitrary character.
            guard let self else { return nil }
            var insidePoint = previousPoint
            var outsidePoint = point
            var insidePosition = model.selection?.focus ?? anchor
            for _ in 0..<12 {
                let middle = NSPoint(x: (insidePoint.x + outsidePoint.x) / 2,
                                     y: (insidePoint.y + outsidePoint.y) / 2)
                guard let middleHit = enginePoint(middle) else { break }
                let candidate = try await model.hitTest(
                    page: middleHit.page, x: middleHit.point.x, y: middleHit.point.y,
                    includeHeaderFooter: anchor.target.isHeaderFooter
                )
                if EditSelection(anchor: anchor, focus: candidate).reaches(candidate) {
                    insidePoint = middle
                    insidePosition = candidate
                } else {
                    outsidePoint = middle
                }
            }
            selectionDragPoint = insidePoint
            return EditSelection(anchor: anchor, focus: insidePosition)
        }
    }

    // MARK: Keyboard

    /// 쉴 때 자동 저장's wait, restarted by each key.
    private var resting: Task<Void, Never>?

    override func keyDown(with event: NSEvent) {
        guard model?.selection != nil || model?.object != nil else { return super.keyDown(with: event) }
        NSCursor.setHiddenUntilMouseMoves(true)
        resting?.cancel()
        resting = Saving.idle.map { seconds in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { Saving.rested(self?.window) }
            }
        }
        if onKey?(event) == true { return }
        // <F11> 개체 선택: the object at the caret, or the one before it in turn.
        if event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
           event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) == NSF11FunctionKey,
           let model {
            commitComposition()
            return model.select { model in
                guard let from = model.selection?.focus else { return nil }
                let found = try await model.previousObject(from: from, before: model.object?.object)
                if found == nil, model.object == nil { NSSound.beep() }
                model.object = found
                return nil
            }
        }
        // Home and End go to the line's ends, as in 한글, where macOS would scroll.
        if event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
           let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }),
           key == NSHomeFunctionKey || key == NSEndFunctionKey {
            commitComposition()
            return model?.move(key == NSHomeFunctionKey ? .lineStart : .lineEnd, extend: event.modifierFlags.contains(.shift)) ?? ()
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
            case #selector(insertTab(_:)), #selector(insertBacktab(_:)):
                guard let model else { return }
                return nextObject(model, object, backward: selector == #selector(insertBacktab(_:)))
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
        model?.linkTypedAddress(after: text, undoManager)
        model?.formatTypedList(after: text, undoManager)
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
            let position = try await model.hitTest(
                page: hit.page, x: hit.point.x, y: hit.point.y,
                includeHeaderFooter: model.selection?.focus.target.isHeaderFooter == true
            )
            guard extend, let anchor = model.selection?.anchor else { return .caret(position) }
            let selection = EditSelection(anchor: anchor, focus: position)
            return selection.reaches(position) ? selection : nil
        }
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { copySelection(cut: false) }
    @objc func cut(_ sender: Any?) { copySelection(cut: true) }
    /// This document's copy number on the pasteboard, as `copyID:number`.
    static let copyType = NSPasteboard.PasteboardType("app.hwalja.mac.copy")
    /// Pastes with formats (a copy of this document, else HTML), or text, or else an image
    /// as a picture.
    @objc func paste(_ sender: Any?) {
        commitComposition()
        let board = pasteboard
        let mark = board.string(forType: Self.copyType)?.split(separator: ":")
        let copy = mark.flatMap { $0.count == 2 && String($0[0]) == model?.copyID ? UInt64($0[1]) : nil }
        var html = board.string(forType: .html)
        let text = board.string(forType: .string)
        // Pages, TextEdit and Notes put rich text without HTML.
        if html == nil, copy == nil, board.availableType(from: [.rtfd, .rtf]) != nil,
           let rich = board.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString {
            html = Self.html(rich)
        }
        if copy != nil || html != nil || text != nil {
            model?.paste(copy: copy, html: html, text: text, undoManager)
        } else if let image = NSImage(pasteboard: board), let data = image.tiffRepresentation {
            model?.insertPicture(data, name: "", undoManager)
        } else {
            NSSound.beep()
        }
    }
    /// Rich text as the HTML the engine reads: a paragraph a line, each run with its font,
    /// size, color, bold, italic, underline and strikethrough.
    static func html(_ text: NSAttributedString) -> String {
        let string = text.string as NSString
        var html = ""
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, line, _, _ in
            html += "<p>"
            text.enumerateAttributes(in: line) { attributes, run, _ in
                var css = ""
                if let font = attributes[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    css += "font-family:'\(font.familyName ?? "")';font-size:\(font.pointSize)pt;"
                    if traits.contains(.bold) { css += "font-weight:bold;" }
                    if traits.contains(.italic) { css += "font-style:italic;" }
                }
                if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                    css += String(format: "color:#%02x%02x%02x;", Int(color.redComponent * 255), Int(color.greenComponent * 255),
                                  Int(color.blueComponent * 255))
                }
                if attributes[.underlineStyle] as? Int ?? 0 != 0 { css += "text-decoration:underline;" }
                if attributes[.strikethroughStyle] as? Int ?? 0 != 0 { css += "text-decoration:line-through;" }
                let escaped = string.substring(with: run).replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                html += "<span style=\"\(css)\">\(escaped)</span>"
            }
            html += "</p>"
        }
        return html
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
        if let model, let object = model.object?.object {
            Task {
                guard let copied = try? await model.copyObject(object) else { return NSSound.beep() }
                pasteboard.clearContents()
                pasteboard.setString("\(model.copyID):\(copied.copy)", forType: Self.copyType)
                if cut, model.object?.object == object { model.edit(undoManager) { _ in .deleteObject(object) } }
            }
            return
        }
        guard let model, let selection = model.selection, selection.anchor != selection.focus else { return NSSound.beep() }
        Task {
            guard let (text, copied) = try? await model.copy(selection) else { return NSSound.beep() }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if let copied {
                pasteboard.setString(copied.html, forType: .html)
                pasteboard.setString("\(model.copyID):\(copied.copy)", forType: Self.copyType)
            }
            // The selection may have moved while the text was read; never cut another range.
            if cut, model.selection == selection { replaceSelection(with: "") }
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
        let locked = model?.context.locked == true
        switch item.action {
        case #selector(copyFont(_:)): return model?.format != nil
        case #selector(pasteFont(_:)): return !locked && hasRange && Self.copiedStyle != nil
        case #selector(copy(_:)): return hasRange || model?.object != nil
        case #selector(cut(_:)): return !locked && (hasRange || model?.object != nil)
        case #selector(delete(_:)): return !locked && hasRange
        case #selector(paste(_:)):
            return !locked && model?.selection != nil
                && (pasteboard.availableType(from: [Self.copyType, .html, .string]) != nil || NSImage.canInit(with: pasteboard))
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
    var isHeaderFooter: Bool { headerFooter != nil }
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
