import AppKit
import SwiftUI

/// Formatting choices shared by the toolbar and the Format menu.
enum FormatChoices {
    static let sizes: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72]
    static let lineSpacings: [Double] = [100, 130, 160, 180, 200, 250, 300]
    /// 글머리표 characters, in 글머리표 모양's order.
    static let bullets = ["●", "•", "■", "▪", "◆", "⬥", "▶", "○", "□", "◇", "▷", "◉", "☑", "✔", "★", "❖", "☞"]
    /// Each 문단 번호 kind as its first four levels read, in 문단 번호 모양's order (the
    /// engine's `NUMBERINGS`).
    static let numberings = [
        ["1.", "가.", "1)", "가)"], ["(1)", "(가)", "(a)", "1)"], ["1)", "가)", "a)", "(1)"],
        ["①", "(ㄱ)", "(a)", "1)"], ["가)", "a)", "(1)", "(가)"], ["(ㄱ)", "(1)", "(a)", "1)"],
        ["I.", "A.", "1.", "i)"], ["i.", "a.", "(i)", "(a)"], ["A.", "1.", "가,", "(a)"],
        ["1.", "1.1.", "1.1.1.", "1.1.1.1."],
    ]
    static let colors = ["#000000", "#808080", "#ff0000", "#ff8000", "#ffd700", "#008000", "#0000ff", "#000080", "#800080"]
    /// 형광펜 colors; `none` removes the highlight.
    static let highlights = ["#ffff00", "#a6ff4d", "#66ffff", "#ff99cc", "#ffc04d"]
    /// No color: white, drawn as the web editor's slashed swatch.
    static let none = "#ffffff"
    /// Installed font families, by the name the user reads.
    static let families: [(name: String, family: String)] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .map { (NSFontManager.shared.localizedName(forFamily: $0, face: nil), $0) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static func label(_ alignment: Alignment) -> (title: String, symbol: String) {
        switch alignment {
        case .justify: ("양쪽 정렬", "text.justify")
        case .left: ("왼쪽 정렬", "text.alignleft")
        case .center: ("가운데 정렬", "text.aligncenter")
        case .right: ("오른쪽 정렬", "text.alignright")
        case .distribute: ("배분 정렬", "text.justify.leading")
        case .split: ("나눔 정렬", "text.justify.trailing")
        }
    }
    static func points(_ size: Double) -> String {
        size.rounded() == size ? "\(Int(size)) pt" : String(format: "%.1f pt", size)
    }
    /// A square of `hex`; `none` is white with a red slash, as in the web editor.
    static func swatch(_ hex: String, none: Bool = false) -> NSImage {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        let color = NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
                            blue: CGFloat(value & 255) / 255, alpha: 1)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let square = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
            color.setFill()
            square.fill()
            NSColor.separatorColor.setStroke()
            square.stroke()
            if none {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 2, y: rect.minY + 2))
                slash.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
                NSColor.systemRed.setStroke()
                slash.stroke()
            }
            return true
        }
        image.accessibilityDescription = hex
        return image
    }
}

