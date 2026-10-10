import AppKit
import SwiftUI

/// The inspector at the window's right, as Keynote's 포맷: 텍스트 and 스타일 for the text at the caret, and the 개체 탭 and 상황 탭 of 한/글 (그림, 도형, 표 …) while they
/// apply, in macOS's own controls. What it changes applies at once; the full dialogs open from it.
struct Inspector: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var chosen: String
    /// The selected object's (or the caret's table's) properties, read again after every edit.
    @State private var props: ObjectProps?

    init(document: HwpDocument, viewer: Viewer, tab: String? = nil) {
        (self.document, self.viewer, _chosen) = (document, viewer, State(initialValue: tab ?? viewer.inspectorTab))
    }

    static let textTabs = ["텍스트", "스타일"]
    /// The 개체 탭 and 상황 탭 for what is selected.
    static func contextTabs(_ context: EditingContext) -> [String] {
        switch context.object {
        case .picture: ["그림"]
        case .shape: context.chart ? ["차트 디자인"] : ["도형"]
        case .equation: []
        case .table, nil:
            context.inHeaderFooter ? ["머리말/꼬리말"] : context.inNote ? ["주석"]
                : context.inTable ? ["표 디자인", "표 레이아웃"] : []
        }
    }
    /// A selected object has only its own tabs; text has 텍스트 and 스타일 before them.
    static func tabs(_ context: EditingContext) -> [String] {
        let extra = contextTabs(context)
        return [.picture, .shape].contains(context.object) ? extra : textTabs + extra
    }

    var body: some View {
        let context = document.context, tabs = Self.tabs(context)
        let tab = tabs.contains(chosen) ? chosen : tabs[0]
        VStack(spacing: 0) {
            if tabs.count > 1 {
                Segments(tabs, selection: Binding(get: { tab }, set: { chosen = $0 }), size: .large, capsule: true) { .init(title: $0, help: $0) }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            } else {
                Text(tab).font(.headline).foregroundStyle(.secondary).frame(height: 44)
            }
            Divider().padding(.horizontal, 16)
            if tab == "스타일" {
                StylePane(document: document, viewer: viewer)
            } else {
                InspectorScroll { content(tab, context) }
                    .disabled(context.locked)
            }
        }
        .onChange(of: chosen) { viewer.inspectorTab = chosen }
        .onChange(of: Self.contextTabs(context)) { old, new in
            // A selected object, 머리말/꼬리말 or 주석 brings its tab up; a table's do not, so typing in cells keeps the tab.
            if let first = new.first, !old.contains(first), !first.hasPrefix("표") { chosen = first }
        }
        .task(id: "\(document.revision) \(String(describing: viewer.arrangedObject))") {
            guard let object = viewer.arrangedObject else { return props = nil }
            props = try? await document.objectProps(object)
        }
    }

    @ViewBuilder private func content(_ tab: String, _ context: EditingContext) -> some View {
        switch tab {
        case "텍스트": TextTab(document: document, viewer: viewer)
        case "그림": picture(context)
        case "도형": shape(context)
        case "차트 디자인": chart(context)
        case "표 디자인": tableDesign(context)
        case "표 레이아웃": tableLayout(context)
        case "머리말/꼬리말": headerFooter(context)
        case "주석": annotations(context)
        default: EmptyView()
        }
    }

    // MARK: 개체 탭과 상황 탭

    @ViewBuilder private func picture(_ context: EditingContext) -> some View {
        InspectorSection("효과") {
            Segments(["RealPic", "GrayScale", "BlackWhite", "Watermark"], selection: Binding(get: { Self.effect(props) }, set: { effect in
                viewer.adjustPicture { props in
                    if effect == "Watermark" { (props.effect, props.brightness, props.contrast) = ("RealPic", 70, -50) } else { props.effect = effect }
                }
            })) { let title = ["RealPic": "효과 없음", "GrayScale": "회색조", "BlackWhite": "흑백", "Watermark": "워터마크"][$0]!; return .init(title: title, help: title) }
            PictureSlider(title: "밝기", value: props?.brightness) { value in viewer.adjustPicture { $0.brightness = value } }
            PictureSlider(title: "대비", value: props?.contrast) { value in viewer.adjustPicture { $0.contrast = value } }
        }
        InspectorSection("그림") {
            Tiles {
                command("그림 바꾸기…", Icon.replacePicture) { viewer.replacePicture() }
                command("삽입 그림 저장하기…", Icon.saveAs) { viewer.savePicture() }
                command("원본 그림으로", Icon.originalPicture) { MenuItems.restorePicture(viewer) }
                command("개체 선택", Icon.selectObjects) { viewer.draw("select") }
            }
        }
        arrangement(context, order: false)
        properties("그림 속성…")
    }
    @ViewBuilder private func shape(_ context: EditingContext) -> some View {
        if let textBox = document.object?.textBox {
            InspectorSection {
                Toggle("글자 넣기", isOn: Binding(get: { textBox }, set: { attach in viewer.change { .setTextBox($0, attach: attach) } })).checkbox()
            }
        }
        arrangement(context, order: true)
        InspectorSection { Tiles { command("개체 선택", Icon.selectObjects) { viewer.draw("select") } } }
        properties("도형 속성…")
    }
    @ViewBuilder private func chart(_ context: EditingContext) -> some View {
        InspectorSection { Tiles { command("데이터 편집…", Icon.chartData) { viewer.editChartData() } } }
        InspectorSection("배치") { wrap }
        captions(context)
    }
    /// 본문과의 배치, 회전, 순서, 그룹, 개체 보호 and 캡션 of a selected picture or shape, each
    /// shown as its buttons.
    @ViewBuilder private func arrangement(_ context: EditingContext, order: Bool) -> some View {
        InspectorSection("배치") { wrap }
        InspectorSection("회전") { ChoiceButtons(items: viewer.rotationChoices) }
        if order {
            InspectorSection("순서") {
                ChoiceButtons(items: [
                    Choice(title: "맨 앞으로", symbol: Icon.front) { viewer.change { .order($0, .front) } },
                    Choice(title: "앞으로") { viewer.change { .order($0, .forward) } },
                    Choice(title: "뒤로") { viewer.change { .order($0, .backward) } },
                    Choice(title: "맨 뒤로", symbol: Icon.back) { viewer.change { .order($0, .back) } },
                ])
            }
        }
        InspectorSection("그룹") { ChoiceButtons(items: viewer.groupChoices) }
        InspectorSection("개체 보호") { ChoiceButtons(items: viewer.protectionChoices, columns: 1) }
        captions(context)
    }
    /// 글자처럼 취급, and 어울림, 자리 차지, 글 앞으로 or 글 뒤로 for an object out of the line.
    @ViewBuilder private var wrap: some View {
        let inLine = props?.treatAsChar == true
        Toggle("글자처럼 취급", isOn: Binding(get: { inLine }, set: { viewer.arrange(ObjectProps(treatAsChar: $0)) })).checkbox()
        let wraps = ["Square": ("어울림", Icon.wrapSquare), "TopAndBottom": ("자리 차지", Icon.wrapTopAndBottom),
                     "InFrontOfText": ("글 앞으로", Icon.inFrontOfText), "BehindText": ("글 뒤로", Icon.behindText)]
        Segments(["Square", "TopAndBottom", "InFrontOfText", "BehindText"],
                 selection: Binding(get: { inLine ? "" : props?.textWrap ?? "" }, set: { viewer.arrange(ObjectProps(treatAsChar: false, textWrap: $0)) })) {
            .init(title: wraps[$0]!.0, help: wraps[$0]!.0)
        }
        .disabled(inLine || props == nil)
    }
    private func captions(_ context: EditingContext) -> some View {
        InspectorSection("캡션") {
            CaptionGrid { viewer.insertCaption($0) }
        }
        .disabled(!context.canCaption)
    }
    /// The object's own dialog, under the last group.
    private func properties(_ title: String) -> some View {
        DialogButtons { Button(title) { viewer.showObjectProperties() } }.padding(16)
    }

    @ViewBuilder private func tableDesign(_ context: EditingContext) -> some View {
        InspectorSection("셀 테두리/배경") {
            ChoiceButtons(items: [
                Choice(title: "각 셀마다 적용…") { viewer.showCellBorder(one: false) },
                Choice(title: "하나의 셀처럼 적용…") { viewer.showCellBorder(one: true) },
            ], columns: 1)
            TransparentLinesToggle(viewer: viewer)
        }
        InspectorSection("배치") { wrap }
        captions(context)
        properties("표 속성…")
    }
    @ViewBuilder private func tableLayout(_ context: EditingContext) -> some View {
        InspectorSection("줄/칸 추가하기") {
            ChoiceButtons(items: [
                Choice(title: "위쪽에 줄", symbol: "arrow.up.to.line") { viewer.editTable(.insertRowAbove) },
                Choice(title: "아래쪽에 줄", symbol: "arrow.down.to.line") { viewer.editTable(.insertRowBelow) },
                Choice(title: "왼쪽에 칸", symbol: "arrow.left.to.line") { viewer.editTable(.insertColumnLeft) },
                Choice(title: "오른쪽에 칸", symbol: "arrow.right.to.line") { viewer.editTable(.insertColumnRight) },
            ])
        }
        InspectorSection("줄/칸 지우기") {
            ChoiceButtons(items: [
                Choice(title: "줄 지우기", symbol: Icon.deleteRow) { viewer.editTable(.deleteRow) },
                Choice(title: "칸 지우기", symbol: Icon.deleteRow) { viewer.editTable(.deleteColumn) },
            ])
        }
        InspectorSection("셀") {
            Tiles {
                command("셀 나누기…", Icon.splitCells) { viewer.splittingCells = true }
                Group {
                    command("셀 합치기", Icon.mergeCells) { viewer.editCells { .mergeCells($0) } }
                    command("셀 너비를 같게", Icon.equalWidth) { viewer.editCells { .equalizeCells($0, height: false) } }
                    command("셀 높이를 같게", Icon.equalHeight) { viewer.editCells { .equalizeCells($0, height: true) } }
                }
                .disabled(!context.cellBlock)
            }
        }
        InspectorSection("표") {
            Tiles {
                command("표 뒤집기…", Icon.flipTable) { viewer.flippingTable = true }
                command("표 나누기", Icon.splitTable) { viewer.editTable(.split) }
                command("표 붙이기", Icon.attachTable) { viewer.editTable(.attach) }
            }
        }
        InspectorSection("계산식") {
            ChoiceButtons(items: MenuItems.blockFunctions.map { function in
                Choice(title: function.title, enabled: context.cellBlock) { viewer.editCells { .calculateBlock($0, function.function) } }
            } + [Choice(title: "계산식…", symbol: Icon.calculation, enabled: !context.cellBlock) { viewer.calculating = true }])
        }
    }

    @ViewBuilder private func headerFooter(_ context: EditingContext) -> some View {
        InspectorSection("머리말") { ChoiceButtons(items: MenuItems.headerChoices(viewer, footer: false)) }
        InspectorSection("꼬리말") { ChoiceButtons(items: MenuItems.headerChoices(viewer, footer: true)) }
        InspectorSection("상용구") {
            ChoiceButtons(items: [("전체 쪽수", PageCode.total), ("현재 쪽 번호", .page), ("현재 쪽/전체 쪽수", .pageOfTotal)]
                .map { title, code in Choice(title: title) { viewer.insertPageCode(code) } })
        }
        InspectorSection {
            Tiles {
                command("이전 머리말/꼬리말", Icon.previous) { viewer.goTo(.previousHeaderFooter) }
                command("다음 머리말/꼬리말", Icon.next) { viewer.goTo(.nextHeaderFooter) }
                command("편집 용지…", Icon.pageSetup) { viewer.showPageSetup() }
                command("지우기", Icon.eraseCodes) { document.deleteHeaderFooter(viewer.undoManager) }
            }
        } footer: {
            DialogButtons { Button("닫기") { document.closeHeaderFooter() } }
        }
    }
    @ViewBuilder private func annotations(_ context: EditingContext) -> some View {
        InspectorSection {
            Tiles {
                command("각주/미주 모양…", Icon.noteShape) { viewer.showNoteShapes() }
                command("주석 지우기", Icon.eraseCodes) { document.deleteNote(viewer.undoManager) }
                command("이전 주석으로", Icon.previous) { viewer.goTo(.previousNote) }
                command("다음 주석으로", Icon.next) { viewer.goTo(.nextNote) }
            }
        } footer: {
            DialogButtons { Button("닫기") { document.closeNote() } }
        }
    }

    // MARK: Rows

    /// A command as a tile: its icon over its name.
    private func command(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { TileLabel(title: title, symbol: symbol) }
    }

    /// 색조 as the picker reads it; 워터마크 is no effect at its brightness and contrast.
    private static func effect(_ props: ObjectProps?) -> String {
        guard let props else { return "" }
        if props.effect == "RealPic", props.brightness == 70, props.contrast == -50 { return "Watermark" }
        return props.effect ?? "RealPic"
    }
}

