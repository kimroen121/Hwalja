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

/// The window's format bar: font, size, character styles, color, alignment and line spacing.
struct FormatBar: ToolbarContent {
    @ObservedObject var document: HwpDocument
    let canvas: DocumentCanvas

    private var text: CharStyle? { document.format?.text }
    private var paragraph: ParaStyle? { document.format?.paragraph }
    /// Character formats apply to selected text.
    private var hasRange: Bool { document.selection.map { $0.anchor != $0.focus } ?? false }

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Group {
                Menu(text?.font ?? "글꼴") {
                    ForEach(FormatChoices.families, id: \.family) { font in
                        Button(font.name) { canvas.setFont(font.family) }
                    }
                }
                .frame(width: 140)
                .help("글꼴")
                Menu(text?.size.map(FormatChoices.points) ?? "크기") {
                    ForEach(FormatChoices.sizes, id: \.self) { size in
                        Button(FormatChoices.points(size)) { canvas.setFontSize(size) }
                    }
                }
                .frame(width: 72)
                .help("글자 크기")
                ControlGroup {
                    style("굵게", "bold", text?.bold, canvas.toggleBold)
                    style("기울임꼴", "italic", text?.italic, canvas.toggleItalic)
                    style("밑줄", "underline", text?.underline, canvas.toggleUnderline)
                    style("취소선", "strikethrough", text?.strikethrough, canvas.toggleStrikethrough)
                }
                Menu {
                    ForEach(FormatChoices.colors, id: \.hex) { color in
                        Button { canvas.setTextColor(color.hex) } label: {
                            Label { Text(color.name) } icon: { Image(nsImage: FormatChoices.swatch(color.hex)) }
                        }
                    }
                } label: {
                    Label("글자 색", systemImage: "paintbrush.pointed")
                }
                .help("글자 색")
            }
            .disabled(!hasRange)
            Group {
                Picker("정렬", selection: Binding(get: { paragraph?.alignment }, set: { $0.map(canvas.setAlignment) })) {
                    ForEach([Alignment.justify, .left, .center, .right], id: \.self) { alignment in
                        let label = FormatChoices.label(alignment)
                        Label(label.title, systemImage: label.symbol).tag(Optional(alignment))
                    }
                }
                .pickerStyle(.segmented)
                .help("정렬")
                Menu {
                    ForEach(FormatChoices.lineSpacings, id: \.self) { percent in
                        Button("\(Int(percent))%") { canvas.setLineSpacing(percent) }
                    }
                } label: {
                    Label("줄 간격", systemImage: "arrow.up.and.down.text.horizontal")
                }
                .help("줄 간격")
            }
            .disabled(document.selection == nil)
        }
    }

    private func style(_ title: String, _ symbol: String, _ on: Bool?, _ action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on == true }, set: { _ in action() })) {
            Label(title, systemImage: symbol)
        }
        .help(title)
    }
}

/// The Format menu, acting on the focused document window.
struct FormatCommands: Commands {
    @FocusedObject private var document: HwpDocument?
    @FocusedObject private var viewer: Viewer?

    var body: some Commands {
        CommandMenu("서식") {
            let text = document?.format?.text
            let canvas = viewer?.canvas
            let hasRange = document?.selection.map { $0.anchor != $0.focus } ?? false
            Group {
                toggle("굵게", text?.bold) { canvas?.toggleBold() }.keyboardShortcut("b")
                toggle("기울임꼴", text?.italic) { canvas?.toggleItalic() }.keyboardShortcut("i")
                toggle("밑줄", text?.underline) { canvas?.toggleUnderline() }.keyboardShortcut("u")
                toggle("취소선", text?.strikethrough) { canvas?.toggleStrikethrough() }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("글자 크게") { canvas?.stepFontSize(by: 1) }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button("글자 작게") { canvas?.stepFontSize(by: -1) }.keyboardShortcut(",", modifiers: [.command, .shift])
            }
            .disabled(!hasRange)
            Divider()
            Group {
                ForEach(Alignment.allCases, id: \.self) { alignment in
                    let shortcut: KeyboardShortcut? = switch alignment {
                    case .left: KeyboardShortcut("[", modifiers: [.command, .shift])
                    case .center: KeyboardShortcut("\\", modifiers: [.command, .shift])
                    case .right: KeyboardShortcut("]", modifiers: [.command, .shift])
                    case .justify: KeyboardShortcut("\\", modifiers: [.command, .option, .shift])
                    default: nil
                    }
                    toggle(FormatChoices.label(alignment).title, document?.format?.paragraph.alignment == alignment) {
                        canvas?.setAlignment(alignment)
                    }
                    .keyboardShortcut(shortcut)
                }
                Menu("줄 간격") {
                    ForEach(FormatChoices.lineSpacings, id: \.self) { percent in
                        toggle("\(Int(percent))%", document?.format?.paragraph.lineSpacing == percent) {
                            canvas?.setLineSpacing(percent)
                        }
                    }
                }
            }
            .disabled(document?.selection == nil)
        }
    }

    private func toggle(_ title: String, _ on: Bool?, _ action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on == true }, set: { _ in action() }))
    }
}