/// 서식 도구 상자, as in Hancom Office Web: undo, font, size, character styles with line
/// shapes, text color, highlight, alignment and line spacing. It observes only the
/// document's format and context, so typing never rebuilds it.
struct FormatRow: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor
    /// The 언어 the font box shows and changes; nil for 대표 (all of them).
    @State private var language: Int?

    var body: some View {
        let text = document.format?.text, paragraph = document.format?.paragraph, context = document.context
        HStack(spacing: 3) {
            // 한/글 2024's order: 새 문서·불러오기·저장하기, 인쇄, 되돌리기·다시 실행, 스타일 … 줄 간격.
            ToolIcon("새 문서", symbol: Icon.newDocument) { NSDocumentController.shared.newDocument(nil) }
            ToolIcon("불러오기", symbol: Icon.open) { NSDocumentController.shared.openDocument(nil) }
            ToolIcon("저장하기", symbol: Icon.save) { send(#selector(NSDocument.save(_:))) }
            RowDivider()
            ToolIcon("인쇄", symbol: Icon.print) { send(#selector(DocumentCanvas.printDocument(_:))) }
            RowDivider()
            ToolIcon("되돌리기", symbol: Icon.undo) { send(Selector(("undo:"))) }
                .disabled(!context.canUndo)
            ToolIcon("다시 실행", symbol: Icon.redo) { send(Selector(("redo:"))) }
                .disabled(!context.canRedo)
            RowDivider()
            FieldBox(title: "스타일", opensWhenClicked: true, choices: { Self.styles(document, editor) }) {
                Text(document.styles.first { $0.id == document.format?.style }?.name ?? "스타일")
                    .lineLimit(1).frame(width: 84, alignment: .leading)
            }
            .disabled(!context.canApplyStyle)
            Group {
                FieldBox(title: "언어", opensWhenClicked: true, choices: {
                    ([nil] + CharShapeSheet.languageNames.indices.map { $0 }).map { index in
                        Choice(title: index.map { CharShapeSheet.languageNames[$0] } ?? "대표", on: index == language) {
                            language = index
                        }
                    }
                }) {
                    Text(language.map { CharShapeSheet.languageNames[$0] } ?? "대표").lineLimit(1).frame(width: 44, alignment: .leading)
                }
                let languages = document.format?.languages ?? []
                let font = language.flatMap { languages.indices.contains($0) ? languages[$0].font : nil } ?? text?.font
                FieldBox(title: "글꼴", opensWhenClicked: true, choices: { Self.fonts(font, language, editor) }) {
                    Text(font ?? "글꼴").lineLimit(1).frame(width: 128, alignment: .leading)
                }
                SizeField(size: text?.size, editor: editor)
                RowDivider()
                ToolIcon("진하게", glyph: Text("가").bold(), on: text?.bold == true) { editor.toggleBold() }
                ToolIcon("기울임", glyph: Text("가").italic(), on: text?.italic == true) { editor.toggleItalic() }
                ToolIcon("밑줄", glyph: Text("가").underline(), on: text?.underline == true) { editor.toggleUnderline() }
                ShapeMenu(title: "밑줄", colorTitle: "밑줄 색", pick: editor.format,
                          shape: { CharStyle(underline: true, underlineShape: $0) },
                          color: { CharStyle(underline: true, underlineColor: $0) })
                ToolIcon("취소선", glyph: Text("가").strikethrough(), on: text?.strikethrough == true) { editor.toggleStrikethrough() }
                ShapeMenu(title: "취소선", colorTitle: "취소선 색", pick: editor.format,
                          shape: { CharStyle(strikethrough: true, strikeShape: $0) },
                          color: { CharStyle(strikethrough: true, strikeColor: $0) })
                ColorMenu(title: "글자 색", symbol: "character", current: text?.color ?? "#000000",
                          colors: FormatChoices.colors, initial: "#ff0000") { editor.format(CharStyle(color: $0)) }
            }
            .disabled(!context.canFormat)
            RowDivider()
            Group {
                ForEach(Alignment.allCases, id: \.self) { alignment in
                    let label = FormatChoices.label(alignment)
                    ToolIcon(label.title, symbol: label.symbol, on: paragraph?.alignment == alignment) { editor.format(ParaStyle(alignment: alignment)) }
                }
                RowDivider()
                SpacingField(paragraph: paragraph, editor: editor)
            }
            .disabled(!context.canFormat)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    /// Every installed family, built only when the menu opens.
    static func styles(_ document: HwpDocument, _ editor: PageEditor) -> [Choice?] {
        document.styles.map { style in
            Choice(title: style.name, on: style.id == document.format?.style) {
                document.applyStyle(style.id, editor.undoManager)
            }
        }
    }
    private static func fonts(_ current: String?, _ language: Int?, _ editor: PageEditor) -> [Choice?] {
        FormatChoices.families.map { font in
            Choice(title: font.name, on: font.name == current || font.family == current) {
                editor.format(CharStyle(language: language, font: font.family))
            }
        }
    }
}

/// The size in points: typed, stepped by one, or picked.
private struct SizeField: View {
    let size: Double?
    let editor: PageEditor
    @State private var text = ""

    var body: some View {
        FieldBox(title: "글자 크기", choices: {
            FormatChoices.sizes.map { value in
                Choice(title: FormatChoices.points(value), on: value == size) { editor.format(CharStyle(size: value)) }
            }
        }) {
            HStack(spacing: 2) {
                NumberField(text: $text) { Double($0).map { editor.format(CharStyle(size: min(max($0, 1), 4096))) } }
                    .frame(width: 34)
                Text("pt").foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    StepArrow(symbol: "chevron.up") { editor.stepFontSize(by: 1) }
                    StepArrow(symbol: "chevron.down") { editor.stepFontSize(by: -1) }
                }
            }
        }
        .onAppear { text = Self.label(size) }
        .onChange(of: size) { text = Self.label(size) }
    }
    private static func label(_ size: Double?) -> String {
        size.map { String(format: "%.1f", $0) } ?? ""
    }
}

/// 줄 간격: the value of the caret's paragraph, typed or picked as a percentage.
private struct SpacingField: View {
    let paragraph: ParaStyle?
    let editor: PageEditor
    @State private var text = ""

    var body: some View {
        FieldBox(title: "줄 간격", choices: {
            FormatChoices.lineSpacings.map { percent in
                Choice(title: "\(Int(percent)) %", on: paragraph?.lineSpacingKind == .percent && paragraph?.lineSpacing == percent) {
                    editor.format(ParaStyle(lineSpacing: percent, lineSpacingKind: .percent))
                }
            }
        }) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.and.down.text.horizontal").font(.system(size: 12, weight: .light))
                NumberField(text: $text) { Double($0).map { editor.format(ParaStyle(lineSpacing: min(max($0, 50), 500), lineSpacingKind: .percent)) } }
                    .frame(width: 30)
                Text(paragraph?.lineSpacingKind == .percent || paragraph == nil ? "%" : "pt").foregroundStyle(.secondary)
            }
        }
        .onAppear { text = Self.label(paragraph) }
        .onChange(of: paragraph?.lineSpacing) { text = Self.label(paragraph) }
    }
    private static func label(_ paragraph: ParaStyle?) -> String {
        guard let value = paragraph?.lineSpacing else { return "" }
        return value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

/// A borderless number field for a `FieldBox`.
private struct NumberField: View {
    @Binding var text: String
    let submit: (String) -> Void
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .onSubmit { submit(text) }
    }
}

/// A small arrow of a size stepper.
struct StepArrow: View {
    let symbol: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 6, weight: .semibold)).frame(width: 12, height: 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolButtonStyle())
    }
}