/// The dialogs a group leads to: buttons as wide as the inspector, one under another, as Keynote's.
struct DialogButtons<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 8) { content }
            .controlSize(.large)
            .flexibleButtons()
    }
}

/// 텍스트, as Keynote's: the paragraph's 스타일 over 스타일 (font, character styles, colors,
/// alignment, spacing and lists) and 레이아웃 (margins, first line, line breaking, 테두리 and
/// 배경). All of 글자 모양 and 문단 모양 is here, each change applied at once.
private struct TextTab: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var layout: Bool
    /// The 언어 the font and scales show and change; nil for 대표 (all of them).
    @State private var language: Int?
    @State private var showsMore = false

    init(document: HwpDocument, viewer: Viewer) {
        (self.document, self.viewer, _layout) = (document, viewer, State(initialValue: viewer.textLayout))
    }

    private var editor: PageEditor { viewer.canvas.editor }
    private var text: CharStyle? { document.format?.text }
    private var paragraph: ParaStyle? { document.format?.paragraph }

    var body: some View {
        Group {
            InspectorSection {
                Picker("스타일", selection: Binding(get: { document.format?.style }, set: { id in
                    if let id { document.applyStyle(id, editor.undoManager) }
                })) {
                    if document.format == nil { Text("").tag(UInt32?.none) }
                    ForEach(document.styles) { Text($0.name).tag(UInt32?.some($0.id)) }
                }
                .labelsHidden()
                .controlSize(.extraLarge)
                .flexibleButtons()
                .disabled(!document.context.canApplyStyle)
                Segments([false, true], selection: $layout) { .init(title: $0 ? "레이아웃" : "스타일", help: $0 ? "레이아웃" : "스타일") }
            }
            Group { if layout { layoutPane } else { stylePane } }
                .disabled(!document.context.canFormat)
        }
        .onChange(of: layout) { viewer.textLayout = layout }
    }

    // MARK: 스타일

    @ViewBuilder private var stylePane: some View {
        let languages = document.format?.languages ?? []
        let font = language.flatMap { languages.indices.contains($0) ? languages[$0].font : nil } ?? text?.font
        InspectorSection("글꼴") {
            Picker("글꼴", selection: Binding(get: { font ?? "" }, set: { editor.format(CharStyle(language: language, font: $0)) })) {
                if let font, !FormatChoices.families.contains(where: { $0.family == font }) { Text(font).tag(font) }
                ForEach(FormatChoices.families, id: \.family) { Text($0.name).tag($0.family) }
            }
            .labelsHidden()
            .flexibleButtons()
            HStack(spacing: 8) {
                Picker("언어", selection: $language) {
                    Text("대표").tag(Int?.none)
                    ForEach(CharShapeSheet.languageNames.indices, id: \.self) { Text(CharShapeSheet.languageNames[$0]).tag(Int?.some($0)) }
                }
                .labelsHidden()
                .flexibleButtons()
                .help("언어")
                NumberStepper(value: text?.size, unit: "pt", range: 1...4096) { editor.format(CharStyle(size: $0)) }
                    .help("기준 크기")
            }
            HStack(spacing: 8) {
                let styles: [(title: String, symbol: String, on: Bool?, toggle: () -> Void)] = [
                    ("진하게", "bold", text?.bold, editor.toggleBold), ("기울임", "italic", text?.italic, editor.toggleItalic),
                    ("밑줄", "underline", text?.underline, editor.toggleUnderline), ("취소선", "strikethrough", text?.strikethrough, editor.toggleStrikethrough),
                ]
                Segments(segments: styles.map { .init(symbol: $0.symbol, help: $0.title) }, on: styles.map { $0.on == true }, any: true) {
                    styles[$0].toggle()
                }
                Button { showsMore = true } label: { Image(systemName: "gearshape") }
                    .help("글자 모양")
                    .accessibilityLabel("글자 모양")
                    .popover(isPresented: $showsMore, arrowEdge: .bottom) { more }
            }
        }
        InspectorSection {
            LabeledContent("글자 색") { ColorWell(hex: char(\.color, "#000000")) }
            LabeledContent("음영 색") { ColorWell(hex: char(\.shade, FormatChoices.none), none: FormatChoices.none) }
        }
        InspectorSection {
            Segments(Alignment.allCases.map(Optional.some),
                     selection: Binding(get: { paragraph?.alignment }, set: { if let alignment = $0 { editor.format(ParaStyle(alignment: alignment)) } })) {
                let label = FormatChoices.label($0!)
                return .init(symbol: label.symbol, help: label.title)
            }
        }
        InspectorSection {
            DisclosureGroup {
                LabeledContent("줄 간격") {
                    Picker("줄 간격", selection: Binding(get: { paragraph?.lineSpacingKind ?? .percent }, set: { kind in
                        guard kind != paragraph?.lineSpacingKind else { return }
                        editor.format(ParaStyle(lineSpacing: kind == .percent ? 160 : 12, lineSpacingKind: kind))
                    })) {
                        Text("글자에 따라").tag(LineSpacingKind.percent)
                        Text("고정 값").tag(LineSpacingKind.fixed)
                        Text("여백만 지정").tag(LineSpacingKind.spaceOnly)
                        Text("최소").tag(LineSpacingKind.minimum)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("문단 위") { length(\.spacingBefore) }
                LabeledContent("문단 아래") { length(\.spacingAfter) }
            } label: {
                LabeledContent {
                    let percent = (paragraph?.lineSpacingKind ?? .percent) == .percent
                    NumberStepper(value: paragraph?.lineSpacing, unit: percent ? "%" : "pt", range: percent ? 50...500 : 0...1000,
                                  step: percent ? 10 : 1) { value in
                        editor.format(ParaStyle(lineSpacing: value, lineSpacingKind: paragraph?.lineSpacingKind ?? .percent))
                    }
                } label: { Text("간격").font(.headline) }
            }
        }
        InspectorSection { lists }
    }

    /// 글머리표 및 문단 번호: the kind beside the title, its shapes, 수준 and 시작 번호 방식 under it.
    @ViewBuilder private var lists: some View {
        let head = paragraph?.head ?? "None"
        DisclosureGroup {
            if head == "Bullet" {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(FormatChoices.bullets, id: \.self) { bullet in
                        Toggle(bullet, isOn: Binding(get: { paragraph?.bullet == bullet },
                                                     set: { _ in editor.format(ParaStyle(head: "Bullet", bullet: bullet)) }))
                    }
                }
                .toggleStyle(.button)
                .flexibleButtons()
            } else if head == "Number" {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                    ForEach(FormatChoices.numberings.indices, id: \.self) { kind in
                        Toggle(isOn: Binding(get: { paragraph?.numbering == kind },
                                             set: { _ in editor.format(ParaStyle(head: "Number", numbering: kind)) })) {
                            Text(FormatChoices.numberings[kind].prefix(3).joined(separator: " ")).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
                .toggleStyle(.button)
                .flexibleButtons()
            }
            if head != "None" {
                LabeledContent("수준") {
                    Stepper("\((paragraph?.level ?? 0) + 1)", onIncrement: { editor.stepLevel(by: 1) }, onDecrement: { editor.stepLevel(by: -1) })
                }
            }
            if head == "Number", document.context.inBody, let numbering = paragraph?.numbering {
                Picker("시작 번호 방식", selection: Binding(get: { paragraph?.restart ?? 0 }, set: { restart in
                    editor.format(ParaStyle(head: "Number", numbering: numbering, restart: restart,
                                            startNumber: restart == 2 ? paragraph?.startNumber ?? 1 : nil))
                })) {
                    Text("앞 번호 목록에 이어").tag(0)
                    Text("이전 번호 목록에 이어").tag(1)
                    Text("새 번호 목록 시작").tag(2)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("1수준 시작 번호") {
                    NumberStepper(value: paragraph.flatMap { $0.startNumber }.map(Double.init), unit: "", range: 1...65535) { start in
                        editor.format(ParaStyle(head: "Number", numbering: numbering, restart: 2, startNumber: Int(start)))
                    }
                }
                .disabled(paragraph?.restart != 2)
            }
        } label: {
            LabeledContent {
                Picker("글머리표 및 문단 번호", selection: Binding(get: { ["Bullet", "Number"].contains(head) ? head : "None" }, set: { kind in
                    editor.format(kind == "Bullet" ? ParaStyle(head: kind, bullet: FormatChoices.bullets[0])
                                  : kind == "Number" ? ParaStyle(head: kind, numbering: 0) : ParaStyle(head: "None"))
                })) {
                    Text("없음").tag("None")
                    Text("글머리표").tag("Bullet")
                    Text("문단 번호").tag("Number")
                }
                .labelsHidden()
                .fixedSize()
            } label: { Text("글머리표 및 문단 번호").font(.headline) }
        }
    }

    /// The rest of 글자 모양: scales of the 언어, 첨자, the attributes, 밑줄, 취소선, 테두리 and 배경.
    private var more: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("장평") { lingual(\.ratio, range: 50...200) }
                LabeledContent("자간") { lingual(\.spacing, range: -50...50) }
                LabeledContent("상대 크기") { lingual(\.relativeSize, range: 10...250) }
                LabeledContent("글자 위치") { lingual(\.offset, range: -100...100) }
                Segments([0, 1, 2], selection: Binding(get: { text?.superscript == true ? 1 : text?.`subscript` == true ? 2 : 0 }, set: { place in
                    editor.format(CharStyle(superscript: place == 1, subscript: place == 2))
                })) { let title = ["보통", "위 첨자", "아래 첨자"][$0]; return .init(title: title, help: title) }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Toggle("외곽선", isOn: char(\.outline, false)); Toggle("그림자", isOn: char(\.shadow, false)) }
                    GridRow { Toggle("양각", isOn: char(\.emboss, false)); Toggle("음각", isOn: char(\.engrave, false)) }
                }
                .checkbox()
                Divider()
                Text("밑줄").font(.headline)
                LabeledContent("위치") {
                    Picker("위치", selection: Binding(get: { text?.underline != true ? 0 : text?.underlineTop == true ? 2 : 1 }, set: { place in
                        editor.format(place == 0 ? CharStyle(underline: false) : CharStyle(underline: true, underlineTop: place == 2))
                    })) { Text("없음").tag(0); Text("아래").tag(1); Text("위").tag(2) }
                    .labelsHidden()
                    .fixedSize()
                }
                Group {
                    LabeledContent("모양") { ChoiceField(char(\.underlineShape, 0), LineShapes.names.indices.map { ($0, LineShapes.names[$0]) }, images: LineShapes.images) }
                    LabeledContent("색") { ColorWell(hex: char(\.underlineColor, "#000000")) }
                }
                .disabled(text?.underline != true)
                Text("취소선").font(.headline)
                LabeledContent("모양") {
                    ChoiceField(Binding(get: { text?.strikethrough == true ? (text?.strikeShape ?? 0) + 1 : 0 }, set: { kind in
                        editor.format(kind == 0 ? CharStyle(strikethrough: false) : CharStyle(strikethrough: true, strikeShape: kind - 1))
                    }), Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds)
                }
                LabeledContent("색") { ColorWell(hex: char(\.strikeColor, "#000000")) }
                    .disabled(text?.strikethrough != true)
                Divider()
                BorderFillRows(style: Binding(get: { text ?? CharStyle() }, set: { new in
                    if let old = text { send(new.changesWithBorderFill(from: old)) }
                }))
            }
            .labeledContentStyle(RowStyle())
            .padding(16)
        }
        .frame(width: 300, height: 520)
    }

    // MARK: 레이아웃

    @ViewBuilder private var layoutPane: some View {
        InspectorSection("여백") {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 4) { length(\.marginLeft); Text("왼쪽").font(.caption) }
                VStack(spacing: 4) { length(\.marginRight); Text("오른쪽").font(.caption) }
            }
            .frame(maxWidth: .infinity)
        }
        InspectorSection("첫 줄") {
            let indent = paragraph?.indent ?? 0
            Segments([0, 1, -1], selection: Binding(get: { indent > 0 ? 1 : indent < 0 ? -1 : 0 }, set: { kind in
                let amount = abs(indent) == 0 ? 10 : abs(indent)
                editor.format(ParaStyle(indent: Double(kind) * amount))
            })) { let title = [0: "보통", 1: "들여쓰기", -1: "내어쓰기"][$0]!; return .init(title: title, help: title) }
            LabeledContent(indent < 0 ? "내어쓰기" : "들여쓰기") {
                NumberStepper(value: paragraph.map { abs($0.indent ?? 0) }, unit: "pt", range: 0...1000) { amount in
                    editor.format(ParaStyle(indent: indent < 0 ? -amount : amount))
                }
            }
            .disabled(indent == 0)
        }
        InspectorSection("줄 나눔 기준") {
            LabeledContent("한글 단위") {
                Picker("한글 단위", selection: para(\.koreanBreakUnit, 1)) { Text("글자").tag(1); Text("어절").tag(0) }.labelsHidden().fixedSize()
            }
            LabeledContent("영어 단위") {
                Picker("영어 단위", selection: para(\.englishBreakUnit, 0)) { Text("단어").tag(0); Text("하이픈").tag(1); Text("글자").tag(2) }
                    .labelsHidden().fixedSize()
            }
        }
        InspectorSection {
            BorderFillRows(style: Binding(get: { paragraph ?? ParaStyle() }, set: { new in
                if let old = paragraph { editor.format(new.changesWithBorderFill(from: old)) }
            }))
            Toggle("문단 테두리 연결", isOn: para(\.borderConnect, false)).checkbox()
        }
    }

    // MARK: Values

    /// A character value, applied as it is changed (테두리 and 배경 together, as the engine takes them).
    private func char<T>(_ key: WritableKeyPath<CharStyle, T?>, _ fallback: T) -> Binding<T> {
        Binding { text?[keyPath: key] ?? fallback } set: { value in
            guard let old = text else { return }
            var new = old
            new[keyPath: key] = value
            send(new.changesWithBorderFill(from: old))
        }
    }
    private func send(_ change: CharStyle) {
        if change != CharStyle() { editor.format(change) }
    }
    private func para<T>(_ key: WritableKeyPath<ParaStyle, T?>, _ fallback: T) -> Binding<T> {
        Binding { paragraph?[keyPath: key] ?? fallback } set: { value in
            guard let old = paragraph else { return }
            var new = old
            new[keyPath: key] = value
            let change = new.changes(from: old)
            if change != ParaStyle() { editor.format(change) }
        }
    }
    /// A length of the paragraph in points.
    private func length(_ key: WritableKeyPath<ParaStyle, Double?>) -> some View {
        NumberStepper(value: paragraph?[keyPath: key], unit: "pt", range: 0...1000) { value in
            var change = ParaStyle()
            change[keyPath: key] = value
            editor.format(change)
        }
    }
    /// A percentage of the chosen 언어, or of all of them.
    private func lingual(_ key: WritableKeyPath<CharStyle, Double?>, range: ClosedRange<Double>) -> some View {
        let languages = document.format?.languages ?? []
        let value = language.flatMap { languages.indices.contains($0) ? languages[$0][keyPath: key] : nil } ?? text?[keyPath: key]
        return NumberStepper(value: value, unit: "%", range: range) { value in
            var change = CharStyle(language: language)
            change[keyPath: key] = value
            editor.format(change)
        }
    }
}

