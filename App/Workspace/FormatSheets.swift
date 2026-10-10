import AppKit
import SwiftUI

// 글자 모양 and 문단 모양.

extension Viewer {
    func applyCharShape(_ change: CharStyle) {
        guard change != CharStyle() else { return }
        canvas.editor.model?.formatText(change, canvas.editor.undoManager)
    }
    func applyParaShape(_ change: ParaStyle) {
        guard change != ParaStyle() else { return }
        canvas.editor.model?.formatParagraphs(change, canvas.editor.undoManager)
    }
}

/// Line shapes for underline and strikethrough, in Hancom's order and numbering.
enum LineShapes {
    static let names = ["실선", "파선", "점선", "일점쇄선", "이점쇄선", "긴 파선", "원형 점선", "이중 실선",
                        "얇고 굵은 이중선", "굵고 얇은 이중선", "얇고 굵고 얇은 삼중선", "물결선", "이중 물결선"]

    /// A sample of each shape, as the web editor's menus show them.
    static let images: [NSImage] = names.indices.map { shape in
        let image = NSImage(size: NSSize(width: 64, height: 10), flipped: true) { rect in
            NSColor.labelColor.set()
            func line(_ y: CGFloat, _ width: CGFloat, dash: [CGFloat] = [], round: Bool = false) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 1, y: y))
                path.line(to: NSPoint(x: rect.maxX - 1, y: y))
                path.lineWidth = width
                if round { path.lineCapStyle = .round }
                if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
                path.stroke()
            }
            func wave(_ y: CGFloat) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 1, y: y))
                for x in stride(from: CGFloat(1), to: rect.maxX - 1, by: 6) {
                    path.curve(to: NSPoint(x: x + 6, y: y), controlPoint1: NSPoint(x: x + 2, y: y - 3),
                               controlPoint2: NSPoint(x: x + 4, y: y + 3))
                }
                path.lineWidth = 1
                path.stroke()
            }
            switch shape {
            case 1: line(5, 1.5, dash: [5, 3])
            case 2: line(5, 1.5, dash: [1.5, 2])
            case 3: line(5, 1.5, dash: [7, 2, 1.5, 2])
            case 4: line(5, 1.5, dash: [7, 2, 1.5, 2, 1.5, 2])
            case 5: line(5, 1.5, dash: [12, 5])
            case 6: line(5, 2.5, dash: [0, 5], round: true)
            case 7: line(3.5, 1); line(6.5, 1)
            case 8: line(3, 0.75); line(6.5, 2)
            case 9: line(3.5, 2); line(7, 0.75)
            case 10: line(1.5, 0.75); line(5, 2); line(8.5, 0.75)
            case 11: wave(5)
            case 12: wave(3); wave(7)
            default: line(5, 1.5)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Formats with 테두리 and 배경, which the engine takes all together.
protocol BorderFillStyle: PartialFormat {
    var borderLine: Int? { get set }
    var borderWidth: Int? { get set }
    var borderColor: String? { get set }
    var fillColor: String? { get set }
    var patternColor: String? { get set }
    var pattern: Int? { get set }
}
extension CharStyle: BorderFillStyle {}
extension ParaStyle: BorderFillStyle {}

extension BorderFillStyle {
    /// The changes from `old`, with all of 테두리 and 배경 when any of them changed.
    func changesWithBorderFill(from old: Self) -> Self {
        var change = changes(from: old)
        let keys: [WritableKeyPath<Self, Int?>] = [\.borderLine, \.borderWidth, \.pattern]
        let colors: [WritableKeyPath<Self, String?>] = [\.borderColor, \.fillColor, \.patternColor]
        guard keys.contains(where: { change[keyPath: $0] != nil }) || colors.contains(where: { change[keyPath: $0] != nil })
        else { return change }
        change.borderLine = borderLine ?? 0
        change.borderWidth = borderWidth ?? 0
        change.borderColor = borderColor ?? "#000000"
        change.fillColor = fillColor ?? "none"
        change.patternColor = patternColor ?? "#000000"
        change.pattern = pattern ?? 0
        return change
    }
}

/// 테두리 and 배경 side by side, as the web 글자 모양 확장 and 문단 모양 테두리/배경 tabs.
struct BorderFillGroups<Style: BorderFillStyle, Extra: View>: View {
    @Binding var style: Style
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                GroupTitle("테두리")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        FieldLabel("종류")
                        ChoiceField(int(\.borderLine), Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds, minWidth: 100)
                    }
                    GridRow {
                        FieldLabel("굵기")
                        ChoiceField(int(\.borderWidth), Swatches.widths.indices.map { ($0, "") }, images: Swatches.widthImages, minWidth: 100)
                    }
                    GridRow {
                        FieldLabel("색")
                        ColorWell(hex: text(\.borderColor, "#000000"))
                    }
                }
                .padding(.leading, 12)
                extra.padding(.leading, 12)
            }
            VStack(alignment: .leading, spacing: 8) {
                GroupTitle("배경")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        FieldLabel("면 색")
                        ColorWell(hex: text(\.fillColor, "none"), none: "none")
                    }
                    GridRow {
                        FieldLabel("무늬 색")
                        ColorWell(hex: text(\.patternColor, "#000000"))
                    }
                    GridRow {
                        FieldLabel("무늬 모양")
                        ChoiceField(int(\.pattern), Swatches.patterns.indices.map { ($0, "") }, images: Swatches.patterns, minWidth: 100)
                    }
                }
                .padding(.leading, 12)
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

