import PDFKit
import SwiftUI

/// One document window, laid out like Hancom Office Web below the macOS menu bar: the
/// 기본 and 서식 tool rows, then page thumbnails beside the pages, and a status bar.
struct DocumentWindow: View {
    let document: HwpDocument
    @StateObject private var viewer = Viewer()

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
        NavigationSplitView(columnVisibility: Binding(get: { viewer.showsSidebar ? .all : .detailOnly },
                                                      set: { viewer.showsSidebar = $0 != .detailOnly })) {
            Sidebar(document: document, viewer: viewer)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            // The inspector is a column of its own here: SwiftUI's `inspector` in a document
            // window loops its layout until AppKit stops the app.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if viewer.showsFormat {
                        FormatRow(document: document, editor: viewer.canvas.editor)
                        Divider()
                    }
                    if viewer.finding { FindBar(viewer: viewer) }
                    Canvas(canvas: viewer.canvas, document: document)
                        .frame(minWidth: 400, minHeight: 300)
                    if viewer.showsStatusBar {
                        Divider()
                        StatusBar(document: document, viewer: viewer, position: viewer.position, status: viewer.status)
                    }
                }
                if viewer.showsInspector {
                    ColumnDivider(width: $viewer.inspectorWidth, range: 240...480)
                    Group {
                        switch viewer.inspectorPane {
                        case .format: Inspector(document: document, viewer: viewer)
                        case .document: DocumentInspector(document: document, viewer: viewer)
                        }
                    }
                    .frame(width: viewer.inspectorWidth)
                }
            }
        }
        .toolbar { DocumentToolbar(document: document, viewer: viewer) }
        .sheet(isPresented: $viewer.goingToPage) { GoToSheet(viewer: viewer, pageCount: document.context.pageCount) }
        .sheet(isPresented: $viewer.insertingTable) { TableSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.splittingCells) { SplitCellSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.calculating) { CalculationSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.replacingPrivateInfo) { PrivateInfoSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.flippingTable) { TableFlipSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.startingNumber) { NewNumberSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.bookmarking) { BookmarkSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.insertingSymbols) { SymbolSheet(viewer: viewer) }
        .sheet(isPresented: $viewer.erasingCodes) { EraseCodesSheet(viewer: viewer) }
        .sheet(isPresented: Binding(get: { viewer.pageHide != nil }, set: { if !$0 { viewer.pageHide = nil } })) {
            if let hide = viewer.pageHide { PageHideSheet(viewer: viewer, hide: hide) }
        }
        .sheet(isPresented: Binding { viewer.passwordSheet != nil } set: { if !$0 { viewer.passwordSheet = nil } }) {
            if viewer.passwordSheet == true { PasswordChangeSheet(viewer: viewer) } else { PasswordSheet(viewer: viewer) }
        }
        .task { await document.loadPassword() }
        .sheet(item: $viewer.documentInfo) { DocumentInfoSheet(info: $0, document: document, viewer: viewer) }
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
        .sheet(isPresented: Binding(get: { viewer.pageBorder != nil }, set: { if !$0 { viewer.pageBorder = nil } })) {
            if let setup = viewer.pageBorder { PageBorderSheet(section: setup.section, border: setup.border, viewer: viewer) }
        }
        .sheet(item: $viewer.cellBorder) { CellBorderSheet(editing: $0, viewer: viewer) }
        .sheet(item: $viewer.chartData) { ChartDataSheet(editing: $0, viewer: viewer) }
        .sheet(item: $viewer.fieldSheet) { FieldSheet(viewer: viewer, editing: $0.existing) }
        .sheet(item: $viewer.hyperlinkSheet) { HyperlinkSheet(viewer: viewer, editing: $0) }
        .sheet(isPresented: $viewer.editingStyles) { StyleSheet(document: document, viewer: viewer) }
        .sheet(item: $viewer.styleEditor) { StyleEditSheet(editor: $0, styles: document.styles, viewer: viewer) }
        .sheet(item: $viewer.replacingStyle) { StyleReplaceSheet(style: $0, styles: document.styles, viewer: viewer) }
        .sheet(isPresented: Binding(get: { viewer.noteShapes != nil }, set: { if !$0 { viewer.noteShapes = nil } })) {
            if let shapes = viewer.noteShapes {
                NoteShapeSheet(section: shapes.section, footnote: shapes.footnote, endnote: shapes.endnote, viewer: viewer)
            }
        }
        .sheet(isPresented: Binding(get: { viewer.sectionSetup != nil }, set: { if !$0 { viewer.sectionSetup = nil } })) {
            if let setup = viewer.sectionSetup { SectionSheet(section: setup.section, setup: setup.setup, viewer: viewer) }
        }
        .sheet(isPresented: Binding(get: { viewer.columnSetup != nil }, set: { if !$0 { viewer.columnSetup = nil } })) {
            if let setup = viewer.columnSetup { ColumnSheet(section: setup.section, setup: setup.setup, viewer: viewer) }
        }
        .focusedSceneObject(document)
        .focusedSceneObject(viewer)
    }
}

