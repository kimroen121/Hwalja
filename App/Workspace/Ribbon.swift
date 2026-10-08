import AppKit
import SwiftUI

/// 기본 도구 상자, as in 한/글 2022: the 메뉴 탭 each switch a row of large labeled icons,
/// and the 개체 탭 and 상황 탭 come after them while an object is selected or the caret is in
/// a table or a 머리말/꼬리말. Commands that do not work yet are left out, and so are the
/// tabs left with none (보안, 검토, 도구).
struct ToolRow: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @AppStorage("toolTab") private var menuTab = "편집"
    /// The 개체 탭 or 상황 탭 shown instead of `menuTab` while it is there.
    @State private var contextTab: String?
    @State private var hovered: String?
    @State private var spans: [String: CGRect] = [:]
    static let menuTabs = ["편집", "보기", "입력", "서식", "쪽"]

    /// Folded (기본 도구 상자 접기), only the tabs show.
    let expanded: Bool

    init(document: HwpDocument, viewer: Viewer, expanded: Bool = true, contextTab: String? = nil) {
        (self.document, self.viewer, self.expanded, _contextTab) = (document, viewer, expanded, State(initialValue: contextTab))
    }

    /// The 개체 탭 and 상황 탭 for what is selected.
    static func contextTabs(_ context: EditingContext) -> [String] {
        switch context.object {
        case .picture: ["그림"]
        case .shape: ["도형"]
        case .equation: []
        case .table, nil: context.inHeaderFooter ? ["머리말/꼬리말"] : context.inTable ? ["표 디자인", "표 레이아웃"] : []
        }
    }

    var body: some View {
        let context = document.context
        let extra = Self.contextTabs(context)
        let tab = contextTab.flatMap { extra.contains($0) ? $0 : nil } ?? (Self.menuTabs.contains(menuTab) ? menuTab : "편집")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Self.menuTabs + extra, id: \.self) { name in
                    if name == extra.first { Divider().frame(height: 14).padding(.horizontal, 4) }
                    tabButton(name, selected: tab == name, object: extra.contains(name))
                }
                Spacer(minLength: 0)
                ToolIcon("기본 도구 상자 접기/펴기", symbol: expanded ? "chevron.up" : "chevron.down") {
                    viewer.showsTools.toggle()
                }
            }
            .coordinateSpace(.named("tabs"))
            .overlay(alignment: .topLeading) {
                // As in Word: one line under the selected tab, moved from tab to tab, a little longer under the pointer.
                if expanded, let span = spans[tab] {
                    let grow: CGFloat = hovered == tab ? 4 : 0
                    Capsule()
                        .frame(width: span.width + grow * 2, height: 3)
                        .offset(x: span.minX - grow, y: span.maxY - 1.5)
                        .allowsHitTesting(false)
                }
            }
            // A change to stored settings comes without the click's animation.
            .animation(.snappy(duration: 0.25), value: tab)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .padding(.horizontal, 7)
            .padding(.top, 5)
            // A narrow window scrolls the row instead of squeezing it.
            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 2) { tiles(tab, context) }
                        .padding(.horizontal, 8)
                        .padding(.top, 5)
                        .padding(.bottom, 8)
                }
            }
        }
        .onChange(of: extra) { old, new in
            if let shown = contextTab, !new.contains(shown) { contextTab = nil }
            // A selected object or 머리말/꼬리말 brings its tab up; a table's do not, so typing in cells keeps the tab.
            if let first = new.first, !old.contains(first), !first.hasPrefix("표") { contextTab = first }
        }
    }

    @ViewBuilder private func tabButton(_ name: String, selected: Bool, object: Bool) -> some View {
        HStack(spacing: 0) {
            tabName(name, selected: selected, object: object)
            // 펼침 단추: the menu of the same name from the menu bar, under the tab.
            if !object { MenuOpener(title: name) }
        }
    }
    private func tabName(_ name: String, selected: Bool, object: Bool) -> some View {
        Button {
            if object { contextTab = name } else { (menuTab, contextTab) = (name, nil) }
        } label: {
            // Laid out bold either way, so choosing a tab moves nothing and the line slides undisturbed.
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
                .hidden()
                .overlay {
                    Text(name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                }
                .padding(.vertical, 4)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabs")) } action: { spans[name] = $0 }
                // The gap between tabs is part of them, so a click beside a name still lands.
                .padding(.leading, 9)
                .padding(.trailing, object ? 9 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // As in 한/글, a double click on a tab folds or unfolds the 기본 도구 상자.
        .simultaneousGesture(TapGesture(count: 2).onEnded { viewer.showsTools.toggle() })
        .onHover { hovered = $0 ? name : (hovered == name ? nil : hovered) }
    }

    @ViewBuilder private func tiles(_ tab: String, _ context: EditingContext) -> some View {
        switch tab {
        case "보기": ViewTiles(viewer: viewer)
        case "입력": insert(context)
        case "서식": format(context)
        case "쪽": page(context)
        case "표 디자인": tableDesign(context)
        case "표 레이아웃": tableLayout(context)
        case "도형": shape(context)
        case "그림": picture(context)
        case "머리말/꼬리말": headerFooter(context)
        default: edit(context)
        }
    }

    // MARK: 메뉴 탭

    @ViewBuilder private func edit(_ context: EditingContext) -> some View {
        clipboard(context)
        ToolTile("모양 복사", Icon.styleCopy) { viewer.paintFormat() }
            .disabled(!context.canFormat)
        ToolTile("조판 부호 지우기", Icon.eraseCodes) { viewer.erasingCodes = true }
            .disabled(context.locked)
        RowDivider()
        shapes(context)
        RowDivider()
        orientation(context)
        columns(context)
        RowDivider()
        objects(context)
        symbols(context)
        RowDivider()
        find
    }
    @ViewBuilder private func insert(_ context: EditingContext) -> some View {
        ShapeGallery(viewer: viewer)
            .disabled(!context.inBody)
        RowDivider()
        ToolTile("그림", Icon.picture) { viewer.insertPicture() }
            .disabled(!context.canPicture)
        table(context)
        ToolTile("수식", Icon.equation) { viewer.newEquation() }
            .disabled(!context.canPicture)
        RowDivider()
        notes(context)
        RowDivider()
        ToolTile("책갈피", Icon.bookmark) { viewer.bookmarking = true }
            .disabled(!context.inBody)
        RowDivider()
        symbols(context)
    }
    @ViewBuilder private func format(_ context: EditingContext) -> some View {
        StyleGallery(document: document, editor: viewer.canvas.editor)
            .disabled(!context.canApplyStyle)
        RowDivider()
        let editor = viewer.canvas.editor, head = document.format?.paragraph.head
        shapes(context)
        ColorMenu(title: "형광펜", symbol: "highlighter", current: document.format?.text.shade ?? "#ffffff",
                  colors: FormatChoices.highlights, clears: true) { editor.format(CharStyle(shade: $0)) }
            .padding(.top, 3)
            .disabled(!context.canFormat)
        RowDivider()
        Group {
            ToolTile("글머리표", Icon.bullets, action: {
                MenuItems.toggleList(editor, head: head, bullet: true)
            }, choices: {
                FormatChoices.bullets.map { bullet in Choice(title: bullet) { editor.format(ParaStyle(head: "Bullet", bullet: bullet)) } }
            })
            ToolTile("문단 번호", Icon.numbering, action: {
                MenuItems.toggleList(editor, head: head, bullet: false)
            }, choices: {
                FormatChoices.numberings.indices.map { kind in
                    Choice(title: FormatChoices.numberings[kind].joined(separator: " ")) { editor.format(ParaStyle(head: "Number", numbering: kind)) }
                }
            })
            Group {
                ToolTile("한 수준 증가", Icon.levelUp) { editor.stepLevel(by: 1) }
                ToolTile("한 수준 감소", Icon.levelDown) { editor.stepLevel(by: -1) }
            }
            .disabled(!context.inList)
        }
        .disabled(!context.canFormat)
    }
    @ViewBuilder private func page(_ context: EditingContext) -> some View {
        ToolTile("편집 용지", Icon.pageSetup) { viewer.showPageSetup() }
            .disabled(context.locked)
        orientation(context)
        RowDivider()
        headers(context)
        Group {
            ToolTile("새 번호로 시작", Icon.newNumber) { viewer.startingNumber = true }
            ToolTile("현재 쪽만 감추기", Icon.pageHide) { viewer.showPageHide() }
        }
        .disabled(!context.inBody)
        RowDivider()
        Group {
            ToolTile("쪽 나누기", Icon.pageBreak) { viewer.insertBreak(column: false) }
            ToolTile("단 나누기", Icon.columnBreak) { viewer.insertBreak(column: true) }
        }
        .disabled(!context.inBody)
        RowDivider()
        columns(context)
    }

    // MARK: 개체 탭과 상황 탭

    @ViewBuilder private func tableDesign(_ context: EditingContext) -> some View {
        ToolTile("표 속성", Icon.objectProps) { viewer.showObjectProperties() }
            .disabled(context.locked)
    }
    @ViewBuilder private func tableLayout(_ context: EditingContext) -> some View {
        TransparentLinesTile(viewer: viewer)
        RowDivider()
        Group {
            ToolTile("줄/칸 추가하기", Icon.insertRow, choices: {
                [Choice(title: "위쪽에 줄 추가하기") { viewer.editTable(.insertRowAbove) },
                 Choice(title: "아래쪽에 줄 추가하기") { viewer.editTable(.insertRowBelow) }, nil,
                 Choice(title: "왼쪽에 칸 추가하기") { viewer.editTable(.insertColumnLeft) },
                 Choice(title: "오른쪽에 칸 추가하기") { viewer.editTable(.insertColumnRight) }]
            })
            ToolTile("줄/칸 지우기", Icon.deleteRow, choices: {
                [Choice(title: "줄 지우기") { viewer.editTable(.deleteRow) }, nil,
                 Choice(title: "칸 지우기") { viewer.editTable(.deleteColumn) }]
            })
            RowDivider()
            ToolTile("셀 나누기", Icon.splitCells) { viewer.splittingCells = true }
        }
        .disabled(context.locked)
        Group {
            ToolTile("셀 합치기", Icon.mergeCells) { viewer.editCells { .mergeCells($0) } }
            ToolTile("셀 너비를 같게", Icon.equalWidth) { viewer.editCells { .equalizeCells($0, height: false) } }
            ToolTile("셀 높이를 같게", Icon.equalHeight) { viewer.editCells { .equalizeCells($0, height: true) } }
            RowDivider()
            ToolTile("블록 계산식", Icon.blockCalculation, choices: {
                MenuItems.blockFunctions.map { function in
                    Choice(title: function.title) { viewer.editCells { .calculateBlock($0, function.function) } }
                }
            })
        }
        .disabled(!context.cellBlock || context.locked)
        RowDivider()
        arrangement(context)
    }
    @ViewBuilder private func shape(_ context: EditingContext) -> some View {
        ShapeGallery(viewer: viewer)
            .disabled(!context.inBody)
        let placed = document.object
        Group {
            if let textBox = placed?.textBox {
                ToolTile("글자 넣기", Icon.textIn, on: textBox) { viewer.change { .setTextBox($0, attach: !textBox) } }
            }
            RowDivider()
            ToolTile("도형 속성", Icon.objectProps) { viewer.showObjectProperties() }
            RowDivider()
            Arrangement(document: document, viewer: viewer)
            RowDivider()
            ToolTile("앞으로", Icon.front, action: { viewer.change { .order($0, .forward) } }, choices: {
                [Choice(title: "맨 앞으로") { viewer.change { .order($0, .front) } },
                 Choice(title: "앞으로") { viewer.change { .order($0, .forward) } }]
            })
            ToolTile("뒤로", Icon.back, action: { viewer.change { .order($0, .backward) } }, choices: {
                [Choice(title: "맨 뒤로") { viewer.change { .order($0, .back) } },
                 Choice(title: "뒤로") { viewer.change { .order($0, .backward) } }]
            })
            if placed?.group == true {
                ToolTile("그룹", Icon.group, choices: { [Choice(title: "개체 풀기") { viewer.change { .ungroup($0) } }] })
            }
        }
        .disabled(context.locked)
        RowDivider()
        captions(context)
    }
    @ViewBuilder private func picture(_ context: EditingContext) -> some View {
        ToolTile("그림", Icon.picture) { viewer.insertPicture() }
            .disabled(!context.canPicture)
        Group {
            ToolTile("원본 그림으로", Icon.originalPicture) { MenuItems.restorePicture(viewer) }
            RowDivider()
            ToolTile("그림 속성", Icon.objectProps) { viewer.showObjectProperties() }
            RowDivider()
            ToolTile("색조 조정", Icon.pictureEffect, choices: { MenuItems.pictureEffects(viewer) })
            ToolTile("밝기", Icon.brightness, choices: { MenuItems.brightness(viewer) })
            ToolTile("대비", Icon.contrast, choices: { MenuItems.contrast(viewer) })
        }
        .disabled(context.locked)
        RowDivider()
        arrangement(context)
    }
    @ViewBuilder private func headerFooter(_ context: EditingContext) -> some View {
        headers(context)
        RowDivider()
        ToolTile("편집 용지", Icon.pageSetup) { viewer.showPageSetup() }
            .disabled(context.locked)
        ToolTile("이전", Icon.previous) { viewer.goToHeaderFooter(.previousHeaderFooter) }
        ToolTile("다음", Icon.next) { viewer.goToHeaderFooter(.nextHeaderFooter) }
        ToolTile("지우기", Icon.eraseCodes) { document.deleteHeaderFooter(viewer.undoManager) }
            .disabled(context.locked)
        RowDivider()
        ToolTile("닫기", Icon.close) { document.closeHeaderFooter() }
    }

    // MARK: Groups shared by tabs

    @ViewBuilder private func clipboard(_ context: EditingContext) -> some View {
        ToolTile("오려 두기", Icon.cut) { send(#selector(NSText.cut(_:))) }
            .disabled(context.locked || (!context.hasRange && context.object == nil))
        ToolTile("복사하기", Icon.copy) { send(#selector(NSText.copy(_:))) }
            .disabled(!context.hasRange && context.object == nil)
        ToolTile("붙이기", Icon.paste) { send(#selector(NSText.paste(_:))) }
            .disabled(!context.hasSelection || context.locked)
    }
    private var find: some View {
        ToolTile("찾기", Icon.find, action: { viewer.showFind(replace: false) }, choices: { MenuItems.findChoices(viewer) })
    }
    @ViewBuilder private func shapes(_ context: EditingContext) -> some View {
        Group {
            ToolTile("글자 모양", Icon.charShape) { viewer.editingCharShape = true }
            ToolTile("문단 모양", Icon.paraShape) { viewer.editingParaShape = true }
        }
        .disabled(!context.canFormat)
    }
    @ViewBuilder private func orientation(_ context: EditingContext) -> some View {
        Group {
            ToolTile("세로", Icon.portrait) { viewer.setOrientation(landscape: false) }
            ToolTile("가로", Icon.landscape) { viewer.setOrientation(landscape: true) }
        }
        .disabled(context.locked)
    }
    private func columns(_ context: EditingContext) -> some View {
        ToolTile("단", Icon.columns, choices: {
            ["하나", "둘", "셋"].enumerated().map { index, title in Choice(title: title) { viewer.setColumns(UInt16(index + 1)) } }
        })
        .disabled(!context.inBody)
    }
    @ViewBuilder private func objects(_ context: EditingContext) -> some View {
        ToolTile("도형", Icon.shape, choices: { MenuItems.shapeChoices(viewer) })
            .disabled(!context.inBody)
        ToolTile("그림", Icon.picture) { viewer.insertPicture() }
            .disabled(!context.canPicture)
        table(context)
    }
    private func table(_ context: EditingContext) -> some View {
        ToolTile("표", Icon.table, action: { viewer.insertingTable = true }, panel: AnyView(TableGrid(viewer: viewer)))
            .disabled(!context.inBody)
    }
    private func symbols(_ context: EditingContext) -> some View {
        ToolTile("문자표", Icon.symbols) { viewer.insertingSymbols = true }
            .disabled(!context.hasSelection)
    }
    @ViewBuilder private func notes(_ context: EditingContext) -> some View {
        Group {
            ToolTile("각주", Icon.footnote) { viewer.insertNote(endnote: false) }
            ToolTile("미주", Icon.endnote) { viewer.insertNote(endnote: true) }
        }
        .disabled(!context.inBody)
    }
    @ViewBuilder private func headers(_ context: EditingContext) -> some View {
        Group {
            ToolTile("머리말", Icon.header, choices: { MenuItems.headerChoices(viewer, footer: false) })
            ToolTile("꼬리말", Icon.footer, choices: { MenuItems.headerChoices(viewer, footer: true) })
        }
        .disabled(context.locked)
    }
    /// 배치 and 캡션, for the selected object or the table holding the caret.
    @ViewBuilder private func arrangement(_ context: EditingContext) -> some View {
        Arrangement(document: document, viewer: viewer)
            .disabled(context.locked)
        RowDivider()
        captions(context)
    }
    private func captions(_ context: EditingContext) -> some View {
        ToolTile("캡션", Icon.caption, choices: {
            Captions.all.map { caption in Choice(title: caption.title) { viewer.insertCaption(caption.value) } }
        })
        .disabled(!context.canCaption)
    }
}

/// A tab's 펼침 단추: opens the menu bar's menu of the same name below it.
private struct MenuOpener: View {
    let title: String
    @State private var anchor = Anchor()
    var body: some View {
        Button {
            guard let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu, let view = anchor.view else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 2 : -2), in: view)
        } label: {
            Chevron().frame(width: 14, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(ToolButtonStyle())
        .background(AnchorView(anchor: anchor))
        .padding(.trailing, 6)
        .accessibilityLabel(title)
    }
}

/// 보기: 쪽 윤곽, the marks shown or hidden, 격자 and 확대/축소, lit or checked while on.
private struct ViewTiles: View {
    @ObservedObject var viewer: Viewer
    var body: some View {
        ToolTile("쪽 윤곽", Icon.pageOutline, on: viewer.showsOutline) { viewer.showsOutline.toggle() }
        RowDivider()
        VStack(alignment: .leading, spacing: 3) {
            Toggle("문단 부호", isOn: $viewer.showsParagraphMarks)
            Toggle("조판 부호", isOn: $viewer.showsControlCodes)
            Toggle("투명 선", isOn: $viewer.showsTransparentLines)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .padding(.horizontal, 5)
        .padding(.top, 3)
        VStack(alignment: .leading, spacing: 3) {
            Toggle("상황 선", isOn: $viewer.showsStatusBar)
            Toggle("눈금자", isOn: $viewer.showsRuler)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .padding(.horizontal, 5)
        .padding(.top, 3)
        ToolTile("격자", Icon.grid, on: viewer.showsGrid) { viewer.showsGrid.toggle() }
        RowDivider()
        ToolTile("작업 창", Icon.taskPane, choices: {
            TaskPane.allCases.map { pane in
                Choice(title: pane.rawValue, on: viewer.taskPane == pane) { viewer.taskPane = viewer.taskPane == pane ? nil : pane }
            }
        })
        RowDivider()
        ToolTile("축소", Icon.zoomOut) { viewer.canvas.zoomOut(nil) }
        ToolTile("확대", Icon.zoomIn) { viewer.canvas.zoomIn(nil) }
        ToolTile("100%", Icon.actualSize) { viewer.canvas.setZoom(1) }
        ToolTile("폭 맞춤", Icon.fitWidth) { viewer.canvas.fit(.width) }
        ToolTile("쪽 맞춤", Icon.fitPage) { viewer.canvas.fit(.page) }
    }
}

/// 표 레이아웃's 투명 선, lit while shown.
private struct TransparentLinesTile: View {
    @ObservedObject var viewer: Viewer
    var body: some View {
        ToolTile("투명 선", Icon.transparentLines, on: viewer.showsTransparentLines) { viewer.showsTransparentLines.toggle() }
    }
}

/// 도형: the shapes to draw as small icons in rows, as 한/글's 도형 꾸러미.
private struct ShapeGallery: View {
    let viewer: Viewer
    private static let order = ["line", "rectangle", "ellipse", "arc", "textbox"]
    var body: some View {
        let shapes = Self.order.compactMap { name in MenuItems.shapes.first { $0.shape == name } }
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(Array(stride(from: 0, to: shapes.count, by: 3)), id: \.self) { start in
                GridRow {
                    ForEach(shapes[start..<min(start + 3, shapes.count)], id: \.shape) { item in
                        ToolIcon(item.title, symbol: item.symbol) { viewer.draw(item.shape) }
                    }
                }
            }
        }
        .padding(.top, 3)
    }
}

/// 스타일: the document's first styles in a small grid, all of them from the arrow, as 한/글's 서식 탭.
private struct StyleGallery: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor
    @State private var anchor = Anchor()
    var body: some View {
        let styles = Array(document.styles.prefix(4))
        HStack(alignment: .top, spacing: 2) {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            if index < styles.count {
                                let style = styles[index]
                                Button { document.applyStyle(style.id, editor.undoManager) } label: {
                                    Text(style.name).font(.system(size: 12)).lineLimit(1)
                                        .padding(.horizontal, 6).frame(width: 92, height: 24, alignment: .leading)
                                }
                                .buttonStyle(ToolButtonStyle(on: style.id == document.format?.style))
                            }
                        }
                    }
                }
            }
            Button { DropDown.show(FormatRow.styles(document, editor), below: anchor.view) } label: {
                Chevron().frame(width: 14, height: 50)
            }
            .buttonStyle(ToolButtonStyle())
            .background(AnchorView(anchor: anchor))
            .help("스타일")
        }
        .padding(.top, 3)
    }
}

/// 배치: 글자처럼 취급, and 어울림, 자리 차지, 글 앞으로 or 글 뒤로 for an object out of the line.
private struct Arrangement: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var props: ObjectProps?
    private static let wraps: [(wrap: String, title: String, symbol: String)] = [
        ("Square", "어울림", Icon.wrapSquare), ("TopAndBottom", "자리 차지", Icon.wrapTopAndBottom),
        ("InFrontOfText", "글 앞으로", Icon.inFrontOfText), ("BehindText", "글 뒤로", Icon.behindText),
    ]
    var body: some View {
        let inLine = props?.treatAsChar == true
        VStack(alignment: .leading, spacing: 4) {
            Toggle("글자처럼 취급", isOn: Binding(get: { inLine }, set: { viewer.arrange(ObjectProps(treatAsChar: $0)) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack(spacing: 1) {
                ForEach(Self.wraps, id: \.wrap) { item in
                    ToolIcon(item.title, symbol: item.symbol, on: !inLine && props?.textWrap == item.wrap) {
                        viewer.arrange(ObjectProps(treatAsChar: false, textWrap: item.wrap))
                    }
                }
            }
            .disabled(inLine)
        }
        .padding(.horizontal, 5)
        .padding(.top, 3)
        .disabled(props == nil)
        // Read again after every edit, so the checks follow undo and 개체 속성.
        .task(id: "\(document.revision) \(String(describing: viewer.arrangedObject))") {
            guard let object = viewer.arrangedObject else { return props = nil }
            props = try? await document.objectProps(object)
        }
    }
}

/// SF Symbols shared by the tool rows and the menu bar.
enum Icon {
    static let save = "square.and.arrow.down", cut = "scissors", copy = "doc.on.doc", paste = "clipboard"
    static let styleCopy = "paintbrush", find = "magnifyingglass", replace = "arrow.left.arrow.right"
    static let goTo = "arrow.right.to.line", table = "tablecells", picture = "photo", equation = "function", symbols = "character.book.closed"
    static let charShape = "textformat", paraShape = "text.alignleft"
    static let header = "rectangle.topthird.inset.filled", footer = "rectangle.bottomthird.inset.filled"
    static let footnote = "note.text", endnote = "doc.plaintext"
    static let objectProps = "slider.horizontal.3", pictureEffect = "camera.filters"
    static let brightness = "sun.max", contrast = "circle.lefthalf.filled", originalPicture = "arrow.uturn.backward"
    static let pageSetup = "doc.text", print = "printer", pdf = "arrow.up.document"
    static let pageBreak = "arrow.down.to.line", columnBreak = "arrow.right.to.line.compact"
    static let insertRow = "plus.rectangle", deleteRow = "minus.rectangle"
    static let controlCodes = "chevron.left.forwardslash.chevron.right", paragraphMarks = "paragraphsign"
    static let documentInfo = "info.circle", eraseCodes = "eraser", bookmark = "bookmark", newNumber = "number", pageHide = "eye.slash"
    static let grid = "grid", caption = "text.below.photo", shape = "square.on.circle"
    static let textbox = "character.textbox", rectangle = "rectangle", ellipse = "circle", line = "line.diagonal", arc = "rainbow"
    static let splitCells = "square.split.2x2", mergeCells = "square.dashed"
    static let undo = "arrow.uturn.backward", redo = "arrow.uturn.forward", delete = "delete.left"
        static let levelUp = "increase.indent", levelDown = "decrease.indent"
    static let equalHeight = "arrow.up.and.down.square", equalWidth = "arrow.left.and.right.square"
    static let blockCalculation = "sum"
    static let newDocument = "doc.badge.plus", open = "folder", taskPane = "sidebar.right"
    static let columns = "rectangle.split.2x1", bullets = "list.bullet", numbering = "list.number"
    static let portrait = "rectangle.portrait", landscape = "rectangle", pageOutline = "doc.richtext"
    static let zoomIn = "plus.magnifyingglass", zoomOut = "minus.magnifyingglass", actualSize = "1.magnifyingglass"
    static let fitWidth = "arrow.left.and.right", fitPage = "arrow.up.left.and.arrow.down.right", transparentLines = "rectangle.dashed"
    static let textIn = "a.square", front = "square.2.layers.3d.top.filled", back = "square.2.layers.3d.bottom.filled"
    static let group = "rectangle.3.group", previous = "chevron.up", next = "chevron.down", close = "xmark.circle"
    static let wrapSquare = "text.justify.left", wrapTopAndBottom = "rectangle.center.inset.filled"
    static let inFrontOfText = "square.3.layers.3d.top.filled", behindText = "square.3.layers.3d.bottom.filled"
    /// 머리말 or 꼬리말 shapes as the web editor draws them: a page with the number's place
    /// marked in red at its top or bottom; (모양 없음) only keeps the room.
    static func pageNumber(_ placement: Placement?, footer: Bool) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            guard let placement else { return true }
            let page = NSRect(x: 2.5, y: 0.5, width: 11, height: 15)
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(rect: page).stroke()
            let x: CGFloat = switch placement {
            case .left: page.minX + 1
            case .center: page.midX - 2
            case .right: page.maxX - 5
            }
            let mark = NSRect(x: x, y: footer ? page.maxY - 5 : page.minY + 1, width: 4, height: 4)
            NSColor.systemRed.withAlphaComponent(0.25).setFill()
            mark.fill()
            NSColor.systemRed.setStroke()
            NSBezierPath(rect: mark.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }
}

/// One drop-down command; `nil` in a list separates groups.
struct Choice {
    let title: String
    var symbol: String?
    var image: NSImage?
    var key = ""
    var modifiers: NSEvent.ModifierFlags = .command
    var enabled = true
    var on = false
    /// Shown as a submenu instead of running `action`.
    var submenu: [Choice?] = []
    var action: () -> Void = {}
}

/// A large icon over its name. With `choices` (a menu) or `panel` (a popover), an
/// arrow under the name opens them, and the icon runs `action` when there is one.
struct ToolTile: View {
    let title: String, symbol: String
    var action: (() -> Void)?
    var choices: (() -> [Choice?])?
    var panel: AnyView?
    /// Lit, for tiles that turn something on.
    var on = false
    @State private var anchor = Anchor()
    @State private var showsPanel = false

    init(_ title: String, _ symbol: String, on: Bool = false, action: @escaping () -> Void) {
        (self.title, self.symbol, self.on, self.action) = (title, symbol, on, action)
    }
    init(_ title: String, _ symbol: String, action: (() -> Void)? = nil,
         choices: (() -> [Choice?])? = nil, panel: AnyView? = nil) {
        (self.title, self.symbol, self.action, self.choices, self.panel) = (title, symbol, action, choices, panel)
    }

    var body: some View {
        if choices == nil, panel == nil {
            Button(action: { action?() }) {
                VStack(spacing: 3) { icon; label(Text(Self.lines(title))) }.tile()
            }
            .buttonStyle(ToolButtonStyle(on: on))
        } else if let action {
            VStack(spacing: 0) {
                Button(action: action) { icon.tile().padding(.bottom, 3) }
                    .buttonStyle(ToolButtonStyle())
                Button(action: open) { label(Text(title), arrow: true).tile(top: 0) }
                    .buttonStyle(ToolButtonStyle())
                    .background(AnchorView(anchor: anchor))
            }
            .popover(isPresented: $showsPanel, arrowEdge: .bottom) { panel }
        } else {
            Button(action: open) {
                VStack(spacing: 3) { icon; label(Text(title), arrow: true) }.tile()
            }
            .buttonStyle(ToolButtonStyle())
            .background(AnchorView(anchor: anchor))
        }
    }

    /// A name on one line over the arrow, or on up to two lines without one, in the same height.
    private func label(_ text: Text, arrow: Bool = false) -> some View {
        VStack(spacing: 0) {
            text.font(.system(size: 12)).multilineTextAlignment(.center).fixedSize()
            if arrow {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).frame(height: 10)
            }
        }
        .frame(height: 30, alignment: .top)
    }
    private var icon: some View {
        Image(systemName: symbol).font(.system(size: 19, weight: .light)).frame(height: 22)
    }
    /// A name of several words on two lines, broken at the space nearest the middle, as
    /// the web tool box writes 글자 모양 and 조판 부호.
    static func lines(_ title: String) -> String {
        let words = title.split(separator: " ")
        guard words.count > 1 else { return title }
        let split = (1..<words.count).min { a, b in
            let width = { (i: Int) in max(words[..<i].joined(separator: " ").count, words[i...].joined(separator: " ").count) }
            return width(a) < width(b)
        }!
        return words[..<split].joined(separator: " ") + "\n" + words[split...].joined(separator: " ")
    }
    private func open() {
        if panel != nil { showsPanel = true } else if let choices { DropDown.show(choices(), below: anchor.view) }
    }
}

private extension View {
    /// As wide as the tile's own name and icon need.
    func tile(top: CGFloat = 3) -> some View {
        frame(minWidth: 32).padding(.top, top).padding(.horizontal, 5)
    }
}

/// The view a drop-down opens below.
final class Anchor {
    weak var view: NSView?
}
struct AnchorView: NSViewRepresentable {
    let anchor: Anchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// Native pop-up menus for the tool rows.
@MainActor
enum DropDown {
    static func show(_ choices: [Choice?], below view: NSView?) {
        guard let view else { return }
        let y = view.isFlipped ? view.bounds.maxY + 2 : -2
        menu(choices).popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
    static func menu(_ choices: [Choice?]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in choices {
            guard let choice else {
                menu.addItem(.separator())
                continue
            }
            let handler = Handler(choice.action)
            let item = NSMenuItem(title: choice.title, action: #selector(Handler.run), keyEquivalent: choice.key)
            (item.target, item.representedObject) = (handler, handler)
            item.keyEquivalentModifierMask = choice.modifiers
            item.isEnabled = choice.enabled
            item.state = choice.on ? .on : .off
            if choice.title.isEmpty, let image = choice.image {
                // A picture alone is left out of the menu's width, so it goes in as the title.
                let picture = NSTextAttachment()
                picture.image = image
                item.attributedTitle = NSAttributedString(attachment: picture)
            } else {
                item.image = choice.image ?? choice.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            }
            if !choice.submenu.isEmpty { item.submenu = Self.menu(choice.submenu) }
            menu.addItem(item)
        }
        return menu
    }
    private final class Handler: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}

/// 표 drop-down: pick the size on a grid, or open 표 만들기.
private struct TableGrid: View {
    let viewer: Viewer
    @State private var rows = 0
    @State private var columns = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // As in the web editor: 취소 until a size is pointed at.
            Button(rows > 0 ? "\(rows) × \(columns)" : "취소") { dismiss() }
                .buttonStyle(.borderless)
                .monospacedDigit()
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(1...8, id: \.self) { row in
                    GridRow {
                        ForEach(1...10, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(row <= rows && column <= columns ? Color.accentColor.opacity(0.3) : .clear)
                                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.separator))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                                .onHover { if $0 { (rows, columns) = (row, column) } }
                                .onTapGesture {
                                    dismiss()
                                    viewer.insertTable(rows: row, columns: column)
                                }
                        }
                    }
                }
            }
            Divider()
            Button("표 만들기…") {
                dismiss()
                viewer.insertingTable = true
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
    }
}
