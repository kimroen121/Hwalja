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

/// 서식 도구 상자: undo, font, size, character styles, color, alignment and line spacing.
/// It observes only the document's format and context, so typing never rebuilds it.
struct FormatRow: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor

    var body: some View {
        let text = document.format?.text, paragraph = document.format?.paragraph, context = document.context
        HStack(spacing: 4) {
            ToolIcon("되돌리기", "arrow.uturn.backward") { send(Selector(("undo:"))) }
                .disabled(!context.canUndo)
            ToolIcon("다시 실행", "arrow.uturn.forward") { send(Selector(("redo:"))) }
                .disabled(!context.canRedo)
            RowDivider()
            Group {
                Menu { FontList(editor: editor) } label: { Text(text?.font ?? "글꼴").lineLimit(1) }
                    .frame(width: 150)
                    .help("글꼴")
                Menu {
                    ForEach(FormatChoices.sizes, id: \.self) { size in
                        Button(FormatChoices.points(size)) { editor.setFontSize(size) }
                    }
                } label: { Text(text?.size.map(FormatChoices.points) ?? "크기").monospacedDigit() }
                    .frame(width: 72)
                    .help("글자 크기")
                ToolIcon("글자 크게", "textformat.size.larger") { editor.stepFontSize(by: 1) }
                ToolIcon("글자 작게", "textformat.size.smaller") { editor.stepFontSize(by: -1) }
                RowDivider()
                ToolIcon("굵게", "bold", on: text?.bold == true) { editor.toggleBold() }
                ToolIcon("기울임꼴", "italic", on: text?.italic == true) { editor.toggleItalic() }
                ToolIcon("밑줄", "underline", on: text?.underline == true) { editor.toggleUnderline() }
                ToolIcon("취소선", "strikethrough", on: text?.strikethrough == true) { editor.toggleStrikethrough() }
                Menu {
                    ForEach(FormatChoices.colors, id: \.hex) { color in
                        Button { editor.setTextColor(color.hex) } label: {
                            Label { Text(color.name) } icon: { Image(nsImage: FormatChoices.swatch(color.hex)) }
                        }
                    }
                } label: { Image(systemName: "paintbrush.pointed") }
                    .menuIndicator(.visible)
                    .fixedSize()
                    .help("글자 색")
            }
            .disabled(!context.hasRange)
            RowDivider()
            Group {
                ForEach(Alignment.allCases, id: \.self) { alignment in
                    let label = FormatChoices.label(alignment)
                    ToolIcon(label.title, label.symbol, on: paragraph?.alignment == alignment) { editor.setAlignment(alignment) }
                }
                RowDivider()
                Menu {
                    ForEach(FormatChoices.lineSpacings, id: \.self) { percent in
                        Button("\(Int(percent))%") { editor.setLineSpacing(percent) }
                    }
                } label: {
                    Label(paragraph?.lineSpacing.map { "\(Int($0))%" } ?? "줄 간격", systemImage: "arrow.up.and.down.text.horizontal")
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

/// A small icon button for the format row; `on` keeps it highlighted.
struct ToolIcon: View {
    let title: String, symbol: String, on: Bool, action: () -> Void
    init(_ title: String, _ symbol: String, on: Bool = false, action: @escaping () -> Void) {
        (self.title, self.symbol, self.on, self.action) = (title, symbol, on, action)
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 22)
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