/// The bar under the pages, as Scrivener's footer: 쪽 and 글자 수 at the left, zoom at the right.
/// The caret's 단, 줄, 칸 and 구역 show over 쪽.
private struct StatusBar: View {
    @ObservedObject var document: HwpDocument
    @ObservedObject var viewer: Viewer
    @ObservedObject var position: ViewPosition
    @ObservedObject var status: StatusModel

    var body: some View {
        let caret = status.caret
        HStack(spacing: 14) {
            Button("\(caret?.page ?? UInt32(position.page + 1))/\(document.context.pageCount)쪽") { viewer.goingToPage = true }
                .buttonStyle(.plain)
                .help(caret.map { "\($0.column)단 \($0.line)줄 \($0.character)칸 · \($0.section)/\($0.sections) 구역" } ?? "")
            if let caret { Text("\(caret.characters)글자") }
            Spacer()
            HStack(spacing: 4) {
                ToolIcon("축소", symbol: Icon.zoomOut) { viewer.canvas.zoomOut(nil) }
                Menu("\(position.zoomPercent)%") { ZoomItems(viewer: viewer, position: position) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                ToolIcon("확대", symbol: Icon.zoomIn) { viewer.canvas.zoomIn(nil) }
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

/// The toolbar, as Pages': the things put in most often, then 찾기 and the inspector. It is
/// not customizable: SwiftUI's customizable toolbars share items between windows and throw
/// when a second document opens.
private struct DocumentToolbar: ToolbarContent {
    let document: HwpDocument
    let viewer: Viewer

    var body: some ToolbarContent {
        // One group, so macOS 26 draws them in one capsule of glass as Keynote's.
        ToolbarItemGroup {
            InsertButton(document: document, title: "표", symbol: Icon.table, when: \.inBody, panel: { TableGrid(viewer: viewer) })
            InsertButton(document: document, title: "그림", symbol: Icon.picture, when: \.canPicture, action: { viewer.insertPicture() })
            InsertButton(document: document, title: "도형", symbol: Icon.shape, when: \.inBody, panel: { ShapeTiles(viewer: viewer) })
            InsertButton(document: document, title: "글상자", symbol: Icon.textbox, when: \.inBody, action: { viewer.draw("textbox") })
            InsertButton(document: document, title: "수식", symbol: Icon.equation, when: \.canPicture, action: { viewer.newEquation() })
            InsertButton(document: document, title: "문자표", symbol: Icon.symbols, when: \.hasSelection, action: { viewer.insertingSymbols = true })
        }
        ToolbarItem(placement: .primaryAction) {
            Button { viewer.showFind(replace: false) } label: { Label("찾기", systemImage: Icon.find) }.help("찾기")
        }
        // Keynote's 포맷 and 문서: each brings its inspector up, and hides it when it shows.
        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(InspectorPane.allCases, id: \.self) { InspectorButton(viewer: viewer, pane: $0) }
        }
    }
}

/// A toolbar button that puts something in, on while `when` holds; `panel` opens a popover
/// instead of running `action`.
private struct InsertButton<Panel: View>: View {
    @ObservedObject var document: HwpDocument
    let title: String, symbol: String
    let when: KeyPath<EditingContext, Bool>
    var panel: (() -> Panel)?
    var action: () -> Void = {}
    @State private var showsPanel = false

    var body: some View {
        Button { if panel != nil { showsPanel = true } else { action() } } label: { Label(title, systemImage: symbol) }
            .help(title)
            .popover(isPresented: $showsPanel, arrowEdge: .bottom) { panel?() }
            .disabled(!document.context[keyPath: when] || document.context.locked)
    }
}
extension InsertButton where Panel == EmptyView {
    init(document: HwpDocument, title: String, symbol: String, when: KeyPath<EditingContext, Bool>, action: @escaping () -> Void) {
        self.init(document: document, title: title, symbol: symbol, when: when, panel: nil, action: action)
    }
}

private struct InspectorButton: View {
    @ObservedObject var viewer: Viewer
    let pane: InspectorPane
    var body: some View {
        Toggle(isOn: Binding(get: { viewer.showsInspector && viewer.inspectorPane == pane },
                             set: { on in (viewer.inspectorPane, viewer.showsInspector) = (pane, on) })) {
            Label(pane.rawValue, systemImage: pane.symbol)
        }
        .toggleStyle(.button)
        .help(pane.rawValue)
    }
}

/// The inspector's panes, chosen from the toolbar.
enum InspectorPane: String, CaseIterable {
    case format = "서식", document = "문서"
    var symbol: String { self == .format ? "paintbrush" : "doc.text" }
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

/// 상황 선's caret status. Kept apart from `Viewer` because it changes with every caret move.
@MainActor
final class StatusModel: ObservableObject {
    @Published fileprivate(set) var caret: CaretStatus?
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
    let status = StatusModel()
    private var statusTask: Task<Void, Never>?
    /// Pages side by side.
    /// Pages side by side; more than one turns 쪽 윤곽 on, as 한글's 여러 쪽 보기 does.
    @Published var columns = 1 {
        didSet {
            canvas.columns = columns
            if columns > 1 { showsOutline = true }
        }
    }
    /// 서식 도구 상자, remembered for new windows.
    @Published var showsFormat = UserDefaults.standard.object(forKey: "showsFormat") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsFormat, forKey: "showsFormat") }
    }
    /// The sidebar at the left and the 작업 창 it shows, and the inspector at the right; they stay as they were left.
    @Published var showsSidebar = UserDefaults.standard.object(forKey: "showsSidebar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsSidebar, forKey: "showsSidebar") }
    }
    @Published var sidebarPane = UserDefaults.standard.string(forKey: "sidebarPane").flatMap(TaskPane.init) ?? .pages {
        didSet { UserDefaults.standard.set(sidebarPane.rawValue, forKey: "sidebarPane") }
    }
    @Published var showsInspector = UserDefaults.standard.object(forKey: "showsInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsInspector, forKey: "showsInspector") }
    }
    @Published var inspectorWidth = UserDefaults.standard.object(forKey: "inspectorWidth") as? Double ?? 270 {
        didSet { UserDefaults.standard.set(inspectorWidth, forKey: "inspectorWidth") }
    }
    @Published var inspectorPane = UserDefaults.standard.string(forKey: "inspectorPane").flatMap(InspectorPane.init) ?? .format {
        didSet { UserDefaults.standard.set(inspectorPane.rawValue, forKey: "inspectorPane") }
    }
    /// The inspector's tab, kept while it is hidden.
    var inspectorTab = "글자"
    func shows(_ pane: TaskPane) -> Bool { showsSidebar && sidebarPane == pane }
    /// Shows `pane`, or hides it when it shows.
    func toggle(_ pane: TaskPane) {
        (showsSidebar, sidebarPane) = (!shows(pane), pane)
    }
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
    /// 보기 › 문서 창: 상황 선, 가로 눈금자 and 세로 눈금자.
    @Published var showsStatusBar = true
    @Published var showsHorizontalRuler = false {
        didSet { canvas.showsHorizontalRuler = showsHorizontalRuler }
    }
    @Published var showsVerticalRuler = false {
        didSet { canvas.showsVerticalRuler = showsVerticalRuler }
    }
    /// 보기 탭's 눈금자: both rulers.
    var showsRuler: Bool {
        get { showsHorizontalRuler || showsVerticalRuler }
        set { (showsHorizontalRuler, showsVerticalRuler) = (newValue, newValue) }
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
    /// 문서 암호 설정 (false) or 문서 암호 변경/해제 (true) shown.
    @Published var passwordSheet: Bool?
    @Published var insertingTable = false
    @Published var splittingCells = false
    @Published var calculating = false
    @Published var replacingPrivateInfo = false
    @Published var flippingTable = false
    /// 수식 편집기, and 개체 속성 (or 표/셀 속성), while open.
    @Published var equation: EquationEdit?
    @Published var objectSheet: ObjectSheetState?
    @Published var editingCharShape = false
    @Published var editingParaShape = false
    /// 글머리표 및 문단 번호, open at its 글머리표 or 문단 번호 tab.
    @Published var editingList: String?
    /// The section and paper 편집 용지 is showing.
    @Published var pageSetup: (section: UInt32, page: PageSetup)?
    @Published var pageBorder: (section: UInt32, border: PageBorder)?
    @Published var cellBorder: CellBorderEditing?
    @Published var fieldSheet: FieldEditing?
    @Published var hyperlinkSheet: HyperlinkEditing?
    @Published var chartData: ChartEditing?
    @Published var sectionSetup: (section: UInt32, setup: SectionSetup)?
    @Published var columnSetup: (section: UInt32, setup: ColumnSetup)?
    @Published var noteShapes: (section: UInt32, footnote: NoteShape, endnote: NoteShape)?
    /// [스타일] 대화 상자, and from the 작업 창 스타일 추가하기/편집하기 and 바꿀 스타일 선택.
    @Published var editingStyles = false
    @Published var styleEditor: StyleEditor?
    @Published var replacingStyle: StyleInfo?

    // Find and replace.
    @Published var finding = false
    @Published var replacing = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var findOptions = FindOptions()
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
            var link: Hyperlink?
            if let focus = document.selection?.focus { link = try? await document.hyperlink(at: focus) }
            return MenuItems.quickMenu(self, document.context, link: link)
        }
        // 한글's keys that work on a cell block or a selected object, and Ctrl+Enter (⌘↩) in a cell.
        canvas.editor.onKey = { [weak self] event in
            guard let self, let context = document?.context else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command, event.keyCode == 36, context.inTable, context.object == nil {
                editTable(.insertRowBelow)
                return true
            }
            // The letter typed, or while typing 한글 the letter of the key's place.
            let letters: [UInt16: Character] = [46: "m", 1: "s", 4: "h", 13: "w", 35: "p", 32: "u", 5: "g", 17: "t", 37: "l", 8: "c"]
            let typed = event.charactersIgnoringModifiers?.lowercased().first.flatMap { $0.isASCII ? $0 : nil }
            guard modifiers.isEmpty, let key = typed ?? letters[event.keyCode] else { return false }
            if context.cellBlock {
                switch key {
                case "m": editCells { .mergeCells($0) }
                case "s": splittingCells = true
                case "h": editCells { .equalizeCells($0, height: true) }
                case "w": editCells { .equalizeCells($0, height: false) }
                case "t": flippingTable = true
                case "p": showObjectProperties()
                case "l": showCellBorder(one: false)
                case "c": showCellBorder(one: false, tab: "배경")
                default: return false
                }
            } else if context.object != nil, !context.locked {
                switch key {
                case "p": showObjectProperties()
                case "u" where document?.object?.group == true: change { .ungroup($0) }
                case "g" where context.objects > 1: groupObjects()
                default: return false
                }
            } else {
                return false
            }
            return true
        }
    }

    /// Keeps the find bar's matches and count current as the document changes.
    private func documentPresented() {
        if showsRuler { canvas.needsRulers() }
        // The 상황 선 follows once typing pauses, off the keystroke's way.
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let document, let focus = document.selection?.focus else { return }
            let caret = try? await document.status(at: focus)
            if !Task.isCancelled, caret != status.caret { status.caret = caret }
        }
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
        let options = findOptions
        let found = asked.isEmpty ? [] : (try? await document?.find(asked, options)) ?? []
        // A newer query started meanwhile owns the result.
        guard asked == query, options == findOptions else { return }
        matches = found
        currentMatch = document?.selection.flatMap { matches.firstIndex(of: $0) }
    }

