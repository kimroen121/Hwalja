import AppKit
import SwiftUI

/// 텍스트, as Keynote's: the paragraph's 스타일 over 스타일 (font, character styles, colors,
/// alignment, spacing and lists) and 레이아웃 (margins, first line, line breaking, 테두리 and
/// 배경). All of 글자 모양 and 문단 모양 is here, each change applied at once.
struct TextTab: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    /// 스타일 (0), 레이아웃 (1) or 기타 (2).
    @State private var layout: Int
    /// The 언어 the font and scales show and change; nil for 대표 (all of them).
    @State private var language: Int?
    @State private var showsMore = false
    @State private var showsStyles = false
    /// The caret's style as it is defined, to tell the caret's shapes from it.
    @State private var defined: (style: UInt32, format: Format)?
    /// The revision `defined` was read at; an edit (업데이트 among them) reads it again.
    @State private var shownRevision: UInt64 = 0

    /// Shows 텍스트 over the style, when no tabs do.
    let title: Bool

    init(document: HwpDocument, viewer: Viewer, title: Bool) {
        (self.document, self.viewer, self.title, _layout) = (document, viewer, title, State(initialValue: viewer.textLayout))
    }

    private var editor: PageEditor { viewer.canvas.editor }
    private var text: CharStyle? { document.format?.text }
    private var paragraph: ParaStyle? { document.format?.paragraph }

    /// The title, the style and 스타일/레이아웃 stay; the groups under them scroll.
    var body: some View {
        VStack(spacing: 0) {
            InspectorScroll(fixed: true) {
                InspectorSection {
                    if title {
                        VStack(spacing: 4) {
                            Text("텍스트").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            Divider()
                        }
                    }
                    // As Pages's: the style's name, its list in a popover under it; with * and
                    // 업데이트 while the text's shapes are not the style's.
                    let style = document.styles.first { $0.id == document.format?.style }
                    let changed = style.map { Self.changed(document.format, from: defined?.style == $0.id ? defined?.format : nil) } ?? false
                    let update = Button("업데이트") { style.map { viewer.restyleFromCaret($0.id) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("스타일을 커서 위치의 모양으로 바꾸기")
                    Button { showsStyles = true } label: {
                        HStack {
                            Text((style?.name ?? "") + (changed ? "*" : ""))
                            Spacer()
                            Image(systemName: "chevron.down").font(.body.weight(.semibold))
                            // Room for 업데이트, which lies over the button.
                            if changed { update.fixedSize().hidden().frame(height: 0) }
                        }
                    }
                    .controlSize(.extraLarge)
                    .popover(isPresented: $showsStyles, arrowEdge: .bottom) {
                        StylePane(document: document, viewer: viewer) { showsStyles = false }
                    }
                    .flexibleButtons()
                    .overlay(alignment: .trailing) { if changed { update.padding(.trailing, 12) } }
                    .disabled(!document.context.canApplyStyle)
                    Divider()
                    Segments([0, 1, 2], selection: $layout, accent: true) { let title = ["스타일", "레이아웃", "기타"][$0]; return .init(title: title, help: title) }
                }
            }
            InspectorScroll {
                Group { switch layout { case 1: layoutPane; case 2: otherPane; default: stylePane } }
                    .disabled(!document.context.canFormat)
            }
        }
        .onChange(of: layout) { viewer.textLayout = layout }
        // The revision is not published: 업데이트 changes the style alone.
        .onReceive(document.presented) { if document.revision != shownRevision { shownRevision = document.revision } }
        .task(id: "\(shownRevision) \(document.format?.style ?? 0)") {
            guard let style = document.format?.style, let format = try? await document.styleFormat(style) else { return }
            defined = (style, format)
        }
        // 스타일… shows the styles.
        .onAppear {
            guard viewer.opensStyles else { return }
            viewer.opensStyles = false
            Task { showsStyles = true }
        }
    }
    /// The text's shapes are not its style's: Pages's * and 업데이트. 시작 번호 방식 is the
    /// paragraph's own, never a style's.
    static func changed(_ format: Format?, from style: Format?) -> Bool {
        guard let format, let style else { return false }
        var paragraph = format.paragraph
        (paragraph.restart, paragraph.startNumber) = (style.paragraph.restart, style.paragraph.startNumber)
        return format.text != style.text || format.languages != style.languages || paragraph != style.paragraph
    }

    // MARK: 스타일

    @ViewBuilder private var stylePane: some View {
        let languages = document.format?.languages ?? []
        let font = language.flatMap { languages.indices.contains($0) ? languages[$0].font : nil } ?? text?.font
        InspectorSection("글꼴") {
            FontPicker(font: font, language: language) { editor.format(CharStyle(language: language, font: $0)) }
                .equatable()
                .flexibleButtons()
            HStack(spacing: 8) {
                Picker("언어", selection: $language) {
                    Text("대표").tag(Int?.none)
                    ForEach(FormatChoices.languageNames.indices, id: \.self) { Text(FormatChoices.languageNames[$0]).tag(Int?.some($0)) }
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
                Button { showsMore = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape")
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                }
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
            // A list paragraph a 수준 up or down; another, its 왼쪽 여백 by 10 pt.
            let indent = { (step: Int) in
                if (paragraph?.head ?? "None") != "None" {
                    editor.stepLevel(by: step)
                } else if let margin = paragraph?.marginLeft {
                    editor.format(ParaStyle(marginLeft: max(0, margin + Double(step) * 10)))
                }
            }
            Segments(segments: [.init(symbol: "decrease.indent", help: "왼쪽 여백 줄이기"), .init(symbol: "increase.indent", help: "왼쪽 여백 키우기")],
                     on: [false, false], any: true) { indent($0 == 0 ? -1 : 1) }
        }
        InspectorSection {
            DisclosureGroup {
                VStack(spacing: 10) {
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
                }
            } label: {
                LabeledContent {
                    let percent = (paragraph?.lineSpacingKind ?? .percent) == .percent
                    NumberStepper(value: paragraph?.lineSpacing, unit: percent ? "%" : "pt", range: percent ? 50...500 : 0...1000,
                                  step: percent ? 10 : 1) { value in
                        editor.format(ParaStyle(lineSpacing: value, lineSpacingKind: paragraph?.lineSpacingKind ?? .percent))
                    }
                } label: { Text("간격").font(.headline.weight(.medium)) }
            }
        }
        InspectorSection { lists }
    }

    /// 글머리표 및 문단 번호: the kind beside the title, its shapes, 수준 and 시작 번호 방식 under it.
    @ViewBuilder private var lists: some View {
        let head = paragraph?.head ?? "None"
        // Nothing to open with no list.
        if !["Bullet", "Number"].contains(head) {
            listsTitle(head)
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    if head == "Bullet" {
                        Picker("글머리표", selection: Binding(get: { paragraph?.bullet }, set: { bullet in
                            if let bullet { editor.format(ParaStyle(head: "Bullet", bullet: bullet)) }
                        })) {
                            if paragraph?.bullet.map(FormatChoices.bullets.contains) != true { Text("").tag(String?.none) }
                            ForEach(FormatChoices.bullets, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .labelsHidden()
                        .flexibleButtons()
                    } else if head == "Number" {
                        Picker("문단 번호", selection: Binding(get: { paragraph?.numbering }, set: { kind in
                            if let kind { editor.format(ParaStyle(head: "Number", numbering: kind)) }
                        })) {
                            if paragraph?.numbering == nil { Text("").tag(Int?.none) }
                            ForEach(FormatChoices.numberings.indices, id: \.self) {
                                Text(FormatChoices.numberings[$0].prefix(3).joined(separator: " ")).tag(Int?.some($0))
                            }
                        }
                        .labelsHidden()
                        .flexibleButtons()
                    }
                    if head == "Number", document.context.inBody, let numbering = paragraph?.numbering {
                        restart(numbering)
                    }
                }
            } label: { listsTitle(head) }
        }
    }

    /// 시작 번호 방식: 직전에서 계속 (the list just before), 이전에서 계속 (the one before that),
    /// 처음부터 시작 (from 1), 다음에서 시작 (from the number given).
    /// The engine reads the way back from where the paragraph's list starts, and its
    /// "앞 번호 목록에 이어" keeps the list as it is; its "이전 번호 목록에 이어" joins the
    /// nearest list before that is not the paragraph's own. So both ways go through that one:
    /// once to the list just before, again to the one before it.
    private func restart(_ numbering: Int) -> some View {
        let restart = paragraph?.restart ?? 0, start = paragraph?.startNumber ?? 1
        let way = restart < 2 ? restart : start == 1 ? 2 : 3
        return HStack(alignment: .lastTextBaseline) {
            Picker("시작 번호 방식", selection: Binding(get: { way }, set: { chosen in
                guard chosen != way else { return }
                let join = ParaStyle(head: "Number", numbering: numbering, restart: 1)
                switch chosen {
                case 0: editor.format(join)
                case 1:
                    if way != 0 { editor.format(join) }
                    editor.format(join)
                default:
                    editor.format(ParaStyle(head: "Number", numbering: numbering, restart: 2, startNumber: chosen == 2 ? 1 : max(start, 2)))
                }
            })) {
                Text("직전에서 계속").tag(0)
                Text("이전에서 계속").tag(1)
                Text("처음부터 시작").tag(2)
                Text("다음에서 시작").tag(3)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .labeledContentStyle(.automatic)
            NumberStepper(value: Double(start), unit: "", range: 1...65535) { start in
                editor.format(ParaStyle(head: "Number", numbering: numbering, restart: 2, startNumber: Int(start)))
            }
            .controlSize(.small)
            .disabled(way != 3)
        }
    }

    private func listsTitle(_ head: String) -> some View {
        LabeledContent {
            let shown = ["Bullet", "Number"].contains(head) ? head : "None"
            Picker("글머리표 및 문단 번호", selection: Binding(get: { shown }, set: { kind in
                // The same kind again keeps the paragraph's shape and numbering.
                guard kind != shown else { return }
                editor.format(kind == "Bullet" ? ParaStyle(head: kind, bullet: FormatChoices.bullets[0])
                              : kind == "Number" ? ParaStyle(head: kind, numbering: 0) : ParaStyle(head: "None"))
            })) {
                Text("없음").tag("None")
                Text("글머리표").tag("Bullet")
                Text("문단 번호").tag("Number")
            }
            .labelsHidden()
            .fixedSize()
        } label: { Text("글머리표 및 문단 번호").font(.headline.weight(.medium)) }
    }

    /// The rest of 글자 모양: scales of the 언어, 첨자, the attributes, 밑줄, 취소선, 테두리 and 배경.
    private var more: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("추가 텍스트 옵션").font(.headline.weight(.medium)).frame(maxWidth: .infinity)
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
                OpeningRows(title: "밑줄", open: text?.underline == true) {
                    Picker("밑줄", selection: Binding(get: { text?.underline != true ? 0 : text?.underlineTop == true ? 2 : 1 }, set: { place in
                        editor.format(place == 0 ? CharStyle(underline: false) : CharStyle(underline: true, underlineTop: place == 2))
                    })) { Text("없음").tag(0); Text("아래").tag(1); Text("위").tag(2) }
                    .labelsHidden()
                    .fixedSize()
                } rows: {
                    LabeledContent("모양") { ChoiceField(char(\.underlineShape, 0), LineShapes.names.indices.map { ($0, LineShapes.names[$0]) }, images: LineShapes.images) }
                    LabeledContent("색") { ColorWell(hex: char(\.underlineColor, "#000000")) }
                }
                OpeningRows(title: "취소선", open: text?.strikethrough == true) {
                    ChoiceField(Binding(get: { text?.strikethrough == true ? (text?.strikeShape ?? 0) + 1 : 0 }, set: { kind in
                        editor.format(kind == 0 ? CharStyle(strikethrough: false) : CharStyle(strikethrough: true, strikeShape: kind - 1))
                    }), Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds)
                } rows: {
                    LabeledContent("색") { ColorWell(hex: char(\.strikeColor, "#000000")) }
                }
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
        InspectorSection {
            Fold("여백") { Pair("왼쪽", length(\.marginLeft), "오른쪽", length(\.marginRight)) }
        }
        // 들여쓰기 (positive) and 내어쓰기 (negative) are one value of the paragraph.
        InspectorSection {
            Fold("들여쓰기") {
                let indent = paragraph?.indent ?? 0
                Pair("들여쓰기", NumberStepper(value: paragraph.map { max($0.indent ?? 0, 0) }, unit: "pt", range: 0...1000) { amount in
                         if amount > 0 || indent > 0 { editor.format(ParaStyle(indent: amount)) }
                     },
                     "내어쓰기", NumberStepper(value: paragraph.map { max(-($0.indent ?? 0), 0) }, unit: "pt", range: 0...1000) { amount in
                         if amount > 0 || indent < 0 { editor.format(ParaStyle(indent: -amount)) }
                     })
            }
        }
        InspectorSection {
            BorderFillRows(style: paragraphBorderFill, fill: false)
            Toggle("문단 테두리 연결", isOn: para(\.borderConnect, false)).checkbox()
        }
        InspectorSection { BorderFillRows(style: paragraphBorderFill, border: false) }
    }

    // MARK: 기타

    @ViewBuilder private var otherPane: some View {
        InspectorSection("줄 나눔 기준") {
            LabeledContent("한글 단위") {
                Picker("한글 단위", selection: para(\.koreanBreakUnit, 1)) { Text("글자").tag(1); Text("어절").tag(0) }.labelsHidden().fixedSize()
            }
            LabeledContent("영어 단위") {
                Picker("영어 단위", selection: para(\.englishBreakUnit, 0)) { Text("단어").tag(0); Text("하이픈").tag(1); Text("글자").tag(2) }
                    .labelsHidden().fixedSize()
            }
        }
    }

    private var paragraphBorderFill: Binding<ParaStyle> {
        Binding(get: { paragraph ?? ParaStyle() }, set: { new in
            if let old = paragraph { editor.format(new.changesWithBorderFill(from: old)) }
        })
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
    var border = true, fill = true
    var body: some View {
        if border { borderRows }
        if border && fill { Divider() }
        if fill { fillRows }
    }
    /// 테두리, then its kind, color and width in one row.
    private var borderRows: some View {
        let on = (style.borderLine ?? 0) != 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("테두리").fontWeight(on ? .medium : .regular)
            HStack(spacing: 8) {
                LineKindField(kind: int(\.borderLine))
                Group {
                    ColorWell(hex: text(\.borderColor, "#000000"))
                    LineRow.width(style.borderWidth ?? 0) { style.borderWidth = $0 }
                }
                .disabled(!on)
            }
        }
    }
    @ViewBuilder private var fillRows: some View {
        LabeledContent("배경") { ColorWell(hex: text(\.fillColor, "none"), none: "none") }
        LabeledContent("무늬") {
            HStack(spacing: 8) {
                ChoiceField(int(\.pattern), Swatches.patterns.indices.map { ($0, "") }, images: Swatches.patterns)
                ColorWell(hex: text(\.patternColor, "#000000"))
            }
        }
    }
    private func int(_ key: WritableKeyPath<Style, Int?>) -> Binding<Int> {
        Binding { style[keyPath: key] ?? 0 } set: { style[keyPath: key] = $0 }
    }
    private func text(_ key: WritableKeyPath<Style, String?>, _ fallback: String) -> Binding<String> {
        Binding { style[keyPath: key] ?? fallback } set: { style[keyPath: key] = $0 }
    }
}

/// The 퀵 메뉴 over selected text, as Freeform's: 글자 색, 글자 모양 and 크기 in a small bar;
/// 글자 모양 opens the rest above it.
struct QuickMenu: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @State private var showsMore = false
    @State private var showsStyles = false

    private var editor: PageEditor { viewer.canvas.editor }
    private var text: CharStyle? { document.format?.text }
    private var paragraph: ParaStyle? { document.format?.paragraph }

    var body: some View {
        let bar = HStack(spacing: 8) {
            ColorWell(hex: Binding(get: { text?.color ?? "#000000" }, set: { editor.format(CharStyle(color: $0)) }), circle: true)
                .pointing()
            .help("글자 색")
            Button { showsMore = true } label: { Image(systemName: "textformat.ko") }
                .buttonStyle(.borderless)
                .pointing()
                .help("글자 모양")
                .popover(isPresented: $showsMore, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { more }
            Menu {
                ForEach(FormatChoices.sizes, id: \.self) { size in
                    Toggle(FormatChoices.points(size), isOn: Binding(get: { text?.size == size }, set: { _ in editor.format(CharStyle(size: size)) }))
                }
            } label: {
                Text(text?.size.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "")
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointing()
            .help("기준 크기")
        }
        // The bar never takes the keyboard: the selection stays the editor's, for ⌘C and ⌘V.
        .focusable(false)
        .focusEffectDisabled()
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .disabled(!document.context.canFormat)
        Group {
            if #available(macOS 26, *) {
                bar.glassEffect(in: .capsule)
            } else {
                bar.background(.regularMaterial, in: Capsule())
            }
        }
        .padding(4)
    }

    /// 진하게, 기울임, 밑줄 and 문단 스타일 over 정렬, 줄 간격 and 글머리표, and the 글꼴.
    private var more: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                let styles: [(title: String, symbol: String, on: Bool?, toggle: () -> Void)] = [
                    ("진하게", "bold", text?.bold, editor.toggleBold), ("기울임", "italic", text?.italic, editor.toggleItalic),
                    ("밑줄", "underline", text?.underline, editor.toggleUnderline),
                ]
                Segments(segments: styles.map { .init(symbol: $0.symbol, help: $0.title) }, on: styles.map { $0.on == true }, any: true) {
                    styles[$0].toggle()
                }
                .gridCellColumns(2)
                Button { showsStyles = true } label: { Text("가가").frame(maxWidth: .infinity) }
                    .help("문단 스타일")
                    .popover(isPresented: $showsStyles, arrowEdge: .bottom) {
                        StylePane(document: document, viewer: viewer) { showsStyles = false }
                    }
            }
            GridRow {
                Menu {
                    ForEach(Alignment.allCases, id: \.self) { alignment in
                        let label = FormatChoices.label(alignment)
                        Toggle(isOn: Binding(get: { paragraph?.alignment == alignment },
                                             set: { _ in editor.format(ParaStyle(alignment: alignment)) })) {
                            Label(label.title, systemImage: label.symbol)
                        }
                    }
                } label: { Image(systemName: FormatChoices.label(paragraph?.alignment ?? .justify).symbol) }
                    .help("정렬")
                Menu {
                    ForEach(FormatChoices.lineSpacings, id: \.self) { spacing in
                        Toggle("\(Int(spacing))%", isOn: Binding(get: { paragraph?.lineSpacingKind == .percent && paragraph?.lineSpacing == spacing },
                                                                 set: { _ in editor.format(ParaStyle(lineSpacing: spacing, lineSpacingKind: .percent)) }))
                    }
                } label: { Image(systemName: "arrow.up.and.down.text.horizontal") }
                    .help("줄 간격")
                Menu {
                    let head = paragraph?.head ?? "None"
                    ForEach([("None", "없음"), ("Bullet", "글머리표"), ("Number", "문단 번호")], id: \.0) { kind, title in
                        Toggle(title, isOn: Binding(get: { head == kind }, set: { _ in
                            guard kind != head else { return }
                            editor.format(kind == "Bullet" ? ParaStyle(head: kind, bullet: FormatChoices.bullets[0])
                                          : kind == "Number" ? ParaStyle(head: kind, numbering: 0) : ParaStyle(head: "None"))
                        }))
                    }
                } label: { Image(systemName: "list.bullet") }
                    .help("글머리표 및 문단 번호")
            }
            .menuIndicator(.hidden)
            GridRow {
                FontPicker(font: text?.font, language: nil) { editor.format(CharStyle(font: $0)) }
                    .equatable()
                    .gridCellColumns(3)
            }
        }
        .flexibleButtons()
        .buttonBorderShape(.roundedRectangle)
        .frame(width: 240)
        .padding(8)
        .disabled(!document.context.canFormat)
    }
}
