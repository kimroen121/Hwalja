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

    init(document: HwpDocument, viewer: Viewer, tab: String = "글자") {
        (self.document, self.viewer, _chosen) = (document, viewer, State(initialValue: tab))
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
                Picker("", selection: Binding(get: { tab }, set: { chosen = $0 })) {
                    ForEach(tabs, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                Text(tab).font(.headline).frame(height: 36)
            }
            Divider()
            if tab == "스타일" {
                StylePane(document: document, viewer: viewer)
            } else {
                Form { content(tab, context) }
                    .formStyle(.grouped)
                    .disabled(context.locked)
            }
        }
        .controlSize(.small)
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
        Section("효과") {
            Picker("색조", selection: Binding(get: { Self.effect(props) }, set: { effect in
                viewer.adjustPicture { props in
                    if effect == "Watermark" { (props.effect, props.brightness, props.contrast) = ("RealPic", 70, -50) } else { props.effect = effect }
                }
            })) {
                Text("효과 없음").tag("RealPic")
                Text("회색조").tag("GrayScale")
                Text("흑백").tag("BlackWhite")
                Text("워터마크").tag("Watermark")
            }
            PictureSlider(title: "밝기", value: props?.brightness) { value in viewer.adjustPicture { $0.brightness = value } }
            PictureSlider(title: "대비", value: props?.contrast) { value in viewer.adjustPicture { $0.contrast = value } }
        }
        Section {
            command("그림 바꾸기…", Icon.replacePicture) { viewer.replacePicture() }
            command("삽입 그림 저장하기…", Icon.saveAs) { viewer.savePicture() }
            command("원본 그림으로", Icon.originalPicture) { MenuItems.restorePicture(viewer) }
        }
        arrangement(context, order: false)
        properties("그림 속성…")
    }
    @ViewBuilder private func shape(_ context: EditingContext) -> some View {
        if let textBox = document.object?.textBox {
            Section {
                Toggle("글자 넣기", isOn: Binding(get: { textBox }, set: { attach in viewer.change { .setTextBox($0, attach: attach) } }))
            }
        }
        arrangement(context, order: true)
        properties("도형 속성…")
    }
    @ViewBuilder private func chart(_ context: EditingContext) -> some View {
        Section {
            command("데이터 편집…", Icon.chartData) { viewer.editChartData() }
        }
        Section("배치") { wrap }
        Section { captions(context) }
    }
    /// 본문과의 배치, 회전, 순서, 그룹, 개체 보호 and 캡션 of a selected picture or shape.
    @ViewBuilder private func arrangement(_ context: EditingContext, order: Bool) -> some View {
        Section("배치") {
            wrap
            choices("회전", Icon.rotate, viewer.rotationChoices)
            if order {
                choices("순서", Icon.front, [
                    Choice(title: "맨 앞으로") { viewer.change { .order($0, .front) } },
                    Choice(title: "앞으로") { viewer.change { .order($0, .forward) } },
                    Choice(title: "뒤로") { viewer.change { .order($0, .backward) } },
                    Choice(title: "맨 뒤로") { viewer.change { .order($0, .back) } },
                ])
            }
            choices("그룹", Icon.group, viewer.groupChoices)
            choices("개체 보호", Icon.protect, viewer.protectionChoices)
        }
        Section {
            captions(context)
            command("개체 선택", Icon.selectObjects) { viewer.draw("select") }
        }
    }
    /// 글자처럼 취급, and 어울림, 자리 차지, 글 앞으로 or 글 뒤로 for an object out of the line.
    @ViewBuilder private var wrap: some View {
        let inLine = props?.treatAsChar == true
        Toggle("글자처럼 취급", isOn: Binding(get: { inLine }, set: { viewer.arrange(ObjectProps(treatAsChar: $0)) }))
        Picker("본문과의 배치", selection: Binding(get: { inLine ? "" : props?.textWrap ?? "" }, set: { wrap in
            viewer.arrange(ObjectProps(treatAsChar: false, textWrap: wrap))
        })) {
            Label("어울림", systemImage: Icon.wrapSquare).tag("Square")
            Label("자리 차지", systemImage: Icon.wrapTopAndBottom).tag("TopAndBottom")
            Label("글 앞으로", systemImage: Icon.inFrontOfText).tag("InFrontOfText")
            Label("글 뒤로", systemImage: Icon.behindText).tag("BehindText")
        }
        .disabled(inLine || props == nil)
    }
    private func captions(_ context: EditingContext) -> some View {
        choices("캡션", Icon.caption, Captions.all.map { caption in Choice(title: caption.title) { viewer.insertCaption(caption.value) } })
            .disabled(!context.canCaption)
    }
    /// The object's own dialog, under the last group.
    private func properties(_ title: String) -> some View {
        Section {} footer: { DialogButtons { Button(title) { viewer.showObjectProperties() } } }
    }

    @ViewBuilder private func tableDesign(_ context: EditingContext) -> some View {
        Section {
            choices("셀 테두리/배경", Icon.cellBorder, [
                Choice(title: "각 셀마다 적용…") { viewer.showCellBorder(one: false) },
                Choice(title: "하나의 셀처럼 적용…") { viewer.showCellBorder(one: true) },
            ])
            TransparentLinesToggle(viewer: viewer)
        }
        Section("배치") { wrap }
        Section { captions(context) }
        properties("표 속성…")
    }
    @ViewBuilder private func tableLayout(_ context: EditingContext) -> some View {
        Section("줄/칸") {
            choices("줄/칸 추가하기", Icon.insertRow, [
                Choice(title: "위쪽에 줄 추가하기") { viewer.editTable(.insertRowAbove) },
                Choice(title: "아래쪽에 줄 추가하기") { viewer.editTable(.insertRowBelow) }, nil,
                Choice(title: "왼쪽에 칸 추가하기") { viewer.editTable(.insertColumnLeft) },
                Choice(title: "오른쪽에 칸 추가하기") { viewer.editTable(.insertColumnRight) },
            ])
            choices("줄/칸 지우기", Icon.deleteRow, [
                Choice(title: "줄 지우기") { viewer.editTable(.deleteRow) }, nil,
                Choice(title: "칸 지우기") { viewer.editTable(.deleteColumn) },
            ])
        }
        Section("셀") {
            command("셀 나누기…", Icon.splitCells) { viewer.splittingCells = true }
            Group {
                command("셀 합치기", Icon.mergeCells) { viewer.editCells { .mergeCells($0) } }
                command("셀 너비를 같게", Icon.equalWidth) { viewer.editCells { .equalizeCells($0, height: false) } }
                command("셀 높이를 같게", Icon.equalHeight) { viewer.editCells { .equalizeCells($0, height: true) } }
            }
            .disabled(!context.cellBlock)
        }
        Section("표") {
            command("표 뒤집기…", Icon.flipTable) { viewer.flippingTable = true }
            command("표 나누기", Icon.splitTable) { viewer.editTable(.split) }
            command("표 붙이기", Icon.attachTable) { viewer.editTable(.attach) }
        }
        Section("계산식") {
            choices("블록 계산식", Icon.blockCalculation, MenuItems.blockFunctions.map { function in
                Choice(title: function.title) { viewer.editCells { .calculateBlock($0, function.function) } }
            })
            .disabled(!context.cellBlock)
            command("계산식…", Icon.calculation) { viewer.calculating = true }
                .disabled(context.cellBlock)
        }
    }

    @ViewBuilder private func headerFooter(_ context: EditingContext) -> some View {
        Section {
            choices("머리말", Icon.header, MenuItems.headerChoices(viewer, footer: false))
            choices("꼬리말", Icon.footer, MenuItems.headerChoices(viewer, footer: true))
            choices("상용구", Icon.autoText, [("전체 쪽수", PageCode.total), ("현재 쪽 번호", .page), ("현재 쪽/전체 쪽수", .pageOfTotal)]
                .map { title, code in Choice(title: title) { viewer.insertPageCode(code) } })
            command("편집 용지…", Icon.pageSetup) { viewer.showPageSetup() }
        }
        Section {
            command("이전 머리말/꼬리말", Icon.previous) { viewer.goTo(.previousHeaderFooter) }
            command("다음 머리말/꼬리말", Icon.next) { viewer.goTo(.nextHeaderFooter) }
            command("지우기", Icon.eraseCodes) { document.deleteHeaderFooter(viewer.undoManager) }
        } footer: {
            DialogButtons { Button("닫기") { document.closeHeaderFooter() } }
        }
    }
    @ViewBuilder private func annotations(_ context: EditingContext) -> some View {
        Section {
            command("각주/미주 모양…", Icon.noteShape) { viewer.showNoteShapes() }
            command("주석 지우기", Icon.eraseCodes) { document.deleteNote(viewer.undoManager) }
        }
        Section {
            command("이전 주석으로", Icon.previous) { viewer.goTo(.previousNote) }
            command("다음 주석으로", Icon.next) { viewer.goTo(.nextNote) }
        } footer: {
            DialogButtons { Button("닫기") { document.closeNote() } }
        }
    }

    // MARK: Rows

    /// A command as a row: its icon before its name.
    private func command(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
    }
    /// A row opening a menu of `items`.
    private func choices(_ title: String, _ symbol: String, _ items: [Choice?]) -> some View {
        Menu { ChoiceItems(items: items) } label: { Label(title, systemImage: symbol) }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.primary)
    }

    /// 색조 as the picker reads it; 워터마크 is no effect at its brightness and contrast.
    private static func effect(_ props: ObjectProps?) -> String {
        guard let props else { return "" }
        if props.effect == "RealPic", props.brightness == 70, props.contrast == -50 { return "Watermark" }
        return props.effect ?? "RealPic"
    }
}