/// 테두리 and 배경 of the text or paragraph, one row each.
private struct BorderFillRows<Style: BorderFillStyle>: View {
    @Binding var style: Style
    var body: some View {
        Text("테두리").font(.headline)
        LabeledContent("종류") { ChoiceField(int(\.borderLine), Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds) }
        LabeledContent("굵기") { ChoiceField(int(\.borderWidth), Swatches.widths.indices.map { ($0, "") }, images: Swatches.widthImages) }
        LabeledContent("색") { ColorWell(hex: text(\.borderColor, "#000000")) }
        Text("배경").font(.headline)
        LabeledContent("면 색") { ColorWell(hex: text(\.fillColor, "none"), none: "none") }
        LabeledContent("무늬 색") { ColorWell(hex: text(\.patternColor, "#000000")) }
        LabeledContent("무늬 모양") { ChoiceField(int(\.pattern), Swatches.patterns.indices.map { ($0, "") }, images: Swatches.patterns) }
    }
    private func int(_ key: WritableKeyPath<Style, Int?>) -> Binding<Int> {
        Binding { style[keyPath: key] ?? 0 } set: { style[keyPath: key] = $0 }
    }
    private func text(_ key: WritableKeyPath<Style, String?>, _ fallback: String) -> Binding<String> {
        Binding { style[keyPath: key] ?? fallback } set: { style[keyPath: key] = $0 }
    }
}