/// 글자 모양, laid out like the web editor's: 기본 (size, per-language settings,
/// attributes, colors) and 확장 (밑줄, 취소선, 테두리, 배경). Only changed attributes apply.
struct CharShapeSheet: View {
    let original: CharStyle
    /// Each 언어's own font and scales, as they were.
    let languages: [CharStyle]
    let viewer: Viewer
    /// Where the changes go: the selection, or a style being edited.
    var apply: ((CharStyle) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var style: CharStyle
    @State private var edited: [CharStyle]
    /// The 언어 the font and scales show: nil for 대표, else an index into `languages`.
    @State private var language: Int?
    @State private var tab: String

    /// 언어별 설정's choices, in the web editor's order.
    static let languageNames = ["한글", "영문", "한자", "일어", "외국어", "기호", "사용자"]

    init(style: CharStyle, languages: [CharStyle], viewer: Viewer, tab: String = "기본",
         apply: ((CharStyle) -> Void)? = nil) {
        original = style
        self.apply = apply
        self.languages = languages
        _tab = State(initialValue: tab)
        self.viewer = viewer
        _style = State(initialValue: style)
        _edited = State(initialValue: languages)
    }

    var body: some View {
        DialogFrame("글자 모양", confirmTitle: "설정") {
            DialogTabs(selection: $tab, titles: ["기본", "확장"]) { tab in
                Group { if tab == "확장" { extended } else { basic } }.padding(16)
            }
            .frame(width: 520, height: 330)
        } confirm: {
            let send = apply ?? viewer.applyCharShape
            send(style.changesWithBorderFill(from: original))
            // Then each 언어 set apart from 대표.
            for (index, (now, was)) in zip(edited, languages).enumerated() {
                var change = now.changes(from: was)
                guard change != CharStyle() else { continue }
                change.language = index
                send(change)
            }
            dismiss()
        }
    }

    private var basic: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField("기준 크기") { SpinField(value: value(\.size, 10), unit: "pt", range: 1...4096) }
            GroupTitle("언어별 설정")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("언어")
                    ChoiceField(Binding { language ?? -1 } set: { language = $0 < 0 ? nil : $0 },
                                [(-1, "대표")] + Self.languageNames.enumerated().map { ($0.offset, $0.element) }, minWidth: 90)
                    FieldLabel("글꼴")
                    ChoiceField(lingual(\.font, ""), fonts, minWidth: 110)
                }
                GridRow {
                    FieldLabel("상대 크기")
                    SpinField(value: lingual(\.relativeSize, 100), unit: "%", range: 10...250)
                    FieldLabel("장평")
                    SpinField(value: lingual(\.ratio, 100), unit: "%", range: 50...200)
                }
                GridRow {
                    FieldLabel("글자 위치")
                    SpinField(value: lingual(\.offset, 0), unit: "%", range: -100...100)
                    FieldLabel("자간")
                    SpinField(value: lingual(\.spacing, 0), unit: "%", range: -50...50)
                }
            }
            .padding(.leading, 12)
            GroupTitle("속성")
            HStack(spacing: 6) {
                attribute("진하게", \.bold) { Text("가").bold() }
                attribute("기울임", \.italic) { Text("가").italic() }
                attribute("밑줄", \.underline) { Text("가").underline() }
                attribute("취소선", \.strikethrough) { Text("가").strikethrough() }
                attribute("외곽선", \.outline) {
                    Text("가").foregroundStyle(.background)
                        .shadow(color: .primary, radius: 0, x: 0.7).shadow(color: .primary, radius: 0, x: -0.7)
                        .shadow(color: .primary, radius: 0, y: 0.7).shadow(color: .primary, radius: 0, y: -0.7)
                }
                attribute("그림자", \.shadow) { Text("가").shadow(color: .secondary, radius: 0, x: 1.5, y: 1.5) }
                attribute("양각", \.emboss) { Text("가").foregroundStyle(.background).shadow(color: .primary, radius: 0, x: 1, y: 1) }
                attribute("음각", \.engrave) { Text("가").foregroundStyle(.background).shadow(color: .primary, radius: 0, x: -1, y: -1) }
                Spacer().frame(width: 8)
                attribute("위 첨자", \.superscript) { Image(systemName: "textformat.superscript") }
                attribute("아래 첨자", \.`subscript`) { Image(systemName: "textformat.subscript") }
            }
            .padding(.leading, 12)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("글자 색")
                    ColorWell(hex: value(\.color, "#000000"))
                    Spacer().frame(width: 24)
                    FieldLabel("음영 색")
                    ColorWell(hex: value(\.shade, "#ffffff"), none: "#ffffff", noneTitle: "음영 없음")
                }
            }
            .padding(.leading, 12)
            Spacer(minLength: 0)
        }
    }

    private var extended: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("밑줄")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("위치")
                            ChoiceField(underlinePlace, [(0, "없음"), (1, "아래"), (2, "위")], minWidth: 100)
                        }
                        Group {
                            GridRow {
                                FieldLabel("모양")
                                ChoiceField(value(\.underlineShape, 0), LineShapes.names.indices.map { ($0, "") },
                                            images: LineShapes.images, minWidth: 100)
                            }
                            GridRow {
                                FieldLabel("색")
                                ColorWell(hex: value(\.underlineColor, "#000000"))
                            }
                        }
                        .disabled(style.underline != true)
                    }
                    .padding(.leading, 12)
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("취소선")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("모양")
                            ChoiceField(strikeShape, Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds, minWidth: 100)
                        }
                        GridRow {
                            FieldLabel("색")
                            ColorWell(hex: value(\.strikeColor, "#000000"))
                        }
                        .disabled(style.strikethrough != true)
                    }
                    .padding(.leading, 12)
                }
            }
            BorderFillGroups(style: $style) { EmptyView() }
            Spacer(minLength: 0)
        }
    }

    /// 밑줄 위치: 없음 (0), 아래 (1) or 위 (2).
    private var underlinePlace: Binding<Int> {
        Binding { style.underline != true ? 0 : style.underlineTop == true ? 2 : 1 } set: { place in
            style.underline = place != 0
            if place != 0 { style.underlineTop = place == 2 }
        }
    }
    /// 취소선 모양: none (0) or a line shape (n + 1).
    private var strikeShape: Binding<Int> {
        Binding { style.strikethrough == true ? (style.strikeShape ?? 0) + 1 : 0 } set: { kind in
            style.strikethrough = kind != 0
            if kind != 0 { style.strikeShape = kind - 1 }
        }
    }
    private func value<T>(_ key: WritableKeyPath<CharStyle, T?>, _ fallback: T) -> Binding<T> {
        Binding { style[keyPath: key] ?? fallback } set: { style[keyPath: key] = $0 }
    }
    /// A value of the chosen 언어, or of 대표.
    private func lingual<T>(_ key: WritableKeyPath<CharStyle, T?>, _ fallback: T) -> Binding<T> {
        guard let language, edited.indices.contains(language) else { return value(key, fallback) }
        return Binding { edited[language][keyPath: key] ?? fallback } set: { edited[language][keyPath: key] = $0 }
    }
    /// Installed families, and the document's font when it isn't installed.
    private var fonts: [(value: String, title: String)] {
        let installed = FormatChoices.families.map { ($0.family, $0.name) }
        guard let font = original.font, !installed.contains(where: { $0.0 == font }) else { return installed }
        return installed + [(font, font)]
    }
    private func attribute(_ title: String, _ key: WritableKeyPath<CharStyle, Bool?>,
                           @ViewBuilder glyph: () -> some View) -> some View {
        let on = style[keyPath: key] == true
        return Button {
            style[keyPath: key] = !on
            // One of 위 첨자 and 아래 첨자 at a time.
            if !on, key == \.superscript { style.`subscript` = false }
            if !on, key == \.`subscript` { style.superscript = false }
        } label: {
            glyph().font(.system(size: 15)).frame(width: 32, height: 32)
        }
        .choice(on)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 문단 모양, laid out like the web editor's: 기본 (alignment, margins, first line,
/// spacing, line breaking) and 테두리/배경. Only changed attributes apply.
struct ParaShapeSheet: View {
    let original: ParaStyle
    let viewer: Viewer
    /// Where the change goes: the selection, or a style being edited.
    var apply: ((ParaStyle) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var style: ParaStyle
    @State private var tab: String

    init(style: ParaStyle, viewer: Viewer, tab: String = "기본", apply: ((ParaStyle) -> Void)? = nil) {
        original = style
        self.apply = apply
        _tab = State(initialValue: tab)
        self.viewer = viewer
        _style = State(initialValue: style)
    }

    private enum FirstLine: Hashable { case normal, indent, hang }

    var body: some View {
        DialogFrame("문단 모양", confirmTitle: "설정") {
            DialogTabs(selection: $tab, titles: ["기본", "테두리/배경"]) { tab in
                Group {
                    if tab == "기본" {
                        basic
                    } else {
                        BorderFillGroups(style: $style) {
                            Toggle("문단 테두리 연결", isOn: Binding { style.borderConnect ?? false } set: { style.borderConnect = $0 })
                        }
                    }
                }
                .padding(16)
            }
            .frame(width: 520, height: 400)
        } confirm: {
            var change = style.changesWithBorderFill(from: original)
            // The engine reads a line spacing by its kind, so they go together.
            if change.lineSpacing != nil || change.lineSpacingKind != nil {
                (change.lineSpacing, change.lineSpacingKind) = (style.lineSpacing, style.lineSpacingKind)
            }
            (apply ?? viewer.applyParaShape)(change)
            dismiss()
        }
    }

    private var basic: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupTitle("정렬 방식")
            HStack(spacing: 6) {
                ForEach(Alignment.allCases, id: \.self) { alignment in
                    let label = FormatChoices.label(alignment)
                    Button { style.alignment = alignment } label: {
                        Image(systemName: label.symbol).font(.system(size: 15, weight: .light)).frame(width: 32, height: 32)
                    }
                    .choice((style.alignment ?? .justify) == alignment)
                    .help(label.title)
                }
            }
            .padding(.leading, 12)
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("여백")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow { FieldLabel("왼쪽"); SpinField(value: length(\.marginLeft), unit: "pt", range: 0...1000) }
                        GridRow { FieldLabel("오른쪽"); SpinField(value: length(\.marginRight), unit: "pt", range: 0...1000) }
                    }
                    .padding(.leading, 12)
                }
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("첫 줄")
                    HStack(alignment: .bottom, spacing: 10) {
                        Picker("첫 줄", selection: firstLine) {
                            Text("보통").tag(FirstLine.normal)
                            Text("들여쓰기").tag(FirstLine.indent)
                            Text("내어쓰기").tag(FirstLine.hang)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        SpinField(value: Binding { abs(style.indent ?? 0) } set: {
                            style.indent = (style.indent ?? 0) < 0 ? -$0 : $0
                        }, unit: "pt", range: 0...1000)
                        .disabled((style.indent ?? 0) == 0)
                    }
                    .padding(.leading, 12)
                }
            }
            GroupTitle("간격")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("줄 간격")
                    ChoiceField(Binding { style.lineSpacingKind ?? .percent } set: { kind in
                        guard kind != style.lineSpacingKind else { return }
                        style.lineSpacingKind = kind
                        style.lineSpacing = kind == .percent ? 160 : 12
                    }, [(.percent, "글자에 따라"), (.fixed, "고정 값"), (.spaceOnly, "여백만 지정"), (.minimum, "최소")])
                    FieldLabel("문단 위")
                    SpinField(value: length(\.spacingBefore), unit: "pt", range: 0...1000)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    let percent = (style.lineSpacingKind ?? .percent) == .percent
                    SpinField(value: length(\.lineSpacing), unit: percent ? "%" : "pt",
                              range: percent ? 50...500 : 0...1000)
                    FieldLabel("문단 아래")
                    SpinField(value: length(\.spacingAfter), unit: "pt", range: 0...1000)
                }
            }
            .padding(.leading, 12)
            GroupTitle("줄 나눔 기준")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("한글 단위")
                    ChoiceField(unit(\.koreanBreakUnit, 1), [(1, "글자"), (0, "어절")], minWidth: 90)
                }
                GridRow {
                    FieldLabel("영어 단위")
                    ChoiceField(unit(\.englishBreakUnit, 0), [(0, "단어"), (1, "하이픈"), (2, "글자")], minWidth: 90)
                }
            }
            .padding(.leading, 12)
        }
    }

    private var firstLine: Binding<FirstLine> {
        Binding {
            let indent = style.indent ?? 0
            return indent > 0 ? .indent : indent < 0 ? .hang : .normal
        } set: { kind in
            let amount = abs(style.indent ?? 0) == 0 ? 10 : abs(style.indent ?? 0)
            style.indent = switch kind { case .normal: 0; case .indent: amount; case .hang: -amount }
        }
    }
    private func length(_ key: WritableKeyPath<ParaStyle, Double?>) -> Binding<Double> {
        Binding { style[keyPath: key] ?? 0 } set: { style[keyPath: key] = $0 }
    }
    private func unit(_ key: WritableKeyPath<ParaStyle, Int?>, _ fallback: Int) -> Binding<Int> {
        Binding { style[keyPath: key] ?? fallback } set: { style[keyPath: key] = $0 }
    }
}