/// Buttons under a group, at its trailing edge as in a form's footer.
private struct DialogButtons<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack {
            Spacer()
            content
        }
    }
}

/// `Choice`s as SwiftUI menu items: buttons, checked ones, submenus and separators.
struct ChoiceItems: View {
    let items: [Choice?]
    var body: some View {
        ForEach(items.indices, id: \.self) { index in
            if let item = items[index] {
                if !item.submenu.isEmpty {
                    Menu(item.title) { ChoiceItems(items: item.submenu) }
                } else if item.on {
                    Toggle(item.title, isOn: Binding(get: { true }, set: { _ in item.action() }))
                        .disabled(!item.enabled)
                } else {
                    Button(action: item.action) {
                        if let image = item.image { Label { Text(item.title) } icon: { Image(nsImage: image) } } else { Text(item.title) }
                    }
                    .disabled(!item.enabled)
                }
            } else {
                Divider()
            }
        }
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
            Section("글꼴") {
                Picker("언어", selection: $language) {
                    Text("대표").tag(Int?.none)
                    ForEach(CharShapeSheet.languageNames.indices, id: \.self) { Text(CharShapeSheet.languageNames[$0]).tag(Int?.some($0)) }
                }
                LabeledContent("글꼴") {
                    Menu(font ?? "") {
                        ForEach(FormatChoices.families, id: \.family) { family in
                            Button(family.name) { editor.format(CharStyle(language: language, font: family.family)) }
                        }
                    }
                    .fixedSize()
                }
                LabeledContent("크기") {
                    NumberStepper(value: text?.size, unit: "pt", range: 1...4096) { editor.format(CharStyle(size: $0)) }
                }
            }
            Section {
                LabeledContent("모양") {
                    ControlGroup {
                        flag("진하게", "bold", text?.bold) { editor.toggleBold() }
                        flag("기울임", "italic", text?.italic) { editor.toggleItalic() }
                        flag("밑줄", "underline", text?.underline) { editor.toggleUnderline() }
                        flag("취소선", "strikethrough", text?.strikethrough) { editor.toggleStrikethrough() }
                    }
                    .fixedSize()
                }
                ColorPicker("글자 색", selection: color(text?.color ?? "#000000") { editor.format(CharStyle(color: $0)) }, supportsOpacity: false)
                ColorPicker("형광펜", selection: color(text?.shade ?? FormatChoices.none) { editor.format(CharStyle(shade: $0)) },
                            supportsOpacity: false)
            } footer: {
                DialogButtons { Button("글자 모양…") { viewer.editingCharShape = true } }
            }
        }
        .disabled(!document.context.canFormat)
    }

    private func flag(_ title: String, _ symbol: String, _ on: Bool?, toggle: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on == true }, set: { _ in toggle() })) { Image(systemName: symbol) }
            .toggleStyle(.button)
            .help(title)
            .accessibilityLabel(title)
    }
    private func color(_ hex: String, set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { HexColor.color(hex) }, set: { set(HexColor.hex($0)) })
    }
}