    /// Selects the match after the selection (or before it), wrapping around the document.
    /// Matches are looked up after queued edits, so it follows a replacement correctly.
    func findNext(backward: Bool = false) {
        guard let document, !query.isEmpty else { return NSSound.beep() }
        let (query, options) = (query, findOptions)
        document.select { [weak self] document in
            let matches = try await document.find(query, options)
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
        document?.replaceAll(query, findOptions, with: replacement, undoManager)
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
                Menu {
                    Toggle("대소문자 구별", isOn: $viewer.findOptions.matchCase)
                    Toggle("온전한 낱말", isOn: $viewer.findOptions.wholeWord)
                } label: {
                    Image(systemName: viewer.findOptions == FindOptions() ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("선택 사항")
                .accessibilityLabel("선택 사항")
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
        .task(id: [viewer.query, "\(viewer.findOptions.matchCase)\(viewer.findOptions.wholeWord)"]) { await viewer.search() }
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
/// 작업 창 that work: 쪽 모양 보기, 스타일, 책갈피 and 개요 보기.
enum TaskPane: String, CaseIterable {
    case pages = "쪽 모양 보기", outline = "개요 보기", bookmarks = "책갈피"
    var symbol: String {
        switch self {
        case .pages: "doc.on.doc"
        case .bookmarks: "bookmark"
        case .outline: "list.bullet.indent"
        }
    }
}

/// The sidebar, as Xcode's navigator: the 작업 창 chosen in a row of icons over it, and a
/// filter under the lists, in Liquid Glass where macOS has it.
private struct Sidebar: View {
    @ObservedObject var document: HwpDocument
    @ObservedObject var viewer: Viewer
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            SegmentedChoice(TaskPane.allCases, selection: $viewer.sidebarPane) { pane in
                Image(systemName: pane.symbol).help(pane.rawValue).accessibilityLabel(pane.rawValue)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            switch viewer.sidebarPane {
            case .pages: PageThumbnails(document: document, viewer: viewer, position: viewer.position)
            case .outline: OutlinePane(document: document, viewer: viewer, filter: filter)
            case .bookmarks: BookmarkPane(document: document, viewer: viewer, filter: filter)
            }
            if viewer.sidebarPane != .pages {
                HStack(spacing: 6) {
                    if viewer.sidebarPane == .bookmarks {
                        Button { viewer.bookmarking = true } label: { Image(systemName: "plus").frame(width: 16, height: 16) }
                            .glassButton()
                            .help("책갈피…")
                            .accessibilityLabel("책갈피…")
                    }
                    FilterField(text: $filter)
                }
                .padding(10)
            }
        }
        .onChange(of: viewer.sidebarPane) { filter = "" }
    }
}

/// Xcode's filter field: a capsule with the filter sign before the text and a clear button after it.
private struct FilterField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("필터", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("지우기")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .glassCapsule()
    }
}

extension View {
    /// Liquid Glass in a capsule on macOS 26 and later, a quiet fill before it.
    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26, *) { glassEffect(.regular, in: .capsule) } else { background(.quaternary, in: Capsule()) }
    }
    /// The Liquid Glass button style on macOS 26 and later, a bordered one before it.
    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass).buttonBorderShape(.circle) } else { buttonStyle(.bordered) }
    }
}

