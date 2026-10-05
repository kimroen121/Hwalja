import SwiftUI

// Structure commands (breaks, tables, page setup) and the sheets that ask for their values.

extension Viewer {
    private var document: HwpDocument? { canvas.editor.model }
    private var undoManager: UndoManager? { canvas.editor.undoManager }

    /// Whether the caret is in body text, where breaks and tables go.
    var inBody: Bool { document?.selection.map { $0.focus.target.cell == nil && $0.focus.target.note == nil } ?? false }
    /// Whether the caret is in a table cell.
    var inTable: Bool { document?.selection?.focus.target.cell != nil }

    func insertBreak(column: Bool) {
        document?.edit(undoManager) { $0.map { .pageBreak($0.ordered.start, column: column) } }
    }
    func insertTable(rows: Int, columns: Int) {
        document?.edit(undoManager) { $0.map { .insertTable($0.ordered.start, rows: rows, columns: columns) } }
    }
    func insertNote(endnote: Bool) {
        document?.edit(undoManager) { $0.map { .insertNote($0.ordered.start, endnote: endnote) } }
    }
    func editTable(_ change: TableChange) {
        document?.edit(undoManager) { selection in
            guard let target = selection?.focus.target, target.cell != nil else { return nil }
            return .editTable(target, change)
        }
    }

    /// Opens 편집 용지 for the section holding the caret.
    func showPageSetup() {
        guard let document else { return }
        let section = document.selection?.focus.target.section ?? 0
        Task {
            guard let page = try? await document.pageSetup(section: section) else { return NSSound.beep() }
            pageSetup = (section, page)
        }
    }
    func setPage(_ page: PageSetup, section: UInt32) {
        document?.edit(undoManager) { _ in .setPage(section: section, page) }
    }
    /// Replaces the section's 머리말 (or 꼬리말) for every page.
    func headerFooter(footer: Bool, pageNumber: Placement?) {
        document?.edit(undoManager) { selection in
            .headerFooter(section: selection?.focus.target.section ?? 0, footer: footer, pageNumber: pageNumber)
        }
    }
}

/// 표 만들기: row and column counts.
struct TableSheet: View {
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 5
    @State private var columns = 5

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Form {
                Stepper(value: $rows, in: 1...1000) {
                    LabeledContent("줄 개수") { TextField("", value: $rows, format: .number).frame(width: 56) }
                }
                Stepper(value: $columns, in: 1...256) {
                    LabeledContent("칸 개수") { TextField("", value: $columns, format: .number).frame(width: 56) }
                }
            }
            HStack {
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("만들기") {
                    viewer.insertTable(rows: min(max(rows, 1), 1000), columns: min(max(columns, 1), 256))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .fixedSize()
    }
}

/// 편집 용지: paper size and orientation, and margins, in millimeters.
struct PageSetupSheet: View {
    let section: UInt32
    @ObservedObject var viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var page: PageSetup

    init(section: UInt32, page: PageSetup, viewer: Viewer) {
        self.section = section
        self.viewer = viewer
        _page = State(initialValue: page)
    }