/// A number typed or stepped, with its unit; it applies on Return or a step.
private struct NumberStepper: View {
    let value: Double?
    let unit: String
    let range: ClosedRange<Double>
    var step: Double = 1
    let apply: (Double) -> Void
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
                .onSubmit { Double(text).map { apply(min(max($0, range.lowerBound), range.upperBound)) } }
            Text(unit).foregroundStyle(.secondary)
            Stepper("", onIncrement: { apply(min((value ?? range.lowerBound) + step, range.upperBound)) },
                    onDecrement: { apply(max((value ?? range.lowerBound) - step, range.lowerBound)) })
                .labelsHidden()
        }
        .onAppear { text = Self.label(value) }
        .onChange(of: value) { text = Self.label(value) }
    }
    private static func label(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

/// 밝기 or 대비 of a picture, applied when the slider is let go.
private struct PictureSlider: View {
    let title: String
    let value: Int32?
    let apply: (Int32) -> Void
    @State private var shown = 0.0
    var body: some View {
        LabeledContent(title) {
            Slider(value: $shown, in: -100...100, step: 5) { editing in
                if !editing, Int32(shown) != value { apply(Int32(shown)) }
            }
        }
        .onAppear { shown = Double(value ?? 0) }
        .onChange(of: value) { shown = Double(value ?? 0) }
    }
}

/// 표 디자인's 투명 선.
private struct TransparentLinesToggle: View {
    @ObservedObject var viewer: Viewer
    var body: some View {
        Toggle("투명 선", isOn: $viewer.showsTransparentLines).checkbox()
    }
}

/// 문서: the paper of the section holding the caret, as Keynote's 문서 inspector; 편집 용지 and
/// the section's other dialogs open from it.
struct DocumentInspector: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var page: PageSetup?

    var body: some View {
        let section = document.selection?.focus.target.section ?? 0
        VStack(spacing: 0) {
            Text("문서").font(.headline).foregroundStyle(.secondary).frame(height: 44)
            Divider().padding(.horizontal, 16)
            InspectorScroll {
                InspectorSection("용지 종류") {
                    let paper = paper(section)
                    Picker("용지 종류", selection: paper) {
                        if paper.wrappedValue == nil { Text("사용자 정의").tag(String?.none) }
                        ForEach(PageSetupSheet.papers, id: \.name) { Text($0.name).tag(String?.some($0.name)) }
                    }
                    .labelsHidden()
                    .flexibleButtons()
                }
                InspectorSection("용지 방향") {
                    Segments([false, true], selection: Binding(get: { page?.landscape ?? false }, set: { landscape in set(section) { $0.landscape = landscape } }),
                             size: .large) {
                        .init(title: $0 ? "가로" : "세로", symbol: $0 ? Icon.landscape : Icon.portrait, help: $0 ? "가로" : "세로")
                    }
                }
                InspectorSection("용지 여백") {
                    margin("위쪽", \.marginTop, section)
                    margin("아래쪽", \.marginBottom, section)
                    margin("왼쪽", \.marginLeft, section)
                    margin("오른쪽", \.marginRight, section)
                    margin("머리말", \.marginHeader, section)
                    margin("꼬리말", \.marginFooter, section)
                } footer: {
                    DialogButtons {
                        Button("편집 용지…") { viewer.showPageSetup() }
                        Button("쪽 테두리/배경…") { viewer.showPageBorder() }
                        Button("구역 설정…") { viewer.showSectionSetup() }
                    }
                }
            }
            .disabled(page == nil || document.context.locked)
        }
        .task(id: "\(document.revision) \(section)") { page = try? await document.pageSetup(section: section) }
    }

    /// Changes the section's paper at once, as the 세로 and 가로 commands do.
    private func set(_ section: UInt32, _ change: (inout PageSetup) -> Void) {
        guard var changed = page else { return }
        change(&changed)
        guard changed != page else { return }
        page = changed
        viewer.setPage(changed, section: section)
    }
    private func margin(_ title: String, _ key: WritableKeyPath<PageSetup, UInt32>, _ section: UInt32) -> some View {
        LabeledContent(title) {
            NumberStepper(value: page.map { Units.millimeters($0[keyPath: key]) }, unit: "mm", range: 0...1000) { mm in
                set(section) { $0[keyPath: key] = Units.units(mm) }
            }
        }
    }
    private func paper(_ section: UInt32) -> Binding<String?> {
        Binding {
            guard let page else { return nil }
            let size = (Units.millimeters(page.width), Units.millimeters(page.height))
            return PageSetupSheet.papers.first { abs($0.width - size.0) < 0.5 && abs($0.height - size.1) < 0.5 }?.name
        } set: { name in
            guard let paper = PageSetupSheet.papers.first(where: { $0.name == name }) else { return }
            set(section) { ($0.width, $0.height) = (Units.units(paper.width), Units.units(paper.height)) }
        }
    }
}