/// A value in a rounded box with a ▾ that opens its choices, shared by 글꼴, 글자 크기
/// and 줄 간격 so they read as one family. `opensWhenClicked` makes the whole box open them.
private struct FieldBox<Content: View>: View {
    let title: String
    var opensWhenClicked = false
    let choices: () -> [Choice?]
    @ViewBuilder let content: Content
    @State private var anchor = Anchor()

    var body: some View {
        HStack(spacing: 0) {
            if opensWhenClicked {
                Button(action: open) { HStack(spacing: 0) { content.padding(.leading, 7); Chevron() }.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            } else {
                content.padding(.leading, 5)
                Button(action: open) { Chevron().contentShape(Rectangle()) }.buttonStyle(.plain)
            }
        }
        .fieldBox()
        .background(AnchorView(anchor: anchor))
        .help(title)
    }
    private func open() { DropDown.show(choices(), below: anchor.view) }
}

/// Line shapes for underline or strikethrough, drawn as in the web editor, with the
/// line's color below them.
private struct ShapeMenu: View {
    let title: String, colorTitle: String
    let pick: (CharStyle) -> Void
    let shape: (Int) -> CharStyle, color: (String) -> CharStyle
    var body: some View {
        MenuArrow(title: title) {
            let shapes: [Choice?] = LineShapes.names.indices.map { index in
                Choice(title: "", image: LineShapes.images[index]) { pick(shape(index)) }
            }
            let colors: [Choice?] = FormatChoices.colors.map { hex in
                Choice(title: "", image: FormatChoices.swatch(hex)) { pick(self.color(hex)) }
            }
            return shapes + [nil, Choice(title: colorTitle, symbol: "paintbrush.pointed", submenu: colors)]
        }
    }
}

/// The small arrow beside a format button that opens its choices.
private struct MenuArrow: View {
    let title: String
    let choices: () -> [Choice?]
    @State private var anchor = Anchor()
    var body: some View {
        Button { DropDown.show(choices(), below: anchor.view) } label: { Chevron() }
            .buttonStyle(ToolButtonStyle())
            .background(AnchorView(anchor: anchor))
            .help(title)
    }
}

/// The small arrow that opens a button's choices.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).frame(width: 14, height: 22)
    }
}

