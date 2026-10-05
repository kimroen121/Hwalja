import AppKit
import SwiftUI

/// Formatting choices shared by the toolbar and the Format menu.
enum FormatChoices {
    static let sizes: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72]
    static let lineSpacings: [Double] = [100, 130, 160, 180, 200, 250, 300]
    static let colors: [(name: String, hex: String)] = [
        ("검정", "#000000"), ("회색", "#808080"), ("빨강", "#ff0000"), ("주황", "#ff8000"),
        ("노랑", "#ffd700"), ("초록", "#008000"), ("파랑", "#0000ff"), ("남색", "#000080"), ("보라", "#800080"),
    ]
    /// 형광펜 colors; white removes the highlight.
    static let highlights: [(name: String, hex: String)] = [
        ("노랑", "#ffff00"), ("연두", "#a6ff4d"), ("하늘", "#66ffff"), ("분홍", "#ff99cc"), ("주황", "#ffc04d"),
        ("없음", "#ffffff"),
    ]
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
    static func swatch(_ hex: String) -> NSImage {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        let color = NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
                            blue: CGFloat(value & 255) / 255, alpha: 1)
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}

/// 서식 도구 상자, as in Hancom Office Web: undo, font, size, character styles with line
/// shapes, text color, highlight, alignment and line spacing. It observes only the
/// document's format and context, so typing never rebuilds it.
struct FormatRow: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor

    var body: some View {
        let text = document.format?.text, paragraph = document.format?.paragraph, context = document.context
        HStack(spacing: 3) {
            ToolIcon("되돌리기", symbol: "arrow.uturn.backward") { send(Selector(("undo:"))) }
                .disabled(!context.canUndo)
            ToolIcon("다시 실행", symbol: "arrow.uturn.forward") { send(Selector(("redo:"))) }
                .disabled(!context.canRedo)
            RowDivider()
            Group {
                Menu { FontList(editor: editor) } label: { Text(text?.font ?? "글꼴").lineLimit(1) }
                    .frame(width: 150)
                    .help("글꼴")
                SizeField(size: text?.size, editor: editor)
                RowDivider()
                ToolIcon("진하게", glyph: Text("가").bold(), on: text?.bold == true) { editor.toggleBold() }
                ToolIcon("기울임", glyph: Text("가").italic(), on: text?.italic == true) { editor.toggleItalic() }
                ToolIcon("밑줄", glyph: Text("가").underline(), on: text?.underline == true) { editor.toggleUnderline() }
                ShapeMenu(title: "밑줄 모양") { editor.setUnderline(shape: $0) }
                ToolIcon("취소선", glyph: Text("가").strikethrough(), on: text?.strikethrough == true) { editor.toggleStrikethrough() }
                ShapeMenu(title: "취소선 모양") { editor.setStrikethrough(shape: $0) }
                RowDivider()
                ColorMenu(title: "글자 색", symbol: "character", current: text?.color ?? "#000000",
                          colors: FormatChoices.colors) { editor.setTextColor($0) }
                ColorMenu(title: "형광펜", symbol: "highlighter", current: text?.shade ?? "#ffffff",
                          colors: FormatChoices.highlights) { editor.setShade($0) }
            }
            .disabled(!context.hasSelection)
            RowDivider()
            Group {
                ForEach(Alignment.allCases, id: \.self) { alignment in
                    let label = FormatChoices.label(alignment)
                    ToolIcon(label.title, symbol: label.symbol, on: paragraph?.alignment == alignment) { editor.setAlignment(alignment) }
                }
                RowDivider()
                Menu {
                    ForEach(FormatChoices.lineSpacings, id: \.self) { percent in
                        Button("\(Int(percent)) %") { editor.setLineSpacing(percent) }
                    }
                } label: {
                    Label(Self.spacing(paragraph), systemImage: "arrow.up.and.down.text.horizontal")
                        .labelStyle(.titleAndIcon)
                        .monospacedDigit()
                }
                .fixedSize()
                .help("줄 간격")
            }
            .disabled(!context.hasSelection)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    private static func spacing(_ paragraph: ParaStyle?) -> String {
        guard let value = paragraph?.lineSpacing else { return "줄 간격" }
        let number = value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
        return paragraph?.lineSpacingKind == .percent ? "\(number) %" : "\(number) pt"
    }
}

/// The size in points: typed, stepped by one, or picked.
private struct SizeField: View {
    let size: Double?
    let editor: PageEditor
    @State private var text = ""

    var body: some View {
        HStack(spacing: 0) {
            TextField("크기", text: $text)
                .frame(width: 40)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .onSubmit { Double(text).map { editor.setFontSize(min(max($0, 1), 4096)) } }
            Text(" pt").foregroundStyle(.secondary)
            Stepper("크기", onIncrement: { editor.stepFontSize(by: 1) }, onDecrement: { editor.stepFontSize(by: -1) })
                .labelsHidden()
            Menu {
                ForEach(FormatChoices.sizes, id: \.self) { size in
                    Button(FormatChoices.points(size)) { editor.setFontSize(size) }
                }
            } label: { Chevron() }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .help("글자 크기")
        .onAppear { text = Self.label(size) }
        .onChange(of: size) { text = Self.label(size) }
    }
    private static func label(_ size: Double?) -> String {
        size.map { String(format: "%.1f", $0) } ?? ""
    }
}

/// Line shapes for underline or strikethrough.
private struct ShapeMenu: View {
    let title: String
    let pick: (Int) -> Void
    var body: some View {
        Menu {
            ForEach(LineShapes.names.indices, id: \.self) { index in
                Button(LineShapes.names[index]) { pick(index) }
            }
        } label: { Chevron() }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(title)
    }
}

/// The small arrow that opens a button's choices.
private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).frame(width: 10, height: 22)
    }
}

/// A color button: the symbol over a bar of the current color, with a palette.
private struct ColorMenu: View {
    let title: String, symbol: String, current: String
    let colors: [(name: String, hex: String)]
    let pick: (String) -> Void
    var body: some View {
        Menu {
            ForEach(colors, id: \.hex) { color in
                Button { pick(color.hex) } label: {
                    Label { Text(color.name) } icon: { Image(nsImage: FormatChoices.swatch(color.hex)) }
                }
            }
        } label: {
            HStack(spacing: 2) {
                VStack(spacing: 1) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .light))
                    Rectangle().fill(HexColor.color(current)).frame(width: 14, height: 3)
                }
                Chevron()
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
    }
}

/// Every installed font family. A separate view with no changing inputs, so SwiftUI
/// builds its long list once instead of on every format change.
private struct FontList: View {
    let editor: PageEditor
    var body: some View {
        ForEach(FormatChoices.families, id: \.family) { font in
            Button(font.name) { editor.setFont(font.family) }
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

struct RowDivider: View {
    var body: some View { Divider().frame(height: 18).padding(.horizontal, 4) }
}