/// 문단: alignment, line spacing and lists, and 문단 모양 for the rest.
private struct ParagraphTab: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer

    var body: some View {
        let editor = viewer.canvas.editor, paragraph = document.format?.paragraph
        Group {
            Section("정렬") {
                Picker("정렬", selection: Binding(get: { paragraph?.alignment }, set: { if let alignment = $0 { editor.format(ParaStyle(alignment: alignment)) } })) {
                    ForEach(Alignment.allCases, id: \.self) { alignment in
                        let label = FormatChoices.label(alignment)
                        Image(systemName: label.symbol).help(label.title).accessibilityLabel(label.title).tag(Alignment?.some(alignment))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LabeledContent("줄 간격") {
                    NumberStepper(value: paragraph?.lineSpacing, unit: paragraph?.lineSpacingKind == .percent || paragraph == nil ? "%" : "pt",
                                  range: 50...500, step: 10) {
                        editor.format(ParaStyle(lineSpacing: $0, lineSpacingKind: .percent))
                    }
                }
            }
            Section {
                let head = paragraph?.head ?? "None"
                Picker("", selection: Binding(get: { ["Bullet", "Number"].contains(head) ? head : "None" }, set: { kind in
                    editor.format(kind == "Bullet" ? ParaStyle(head: kind, bullet: FormatChoices.bullets[0])
                                  : kind == "Number" ? ParaStyle(head: kind, numbering: 0) : ParaStyle(head: "None"))
                })) {
                    Text("없음").tag("None")
                    Text("글머리표").tag("Bullet")
                    Text("문단 번호").tag("Number")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if head == "Bullet" {
                    LabeledContent("글머리표 모양") {
                        Menu(paragraph?.bullet ?? "") {
                            ForEach(FormatChoices.bullets, id: \.self) { bullet in
                                Button(bullet) { editor.format(ParaStyle(head: "Bullet", bullet: bullet)) }
                            }
                        }
                        .fixedSize()
                    }
                } else if head == "Number" {
                    LabeledContent("문단 번호 모양") {
                        Menu(paragraph?.numbering.map { FormatChoices.numberings[$0][0] } ?? "") {
                            ForEach(FormatChoices.numberings.indices, id: \.self) { kind in
                                Button(FormatChoices.numberings[kind].joined(separator: " ")) {
                                    editor.format(ParaStyle(head: "Number", numbering: kind))
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
                if head != "None" {
                    LabeledContent("수준") {
                        Stepper("\((paragraph?.level ?? 0) + 1)", onIncrement: { editor.stepLevel(by: 1) }, onDecrement: { editor.stepLevel(by: -1) })
                    }
                }
            } header: {
                Text("글머리표 및 문단 번호")
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