/// [개요 보기] 작업 창: the 개요 문단 as a tree by 수준, kept current as the text changes; a
/// click moves the caret to that paragraph.
private struct OutlinePane: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    /// Shows only the 개요 whose title holds it, in one list.
    var filter = ""
    @State private var nodes: [OutlineNode] = []
    @State private var chosen: Int?
    /// Every 개요 shows until its 수준 is folded.
    @State private var folded: Set<Int> = []

    var body: some View {
        List(selection: $chosen) {
            if filter.isEmpty {
                ForEach(nodes) { row($0) }
            } else {
                ForEach(Self.flat(nodes).filter { $0.item.title.localizedCaseInsensitiveContains(filter) }) { row(OutlineNode(id: $0.id, item: $0.item)) }
            }
        }
        .listStyle(.sidebar)
        .task(id: document.reply.revision) {
            await document.settle()
            nodes = OutlineNode.tree((try? await document.outline()) ?? [])
        }
    }

    private static func flat(_ nodes: [OutlineNode]) -> [OutlineNode] {
        nodes.flatMap { [$0] + flat($0.children ?? []) }
    }

    private func row(_ node: OutlineNode) -> AnyView {
        let title = Text(node.item.number.isEmpty ? node.item.title : "\(node.item.number) \(node.item.title)")
            .lineLimit(1)
            .help(node.item.title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // A tap rather than the selection, so the same 개요 moves the caret again.
            .simultaneousGesture(TapGesture().onEnded {
                chosen = node.id
                viewer.go(to: node.item.position)
            })
            .tag(node.id)
        guard let children = node.children else { return AnyView(title) }
        let open = Binding { !folded.contains(node.id) } set: { if $0 { folded.remove(node.id) } else { folded.insert(node.id) } }
        return AnyView(DisclosureGroup(isExpanded: open) { ForEach(children) { row($0) } } label: { title })
    }
}

