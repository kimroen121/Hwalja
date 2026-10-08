import PDFKit
import SwiftUI

/// One document window, laid out like Hancom Office Web below the macOS menu bar: the
/// 기본 and 서식 tool rows, then page thumbnails beside the pages, and a status bar.
struct DocumentWindow: View {
    let document: HwpDocument
    @StateObject private var viewer = Viewer()
    @State private var pageField = ""

    var body: some View {
        if document.creationFailed {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                HStack {
                    Button("다시 시도") { NSDocumentController.shared.newDocument(nil) }
                    Button("다른 문서 열기…") { NSDocumentController.shared.openDocument(nil) }
                }
            }
            .padding(32)
            .frame(minWidth: 480, minHeight: 300)
        } else {
            editor
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if viewer.showsTools {
                ToolRow(document: document, viewer: viewer)
                Divider()
            }
            if viewer.showsFormat {
                FormatRow(document: document, editor: viewer.canvas.editor)
                Divider()
            }
            if viewer.finding { FindBar(viewer: viewer) }
            HStack(spacing: 0) {
                if viewer.showsThumbnails {
                    PageThumbnails(document: document, viewer: viewer, position: viewer.position)
                        .frame(width: 150)
                    Divider()
                }
                Canvas(canvas: viewer.canvas, document: document)
                    .frame(minWidth: 480, minHeight: 400)
            }
            Divider()
            StatusBar(document: document, viewer: viewer, position: viewer.position)
        }
        .alert("찾아가기", isPresented: $viewer.goingToPage) {
            TextField("쪽", text: $pageField)
            Button("가기") { Int(pageField).map { viewer.go(toPage: $0 - 1) } }
            Button("취소", role: .cancel) {}
        }
        .sheet(isPresented: $viewer.insertingTable) { TableSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.splittingCells) { SplitCellSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.startingNumber) { NewNumberSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.bookmarking) { BookmarkSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.insertingSymbols) { SymbolSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.erasingCodes) { EraseCodesSheet(viewer: viewer) }
        .sheet(isPresented: Binding(get: { viewer.pageHide != nil }, set: { if !$0 { viewer.pageHide = nil } })) {
            if let hide = viewer.pageHide { PageHideSheet(viewer: viewer, hide: hide) }
        }
        .sheet(item: $viewer.documentInfo) { DocumentInfoSheet(info: $0) }
        .sheet(item: $viewer.equation) { EquationEditor(edit: $0, viewer: viewer, document: document) }
        .sheet(item: $viewer.objectSheet) { ObjectSheet(state: $0, viewer: viewer) }
        .sheet(isPresented: $viewer.editingCharShape) {
            CharShapeSheet(style: document.format?.text ?? CharStyle(), languages: document.format?.languages ?? [], viewer: viewer)
        }
        .sheet(isPresented: $viewer.editingParaShape) {
            ParaShapeSheet(style: document.format?.paragraph ?? ParaStyle(), viewer: viewer)
        }
        .sheet(isPresented: Binding(get: { viewer.editingList != nil }, set: { if !$0 { viewer.editingList = nil } })) {
            if let tab = viewer.editingList {
                ListSheet(style: document.format?.paragraph ?? ParaStyle(), body: document.context.inBody, tab: tab, viewer: viewer)
            }
        }
        .sheet(isPresented: Binding(get: { viewer.pageSetup != nil }, set: { if !$0 { viewer.pageSetup = nil } })) {
            if let setup = viewer.pageSetup { PageSetupSheet(section: setup.section, page: setup.page, viewer: viewer) }
        }
        .background(ClearTitleBar())
        .focusedSceneObject(document)
        .focusedSceneObject(viewer)
    }
}

/// Makes the title bar clear and drops its line, so the window's color runs on from it into
/// the tool box.
private struct ClearTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Watcher() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Watcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
    }
}

/// Page count, page in view and zoom.
private struct StatusBar: View {
    @ObservedObject var document: HwpDocument
    @ObservedObject var viewer: Viewer
    @ObservedObject var position: ViewPosition