/// 글머리표 및 문단 번호: a 글머리표 or 문단 번호 kind for the selected paragraphs, and for
/// 문단 번호 in the body the 시작 번호 방식.
struct ListSheet: View {
    let original: ParaStyle
    /// The caret is in the body, where numbering can restart.
    let inBody: Bool
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var tab: String
    @State private var bullet: String?
    @State private var numbering: Int?
    @State private var restart: Int
    @State private var start: Double

    init(style: ParaStyle, body: Bool, tab: String, viewer: Viewer) {
        original = style
        inBody = body
        self.viewer = viewer
        _tab = State(initialValue: tab)
        _bullet = State(initialValue: style.head == "Bullet" ? style.bullet : nil)
        _numbering = State(initialValue: style.head == "Number" ? style.numbering : nil)
        _restart = State(initialValue: style.restart ?? 0)
        _start = State(initialValue: Double(style.startNumber ?? 1))
    }

    var body: some View {
        DialogFrame("글머리표 및 문단 번호", confirmTitle: "설정") {
            DialogTabs(selection: $tab, titles: ["글머리표", "문단 번호"]) { tab in
                if tab == "글머리표" {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupTitle("글머리표 모양")
                        Samples(count: FormatChoices.bullets.count, selected: FormatChoices.bullets.firstIndex { $0 == bullet }) {
                            bullet = $0.map { FormatChoices.bullets[$0] }
                        } sample: { BulletSample(bullet: FormatChoices.bullets[$0]) }
                    }
                    .padding(16)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupTitle("문단 번호 모양")
                        Samples(count: FormatChoices.numberings.count, selected: numbering) { numbering = $0 } sample: {
                            NumberingSample(levels: FormatChoices.numberings[$0])
                        }
                        GroupTitle("시작 번호 방식").padding(.top, 8)
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $restart) {
                                Text("앞 번호 목록에 이어").tag(0)
                                Text("이전 번호 목록에 이어").tag(1)
                                Text("새 번호 목록 시작").tag(2)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            LabeledField("1수준 시작 번호") { SpinField(value: $start, unit: "", range: 1...65535) }
                                .padding(.leading, 20)
                                .disabled(restart != 2)
                        }
                        .padding(.leading, 12)
                        .disabled(!inBody || numbering == nil)
                    }
                    .padding(16)
                }
            }
            .frame(width: 420, height: 470)
        } confirm: {
            var change = ParaStyle()
            switch (tab, bullet, numbering) {
            case ("글머리표", let bullet?, _):
                (change.head, change.bullet) = ("Bullet", bullet)
            case ("문단 번호", _, let numbering?):
                (change.head, change.numbering) = ("Number", numbering)
                if inBody, restart != (original.restart ?? 0) || (restart == 2 && Int(start) != original.startNumber) {
                    change.restart = restart
                    change.startNumber = restart == 2 ? Int(start) : nil
                }
            default:
                if original.head == "Bullet" || original.head == "Number" { change.head = "None" }
            }
            let same = change.head == original.head && change.bullet == (change.head == "Bullet" ? original.bullet : nil)
                && change.numbering == (change.head == "Number" ? original.numbering : nil) && change.restart == nil
            if !same { viewer.applyParaShape(change) }
            dismiss()
        }
    }
}

