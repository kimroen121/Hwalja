import AppKit
import SwiftUI

/// The inspector at the window's right, as Pages' 포맷 and Xcode's: 글자, 문단 and 스타일 for
/// the text at the caret, and the 개체 탭 and 상황 탭 of 한/글 (그림, 도형, 표 …) while they
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

    static let textTabs = ["글자", "문단", "스타일"]
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
    /// A selected object has only its own tabs; text has 글자, 문단 and 스타일 before them.
    static func tabs(_ context: EditingContext) -> [String] {
        let extra = contextTabs(context)
        return [.picture, .shape].contains(context.object) ? extra : textTabs + extra
    }

    var body: some View {
        let context = document.context, tabs = Self.tabs(context)
        let tab = tabs.contains(chosen) ? chosen : tabs[0]
        VStack(spacing: 0) {
            if tabs.count > 1 {
                Segments(tabs, selection: Binding(get: { tab }, set: { chosen = $0 }), size: .large) { .init(title: $0, help: $0) }
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
        case "글자": CharacterTab(document: document, viewer: viewer)
        case "문단": ParagraphTab(document: document, viewer: viewer)
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
                Toggle("글자 넣기", isOn: Binding(get: { textBox }, set: { attach in viewer.change { .setTextBox($0, attach: attach) } }))
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
        Toggle("글자처럼 취급", isOn: Binding(get: { inLine }, set: { viewer.arrange(ObjectProps(treatAsChar: $0)) }))
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

/// 글자: font, size, character styles and colors, and 글자 모양 for the rest.
private struct CharacterTab: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var language: Int?

    var body: some View {
        let editor = viewer.canvas.editor, text = document.format?.text
        let languages = document.format?.languages ?? []
        let font = language.flatMap { languages.indices.contains($0) ? languages[$0].font : nil } ?? text?.font
        Group {
            InspectorSection("글꼴") {
                Picker("글꼴", selection: Binding(get: { font ?? "" }, set: { editor.format(CharStyle(language: language, font: $0)) })) {
                    ForEach(FormatChoices.families, id: \.family) { Text($0.name).tag($0.family) }
                }
                .labelsHidden()
                .flexibleButtons()
                HStack(spacing: 8) {
                    let styles: [(title: String, symbol: String, on: Bool?, toggle: () -> Void)] = [
                        ("진하게", "bold", text?.bold, editor.toggleBold), ("기울임", "italic", text?.italic, editor.toggleItalic),
                        ("밑줄", "underline", text?.underline, editor.toggleUnderline), ("취소선", "strikethrough", text?.strikethrough, editor.toggleStrikethrough),
                    ]
                    Segments(segments: styles.map { .init(symbol: $0.symbol, help: $0.title) }, on: styles.map { $0.on == true }, any: true) {
                        styles[$0].toggle()
                    }
                    NumberStepper(value: text?.size, unit: "pt", range: 1...4096) { editor.format(CharStyle(size: $0)) }
                }
                LabeledContent("언어") {
                    Picker("언어", selection: $language) {
                        Text("대표").tag(Int?.none)
                        ForEach(CharShapeSheet.languageNames.indices, id: \.self) { Text(CharShapeSheet.languageNames[$0]).tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            InspectorSection {
                LabeledContent("글자 색") {
                    ColorPicker("글자 색", selection: color(text?.color ?? "#000000") { editor.format(CharStyle(color: $0)) }, supportsOpacity: false)
                        .labelsHidden()
                }
                LabeledContent("형광펜") {
                    ColorPicker("형광펜", selection: color(text?.shade ?? FormatChoices.none) { editor.format(CharStyle(shade: $0)) },
                                supportsOpacity: false)
                        .labelsHidden()
                }
            } footer: {
                DialogButtons { Button("글자 모양…") { viewer.editingCharShape = true } }
            }
        }
        .disabled(!document.context.canFormat)
    }

    private func color(_ hex: String, set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { HexColor.color(hex) }, set: { set(HexColor.hex($0)) })
    }
}

/// 문단: alignment, line spacing and lists, each choice in sight, and 문단 모양 for the rest.
private struct ParagraphTab: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer

    var body: some View {
        let editor = viewer.canvas.editor, paragraph = document.format?.paragraph
        let head = paragraph?.head ?? "None"
        Group {
            InspectorSection("정렬") {
                Segments(Alignment.allCases.map(Optional.some),
                         selection: Binding(get: { paragraph?.alignment }, set: { if let alignment = $0 { editor.format(ParaStyle(alignment: alignment)) } })) {
                    let label = FormatChoices.label($0!)
                    return .init(symbol: label.symbol, help: label.title)
                }
                LabeledContent("줄 간격") {
                    NumberStepper(value: paragraph?.lineSpacing, unit: paragraph?.lineSpacingKind == .percent || paragraph == nil ? "%" : "pt",
                                  range: 50...500, step: 10) {
                        editor.format(ParaStyle(lineSpacing: $0, lineSpacingKind: .percent))
                    }
                }
            }
            InspectorSection("글머리표 및 문단 번호") {
                Segments(["None", "Bullet", "Number"], selection: Binding(get: { ["Bullet", "Number"].contains(head) ? head : "None" }, set: { kind in
                    editor.format(kind == "Bullet" ? ParaStyle(head: kind, bullet: FormatChoices.bullets[0])
                                  : kind == "Number" ? ParaStyle(head: kind, numbering: 0) : ParaStyle(head: "None"))
                })) { let title = ["None": "없음", "Bullet": "글머리표", "Number": "문단 번호"][$0]!; return .init(title: title, help: title) }
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
            } footer: {
                DialogButtons {
                    Button("문단 번호 모양…") { viewer.editingList = "문단 번호" }
                    Button("문단 모양…") { viewer.editingParaShape = true }
                }
            }
        }
        .disabled(!document.context.canFormat)
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
        Toggle("투명 선", isOn: $viewer.showsTransparentLines)
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

/// A tile's face: a large icon over the name, with ⌄ when it opens a menu.
struct TileLabel: View {
    let title: String
    let symbol: String
    var menu = false
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 19)).frame(height: 22)
            HStack(spacing: 2) {
                Text(title).lineLimit(2).multilineTextAlignment(.center)
                if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
            }
            .font(.callout)
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
    /// Buttons and pop-ups as wide as their place, as macOS 26 sizes them; fitted before it.
    @ViewBuilder func flexibleButtons() -> some View {
        if #available(macOS 26, *) { buttonSizing(.flexible) } else { self }
    }
}