/// A 개요 문단 with the deeper ones that follow it.
struct OutlineNode: Identifiable {
    let id: Int
    let item: OutlineItem
    var children: [OutlineNode]?

    static func tree(_ items: [OutlineItem]) -> [OutlineNode] {
        var rest = items.enumerated().map { OutlineNode(id: $0.offset, item: $0.element) }[...]
        return take(&rest, deeperThan: 0)
    }
    private static func take(_ rest: inout ArraySlice<OutlineNode>, deeperThan level: UInt8) -> [OutlineNode] {
        var nodes: [OutlineNode] = []
        while var node = rest.first, node.item.level > level {
            rest.removeFirst()
            let children = take(&rest, deeperThan: node.item.level)
            node.children = children.isEmpty ? nil : children
            nodes.append(node)
        }
        return nodes
    }
}

/// [스타일] 작업 창: the styles, the caret's marked; a click applies one. The tools below
/// work on the caret's style; a style's quick menu on that style.
struct StylePane: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    var body: some View {
        let current = document.styles.first { $0.id == document.format?.style }
        VStack(spacing: 0) {
            List(document.styles, id: \.id) { style in
                Button { document.applyStyle(style.id, viewer.undoManager) } label: {
                    Label(style.name, systemImage: style.id == current?.id
                        ? "checkmark" : style.paragraphStyle ? "paragraphsign" : "textformat")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!document.context.canApplyStyle)
                .contextMenu {
                    Button("스타일 추가/편집") { edit(style) }
                    Button("커서 위치의 스타일로 바꾸기") { viewer.restyleFromCaret(style.id) }
                    Button("스타일 지우기") { delete(style) }.disabled(style.id == 0)
                }
                .disabled(document.context.locked)
            }
            .listStyle(.plain)
            Divider()
            HStack(spacing: 2) {
                listTool("스타일 추가", "plus") { viewer.styleEditor = viewer.newStyle() }
                listTool("스타일 편집", "pencil") { if let current { edit(current) } }.disabled(current == nil)
                listTool("스타일 지우기", "minus") { if let current { delete(current) } }.disabled((current?.id ?? 0) == 0)
                listTool("스타일 위로", "arrow.up") { if let current { viewer.moveStyle(current.id, up: true) } }
                    .disabled((current?.id ?? 0) < 2)
                listTool("스타일 아래로", "arrow.down") { if let current { viewer.moveStyle(current.id, up: false) } }
                    .disabled(current.map { $0.id == 0 || Int($0.id) + 1 >= document.styles.count } ?? true)
                Spacer()
            }
            .padding(4)
            .disabled(document.context.locked)
        }
        .task { await document.loadStyles() }
    }
    private func edit(_ style: StyleInfo) {
        Task { viewer.styleEditor = await viewer.styleEditor(style) }
    }
    private func delete(_ style: StyleInfo) {
        viewer.deleteStyle(style) { viewer.replacingStyle = $0 }
    }
}

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