    var body: some View {
        HStack(spacing: 4) {
            Text("\(position.page + 1) / \(document.context.pageCount)쪽")
                .monospacedDigit()
            Spacer()
            ToolIcon("쪽 윤곽", symbol: "doc", on: viewer.showsOutline) { viewer.showsOutline.toggle() }
            ToolIcon("축소", symbol: "minus.magnifyingglass") { viewer.canvas.zoomOut(nil) }
            Menu("\(position.zoomPercent)%") { ZoomItems(viewer: viewer, position: position) }
                .menuStyle(.borderlessButton)
                .monospacedDigit()
                .fixedSize()
            ToolIcon("확대", symbol: "plus.magnifyingglass") { viewer.canvas.zoomIn(nil) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}

/// Zoom choices shared by the status bar and the View menu.
struct ZoomItems: View {
    let viewer: Viewer
    @ObservedObject var position: ViewPosition

    var body: some View {
        ForEach([50, 75, 100, 125, 150, 200, 300], id: \.self) { percent in
            Toggle("\(percent)%", isOn: Binding(get: { position.zoomPercent == percent && viewer.canvas.fit == nil },
                                                set: { _ in viewer.canvas.setZoom(CGFloat(percent) / 100) }))
        }
        Divider()
        Toggle("쪽 맞춤", isOn: Binding(get: { viewer.canvas.fit == .page }, set: { _ in viewer.canvas.fit(.page) }))
        Toggle("폭 맞춤", isOn: Binding(get: { viewer.canvas.fit == .width }, set: { _ in viewer.canvas.fit(.width) }))
    }
}

/// Page in view and zoom. Kept apart from `Viewer` because they change on every scroll.
@MainActor
final class ViewPosition: ObservableObject {
    /// Zero-based page in view.
    @Published fileprivate(set) var page = 0
    @Published fileprivate(set) var zoomPercent = 100
}

/// Owns the window's canvas and the state of its bars and sheets.
@MainActor
final class Viewer: ObservableObject {
    let canvas = DocumentCanvas(frame: .zero)
    let position = ViewPosition()
    /// Pages side by side.
    /// Pages side by side; more than one turns 쪽 윤곽 on, as 한글's 여러 쪽 보기 does.
    @Published var columns = 1 {
        didSet {
            canvas.columns = columns
            if columns > 1 { showsOutline = true }
        }
    }
    @Published var showsTools = true
    @Published var showsFormat = true
    @Published var showsThumbnails = true
    /// 표시/숨기기.
    @Published var showsControlCodes = false {
        didSet { showMarks() }
    }
    @Published var showsParagraphMarks = false {
        didSet { showMarks() }
    }
    @Published var showsTransparentLines = false {
        didSet { showMarks() }
    }
    @Published var showsGrid = false {
        didSet { canvas.editor.showsGrid = showsGrid }
    }
    @Published var showsRuler = false {
        didSet { canvas.showsRuler = showsRuler }
    }
    /// 쪽 윤곽, remembered for new windows and the next launch as 한글 does.
    @Published var showsOutline = UserDefaults.standard.object(forKey: "showsOutline") as? Bool ?? true {
        didSet {
            canvas.editor.showsOutline = showsOutline
            canvas.showsMargins = showsOutline
            UserDefaults.standard.set(showsOutline, forKey: "showsOutline")
        }
    }
    @Published var goingToPage = false
    /// 새 번호로 시작, 책갈피 and 조판 부호 지우기, while open; 현재 쪽만 감추기 and 문서 정보 with what they show.
    @Published var startingNumber = false
    @Published var bookmarking = false
    @Published var insertingSymbols = false
    @Published var erasingCodes = false
    @Published var pageHide: PageHide?
    @Published var documentInfo: DocumentInfo?
    @Published var insertingTable = false
    @Published var splittingCells = false
    /// 수식 편집기, and 개체 속성 (or 표/셀 속성), while open.
    @Published var equation: EquationEdit?
    @Published var objectSheet: ObjectSheetState?
    @Published var editingCharShape = false
    @Published var editingParaShape = false
    /// 글머리표 및 문단 번호, open at its 글머리표 or 문단 번호 tab.
    @Published var editingList: String?
    /// The section and paper 편집 용지 is showing.
    @Published var pageSetup: (section: UInt32, page: PageSetup)?

    // Find and replace.
    @Published var finding = false
    @Published var replacing = false
    @Published var query = ""
    @Published var replacement = ""
    /// Matches of `query` in the latest searched revision, and the selected one.
    /// Bumped by every request to find, so the bar takes the keyboard even when already shown.
    @Published private(set) var findRequests = 0
    @Published private(set) var matches: [EditSelection] = []
    @Published private(set) var currentMatch: Int?
    private var searchedRevision: UInt64?

    var document: HwpDocument? { canvas.editor.model }
    var undoManager: UndoManager? { canvas.editor.undoManager }

    init() {
        canvas.editor.showsOutline = showsOutline
        canvas.showsMargins = showsOutline
        canvas.onViewChange = { [weak self] in
            guard let self else { return }
            let zoom = Int((canvas.zoom * 100).rounded()), page = canvas.currentPage
            if zoom != position.zoomPercent { position.zoomPercent = zoom }
            if page != position.page { position.page = page }
        }
        canvas.editor.onPresent = { [weak self] in self?.documentPresented() }
        canvas.editor.onOpenObject = { [weak self] in self?.open($0) }
        canvas.editor.onContextMenu = { [weak self] in
            guard let self, let document else { return [] }
            return MenuItems.quickMenu(self, document.context)
        }
        canvas.editor.onCellBlockKey = { [weak self] key in
            guard let self else { return false }
            switch key {
            case "m": editCells { .mergeCells($0) }
            case "s": splittingCells = true
            case "h": editCells { .equalizeCells($0, height: true) }
            case "w": editCells { .equalizeCells($0, height: false) }
            default: return false
            }
            return true
        }
    }

    /// Keeps the find bar's matches and count current as the document changes.
    private func documentPresented() {
        if showsRuler { canvas.needsRulers() }
        guard finding, let document else { return }
        if document.revision != searchedRevision {
            Task { await search() }
        } else {
            let current = document.selection.flatMap { matches.firstIndex(of: $0) }
            if current != currentMatch { currentMatch = current }
        }
    }

    private func showMarks() {
        document?.showMarks(paragraph: showsParagraphMarks, control: showsControlCodes, borders: showsTransparentLines)
    }

    /// 모양 복사 in one button: applies the copied format to selected text, otherwise
    /// copies the format at the caret.
    func paintFormat() {
        let editor = canvas.editor
        if document?.context.hasRange == true, PageEditor.copiedStyle != nil { editor.pasteFont(nil) } else { editor.copyFont(nil) }
    }
}

extension Viewer {
    /// Shows the find bar; `replace` also shows the replacement field.
    func showFind(replace: Bool) {
        replacing = replace || (finding && replacing)
        finding = true
        findRequests += 1
    }
    func closeFind() {
        finding = false
        canvas.window?.makeFirstResponder(canvas.editor)
    }
    /// Finds with the selected text.
    func findSelection() {
        guard let document, let selection = document.selection, selection.anchor != selection.focus else { return NSSound.beep() }
        Task {
            guard let text = try? await document.text(of: selection) else { return }
            query = text
        }
    }
    func search() async {
        searchedRevision = document?.revision
        let asked = query
        let found = asked.isEmpty ? [] : (try? await document?.find(asked)) ?? []
        // A newer query started meanwhile owns the result.
        guard asked == query else { return }
        matches = found
        currentMatch = document?.selection.flatMap { matches.firstIndex(of: $0) }
    }

    /// Selects the match after the selection (or before it), wrapping around the document.
    /// Matches are looked up after queued edits, so it follows a replacement correctly.
    func findNext(backward: Bool = false) {
        guard let document, !query.isEmpty else { return NSSound.beep() }
        let query = query
        document.select { [weak self] document in
            let matches = try await document.find(query)
            self?.matches = matches
            guard !matches.isEmpty else {
                NSSound.beep()
                return nil
            }
            guard let selection = document.selection else { return matches[0] }
            if backward {
                let start = selection.ordered.start.order
                return matches.last { !start.lexicographicallyPrecedes($0.ordered.end.order) } ?? matches.last
            }
            let end = selection.ordered.end.order
            return matches.first { !$0.ordered.start.order.lexicographicallyPrecedes(end) } ?? matches.first
        }
    }
    /// Replaces the selected match and moves to the next one.
    func replace() {
        guard let document, let selection = document.selection, matches.contains(selection) else { return findNext() }
        let text = replacement
        document.edit(undoManager) { $0 == selection ? .replace(selection, text: text) : nil }
        findNext()
    }
    func replaceAll() {
        guard !query.isEmpty else { return NSSound.beep() }
        document?.replaceAll(query, with: replacement, undoManager)
    }

    /// Shows a zero-based page and puts the caret at its top.
    func go(toPage index: Int) {
        guard let document, !document.pages.isEmpty else { return }
        let page = min(max(index, 0), document.pages.count - 1)
        canvas.go(to: page)
        document.select { try await .caret($0.hitTest(page: page, x: 0, y: 0)) }
    }
}

/// The find bar above the pages: the query with match count and arrows, and when
/// replacing, the replacement with its buttons.
private struct FindBar: View {
    @ObservedObject var viewer: Viewer
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("찾기", text: $viewer.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { viewer.findNext() }
                if !viewer.query.isEmpty {
                    Text(viewer.currentMatch.map { "\($0 + 1)/\(viewer.matches.count)" } ?? "\(viewer.matches.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlGroup {
                    Button { viewer.findNext(backward: true) } label: { Label("이전 찾기", systemImage: "chevron.left") }
                    Button { viewer.findNext() } label: { Label("다음 찾기", systemImage: "chevron.right") }
                }
                .fixedSize()
                .disabled(viewer.matches.isEmpty)
                Button("완료") { viewer.closeFind() }
                    .keyboardShortcut(.cancelAction)
            }
            if viewer.replacing {
                HStack {
                    TextField("바꾸기", text: $viewer.replacement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewer.replace() }
                    Button("바꾸기") { viewer.replace() }
                    Button("모두 바꾸기") { viewer.replaceAll() }
                }
                .disabled(viewer.matches.isEmpty)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
        .onChange(of: viewer.findRequests) { focused = true }
        .task(id: viewer.query) { await viewer.search() }
    }
}

extension EditPosition {
    /// Sort key in document order across the body and table cells; a table's cells come
    /// after the text of the paragraph holding it.
    var order: [Int] {
        [Int(target.section), Int(target.paragraph), target.cell.map { Int($0.control) } ?? target.note.map { Int($0.control) } ?? -1,
         Int(target.cell?.cell ?? 0), Int(target.cell?.paragraph ?? target.note?.paragraph ?? 0), Int(scalar)]
    }
}

private struct Canvas: NSViewRepresentable {
    let canvas: DocumentCanvas
    let document: HwpDocument
    func makeNSView(context: Context) -> DocumentCanvas { canvas }
    func updateNSView(_ view: DocumentCanvas, context: Context) { view.bind(document) }
}

/// Page thumbnails; a page's image is redrawn only when the engine replaced that page.
private struct PageThumbnails: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @ObservedObject var position: ViewPosition

    var body: some View {
        let pages = document.thumbnails
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(pages.indices, id: \.self) { index in
                        let page = pages[index]
                        Button { viewer.canvas.go(to: index) } label: {
                                VStack(spacing: 4) {
                                    Thumbnail(page: page)
                                        .id(page.id)
                                        .padding(3)
                                        .background(RoundedRectangle(cornerRadius: 4)
                                            .fill(index == position.page ? Color.accentColor.opacity(0.35) : .clear))
                                    Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(index)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: position.page) { proxy.scrollTo(position.page) }
        }
    }
}

/// Draws off the main actor, keeping the previous image meanwhile. The document hands
/// out new thumbnail pages only once typing pauses.
private struct Thumbnail: View {
    let page: RenderedPage
    @State private var image: CGImage?

    var body: some View {
        let size = Self.size(of: page)
        Group {
            if let image { Image(decorative: image, scale: 2) } else { Color.white }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        .task(id: page.id) {
            let page = page
            let drawn = await Task.detached(priority: .utility) { Drawn(Self.render(page, size: size)) }.value
            if !Task.isCancelled { image = drawn.image }
        }
    }

    nonisolated private static func size(of page: RenderedPage) -> CGSize {
        let scale = min(110 / page.size.width, 150 / page.size.height)
        return CGSize(width: (page.size.width * scale).rounded(), height: (page.size.height * scale).rounded())
    }
    nonisolated private static func render(_ page: RenderedPage, size: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
        context.translateBy(x: 0, y: size.height * 2)
        context.scaleBy(x: 2, y: -2)
        page.draw(in: context, rect: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}

private struct Drawn: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}