// MARK: Keynote's inspector parts

/// The inspector's groups one under another, scrolling, with rows spread across it.
private struct InspectorScroll<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
        }
        .labeledContentStyle(RowStyle())
        .buttonBorderShape(.roundedRectangle)
    }
}

/// A group: its title in bold over its controls, and a line under it.
struct InspectorSection<Header: View, Content: View, Footer: View>: View {
    let header: Header
    let content: Content
    let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.font(.headline)
            content
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 16) }
    }
}
extension InspectorSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { (header, self.content, footer) = (EmptyView(), content(), EmptyView()) }
}
extension InspectorSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { (header, self.content, footer) = (Text(title), content(), EmptyView()) }
}
extension InspectorSection where Header == Text {
    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        (header, self.content, self.footer) = (Text(title), content(), footer())
    }
}
extension InspectorSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        (header, self.content, self.footer) = (EmptyView(), content(), footer())
    }
}
extension InspectorSection {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        (self.header, self.content, self.footer) = (header(), content(), footer())
    }
}

/// A label at the leading edge and its control at the trailing one.
private struct RowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

/// Commands as tiles, two to a row.
struct Tiles<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) { content }
            .flexibleButtons()
    }
}

/// A tile's face: a large icon over the name.
struct TileLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 19)).frame(height: 22)
            Text(title).lineLimit(2).multilineTextAlignment(.center).font(.callout)
        }
        .frame(maxWidth: .infinity, minHeight: 66)
        .padding(.horizontal, 4)
    }
}