    private static let papers: [(name: String, width: Double, height: Double)] = [
        ("A3", 297, 420), ("A4", 210, 297), ("A5", 148, 210), ("B4", 257, 364), ("B5", 182, 257),
        ("레터", 215.9, 279.4), ("리걸", 215.9, 355.6),
    ]
    private static let unitsPerMillimeter = 7200 / 25.4

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Form {
                Section("용지 종류") {
                    Picker("크기", selection: paper) {
                        ForEach(Self.papers, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                        Text("사용자 정의").tag(String?.none)
                    }
                    millimeters("폭", \.width)
                    millimeters("길이", \.height)
                    Picker("방향", selection: $page.landscape) {
                        Text("세로").tag(false)
                        Text("가로").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section("여백") {
                    millimeters("위쪽", \.marginTop)
                    millimeters("아래쪽", \.marginBottom)
                    millimeters("왼쪽", \.marginLeft)
                    millimeters("오른쪽", \.marginRight)
                    millimeters("머리말", \.marginHeader)
                    millimeters("꼬리말", \.marginFooter)
                    millimeters("제본", \.marginGutter)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("설정") {
                    viewer.setPage(page, section: section)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 360)
    }

    /// The named paper matching the size within half a millimeter.
    private var paper: Binding<String?> {
        Binding {
            let size = (Self.millimeters(page.width), Self.millimeters(page.height))
            return Self.papers.first { abs($0.width - size.0) < 0.5 && abs($0.height - size.1) < 0.5 }?.name
        } set: { name in
            guard let paper = Self.papers.first(where: { $0.name == name }) else { return }
            page.width = Self.units(paper.width)
            page.height = Self.units(paper.height)
        }
    }

    private func millimeters(_ title: String, _ key: WritableKeyPath<PageSetup, UInt32>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding { Self.millimeters(page[keyPath: key]) } set: { page[keyPath: key] = Self.units($0) },
                          format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }
    private static func millimeters(_ units: UInt32) -> Double { (Double(units) / unitsPerMillimeter * 10).rounded() / 10 }
    private static func units(_ millimeters: Double) -> UInt32 { UInt32(max(0, millimeters * unitsPerMillimeter).rounded()) }
}

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

/// Converts between `#rrggbb` and SwiftUI colors.
enum HexColor {
    static func color(_ hex: String?) -> Color {
        let value = Int((hex ?? "#000000").dropFirst(), radix: 16) ?? 0
        return Color(.sRGB, red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
    static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

/// Line shapes for underline and strikethrough, in Hancom's order and numbering.
enum LineShapes {
    static let names = ["실선", "파선", "점선", "일점쇄선", "이점쇄선", "긴 파선", "원형 점선", "이중 실선",
                        "얇고 굵은 이중선", "굵고 얇은 이중선", "얇고 굵고 얇은 삼중선", "물결선", "이중 물결선"]
}

/// 글자 모양: every character attribute of the selection (or of the next text typed).
/// Only the attributes the user changed are applied.
struct CharShapeSheet: View {
    let original: CharStyle
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var style: CharStyle

    init(style: CharStyle, viewer: Viewer) {
        original = style
        self.viewer = viewer
        _style = State(initialValue: style)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section("기본") {
                    Picker("글꼴", selection: binding(\.font, "")) {
                        ForEach(FormatChoices.families, id: \.family) { Text($0.name).tag($0.family) }
                        if let font = original.font, !FormatChoices.families.contains(where: { $0.family == font }) {
                            Text(font).tag(font)
                        }
                    }
                    number("기준 크기", binding(\.size, 10), "pt", 1...4096)
                    number("장평", binding(\.ratio, 100), "%", 50...200)
                    number("자간", binding(\.spacing, 0), "%", -50...50)
                }
                Section("속성") {
                    Toggle("진하게", isOn: binding(\.bold, false))
                    Toggle("기울임", isOn: binding(\.italic, false))
                    line("밑줄", \.underline, \.underlineShape)
                    line("취소선", \.strikethrough, \.strikeShape)
                    Toggle("외곽선", isOn: binding(\.outline, false))
                    Toggle("그림자", isOn: binding(\.shadow, false))
                    Toggle("양각", isOn: binding(\.emboss, false))
                    Toggle("음각", isOn: binding(\.engrave, false))
                    Toggle("위 첨자", isOn: Binding { style.superscript == true } set: {
                        style.superscript = $0
                        if $0 { style.`subscript` = false }
                    })
                    Toggle("아래 첨자", isOn: Binding { style.`subscript` == true } set: {
                        style.`subscript` = $0
                        if $0 { style.superscript = false }
                    })
                }
                Section("색") {
                    ColorPicker("글자 색", selection: Binding { HexColor.color(style.color) } set: { style.color = HexColor.hex($0) },
                                supportsOpacity: false)
                    LabeledContent("음영 색") {
                        HStack {
                            if style.shade.map({ $0 != "#ffffff" }) == true {
                                Button("없음") { style.shade = "#ffffff" }
                            }
                            ColorPicker("음영 색", selection: Binding { HexColor.color(style.shade ?? "#ffffff") } set: {
                                style.shade = HexColor.hex($0)
                            }, supportsOpacity: false)
                            .labelsHidden()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            SheetButtons(confirm: "설정") {
                viewer.applyCharShape(style.changes(from: original))
                dismiss()
            }
        }
        .frame(width: 380, height: 640)
    }

    private func binding<T>(_ key: WritableKeyPath<CharStyle, T?>, _ fallback: T) -> Binding<T> {
        Binding { style[keyPath: key] ?? fallback } set: { style[keyPath: key] = $0 }
    }
    private func line(_ title: String, _ on: WritableKeyPath<CharStyle, Bool?>, _ shape: WritableKeyPath<CharStyle, Int?>) -> some View {
        HStack {
            Toggle(title, isOn: binding(on, false))
            Spacer()
            Picker(title, selection: binding(shape, 0)) {
                ForEach(LineShapes.names.indices, id: \.self) { Text(LineShapes.names[$0]).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(style[keyPath: on] != true)
        }
    }
}

/// 문단 모양: alignment, margins, first-line indent, spacing and breaking.
/// Only the attributes the user changed are applied.
struct ParaShapeSheet: View {
    let original: ParaStyle
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var style: ParaStyle

    init(style: ParaStyle, viewer: Viewer) {
        original = style
        self.viewer = viewer
        _style = State(initialValue: style)
    }

    private enum FirstLine: Hashable { case normal, indent, hang }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section("정렬") {
                    Picker("정렬 방식", selection: Binding { style.alignment ?? .justify } set: { style.alignment = $0 }) {
                        ForEach(Alignment.allCases, id: \.self) { Text(FormatChoices.label($0).title).tag($0) }
                    }
                }
                Section("여백") {
                    number("왼쪽", length(\.marginLeft), "pt", 0...1000)
                    number("오른쪽", length(\.marginRight), "pt", 0...1000)
                    Picker("첫 줄", selection: firstLine) {
                        Text("보통").tag(FirstLine.normal)
                        Text("들여쓰기").tag(FirstLine.indent)
                        Text("내어쓰기").tag(FirstLine.hang)
                    }
                    .pickerStyle(.segmented)
                    if (style.indent ?? 0) != 0 {
                        number("첫 줄 간격", Binding { abs(style.indent ?? 0) } set: {
                            style.indent = (style.indent ?? 0) < 0 ? -$0 : $0
                        }, "pt", 0...1000)
                    }
                }
                Section("간격") {
                    Picker("줄 간격", selection: Binding { style.lineSpacingKind ?? .percent } set: { kind in
                        guard kind != style.lineSpacingKind else { return }
                        style.lineSpacingKind = kind
                        style.lineSpacing = kind == .percent ? 160 : 12
                    }) {
                        Text("글자에 따라").tag(LineSpacingKind.percent)
                        Text("고정 값").tag(LineSpacingKind.fixed)
                        Text("여백만 지정").tag(LineSpacingKind.spaceOnly)
                        Text("최소").tag(LineSpacingKind.minimum)
                    }
                    number("값", length(\.lineSpacing), style.lineSpacingKind == .percent ? "%" : "pt",
                           style.lineSpacingKind == .percent ? 50...500 : 0...1000)
                    number("문단 위", length(\.spacingBefore), "pt", 0...1000)
                    number("문단 아래", length(\.spacingAfter), "pt", 0...1000)
                }
                Section("줄 나눔") {
                    Toggle("외톨이줄 보호", isOn: flag(\.widowOrphan))
                    Toggle("다음 문단과 함께", isOn: flag(\.keepWithNext))
                    Toggle("문단 보호", isOn: flag(\.keepLines))
                    Toggle("문단 앞에서 항상 쪽 나눔", isOn: flag(\.pageBreakBefore))
                }
            }
            .formStyle(.grouped)
            SheetButtons(confirm: "설정") {
                viewer.applyParaShape(style.changes(from: original))
                dismiss()
            }
        }
        .frame(width: 400, height: 640)
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
    private func flag(_ key: WritableKeyPath<ParaStyle, Bool?>) -> Binding<Bool> {
        Binding { style[keyPath: key] ?? false } set: { style[keyPath: key] = $0 }
    }
}

/// A labeled number field with its unit, clamped to `range`.
private func number(_ title: String, _ value: Binding<Double>, _ unit: String, _ range: ClosedRange<Double>) -> some View {
    LabeledContent(title) {
        HStack(spacing: 4) {
            TextField(title, value: Binding { value.wrappedValue } set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) },
                      format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text(unit).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
        }
    }
}

/// 취소 and a default confirm button at the bottom of a sheet.
struct SheetButtons: View {
    let confirm: String
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack {
            Button("취소", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(confirm, action: action)
                .keyboardShortcut(.defaultAction)
        }
        .padding([.horizontal, .bottom], 20)
    }
}