/// The kinds to pick from in a grid of four, after the box for none.
private struct Samples<Sample: View>: View {
    let count: Int
    let selected: Int?
    let pick: (Int?) -> Void
    @ViewBuilder let sample: (Int) -> Sample

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 4), count: 4), alignment: .leading, spacing: 4) {
            cell(nil) {
                ZStack {
                    Rectangle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 1)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 40))
                        path.addLine(to: CGPoint(x: 40, y: 0))
                    }
                    .stroke(Color.red.opacity(0.8), lineWidth: 1)
                }
                .frame(width: 40, height: 40)
            }
            ForEach(0..<count, id: \.self) { index in cell(index) { sample(index) } }
        }
        .padding(8)
        .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func cell(_ index: Int?, @ViewBuilder content: () -> some View) -> some View {
        Button { pick(index) } label: {
            content().frame(width: 84, height: 66)
                .background(selected == index ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Two lines headed by a 글머리표.
private struct BulletSample: View {
    let bullet: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 6) { Text(bullet).font(.system(size: 11)).frame(width: 14); SampleLines(count: 2) }
            }
        }
    }
}

/// Four levels of a 문단 번호 kind.
private struct NumberingSample: View {
    let levels: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(levels, id: \.self) { level in
                HStack(spacing: 4) {
                    Text(level).font(.system(size: 9)).lineLimit(1).fixedSize()
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(height: 1)
                }
            }
        }
        .frame(width: 68)
    }
}

/// Text lines, drawn as rules.
private struct SampleLines: View {
    let count: Int
    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { _ in Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 36, height: 1) }
        }
    }
}