/// `Choice`s as buttons in sight, two to a row (or `columns`), in place of a menu.
private struct ChoiceButtons: View {
    let items: [Choice?]
    var columns = 2
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(items.compactMap { $0 }.indices, id: \.self) { index in
                let item = items.compactMap { $0 }[index]
                Button(action: item.action) {
                    HStack(spacing: 6) {
                        if let image = item.image { Image(nsImage: image) } else if let symbol = item.symbol { Image(systemName: symbol) }
                        if !item.title.isEmpty { Text(item.title).lineLimit(1).minimumScaleFactor(0.75) }
                    }
                }
                .disabled(!item.enabled)
                .help(item.title)
            }
        }
        .flexibleButtons()
    }
}

/// 캡션: the nine places around the object as a grid, 캡션 없음 at its middle.
private struct CaptionGrid: View {
    let insert: (String) -> Void
    var body: some View {
        let places = ["LeftTop", "Top", "RightTop", "LeftCenter", "None", "RightCenter", "LeftBottom", "Bottom", "RightBottom"]
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(places, id: \.self) { place in
                let title = Captions.all.first { $0.value == place }!.title
                Button { insert(place) } label: { Text(title).lineLimit(1).minimumScaleFactor(0.7) }
                    .help(title)
            }
        }
        .flexibleButtons()
    }
}

extension View {
    /// A checkbox before its name, as Keynote's, not spread as the inspector's rows are.
    func checkbox() -> some View { toggleStyle(.checkbox).labeledContentStyle(.automatic) }
    /// Buttons and pop-ups as wide as their place, as macOS 26 sizes them; fitted before it.
    @ViewBuilder func flexibleButtons() -> some View {
        if #available(macOS 26, *) { buttonSizing(.flexible) } else { self }
    }
}