/// A color button, as 한/글's: the symbol over a bar of the color last picked, which the
/// button applies; the arrow beside it opens the palette.
struct ColorMenu: View {
    let title: String, symbol: String, current: String
    let colors: [String]
    /// Offers `FormatChoices.none` after the colors.
    var clears = false
    let pick: (String) -> Void
    @AppStorage private var last: String
    @State private var open = false

    init(title: String, symbol: String, current: String, colors: [String], initial: String, clears: Bool = false,
         pick: @escaping (String) -> Void) {
        (self.title, self.symbol, self.current, self.colors, self.clears, self.pick) = (title, symbol, current, colors, clears, pick)
        _last = AppStorage(wrappedValue: initial, "lastColor.\(title)")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { pick(last) } label: {
                VStack(spacing: 1) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .light))
                    Rectangle().fill(HexColor.color(last)).frame(width: 14, height: 3)
                }
                .frame(width: 20, height: 22)
            }
            .buttonStyle(ToolButtonStyle())
            .help(title)
            Button { open = true } label: { Chevron() }
                .buttonStyle(ToolButtonStyle(on: open))
                .help(title)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    HStack(spacing: 4) {
                        ForEach(colors + (clears ? [FormatChoices.none] : []), id: \.self) { hex in
                            Button {
                                open = false
                                last = hex
                                pick(hex)
                            } label: {
                                Image(nsImage: FormatChoices.swatch(hex, none: clears && hex == FormatChoices.none))
                                    .padding(3)
                            }
                            .buttonStyle(ToolButtonStyle(on: hex == current))
                        }
                    }
                    .padding(8)
                }
        }
    }
}

/// A small icon (or glyph) button for the format row; `on` keeps it highlighted.
struct ToolIcon: View {
    let title: String, icon: AnyView, on: Bool, action: () -> Void
    init(_ title: String, symbol: String, on: Bool = false, action: @escaping () -> Void) {
        self.init(title, icon: AnyView(Image(systemName: symbol).font(.system(size: 13, weight: .light))), on: on, action: action)
    }
    init(_ title: String, glyph: Text, on: Bool = false, action: @escaping () -> Void) {
        self.init(title, icon: AnyView(glyph.font(.system(size: 14))), on: on, action: action)
    }
    private init(_ title: String, icon: AnyView, on: Bool, action: @escaping () -> Void) {
        (self.title, self.icon, self.on, self.action) = (title, icon, on, action)
    }
    var body: some View {
        Button(action: action) {
            icon.frame(width: 24, height: 22)
        }
        .buttonStyle(ToolButtonStyle(on: on))
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Flat button that shows a background on hover, press and when on.
struct ToolButtonStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, on: on)
    }
    private struct Styled: View {
        let configuration: Configuration
        let on: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? .primary : .tertiary)
                .background(RoundedRectangle(cornerRadius: 5).fill(fill))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
        private var fill: Color {
            if on || configuration.isPressed { return Color.primary.opacity(0.14) }
            return hovering && enabled ? Color.primary.opacity(0.07) : .clear
        }
    }
}

extension View {
    /// The rounded box of the format row's fields and the dialogs' number fields.
    func fieldBox() -> some View {
        frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct RowDivider: View {
    var body: some View { Divider().frame(height: 18).padding(.horizontal, 4) }
}
