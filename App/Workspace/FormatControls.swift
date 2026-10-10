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

/// The installed families in a pop-up, a font that is not installed shown as it is named.
/// Built again only when the font or 언어 changes: typing changes neither.
struct FontPicker: View, @MainActor Equatable {
    let font: String?
    let language: Int?
    let pick: (String) -> Void
    static func == (a: Self, b: Self) -> Bool { a.font == b.font && a.language == b.language }

    var body: some View {
        let family = font.map { font in FormatChoices.families.first { $0.name == font || $0.family == font }?.family ?? font }
        Picker("글꼴", selection: Binding(get: { family ?? "" }, set: pick)) {
            if let family, !FormatChoices.families.contains(where: { $0.family == family }) { Text(family).tag(family) }
            if family == nil { Text("글꼴").tag("") }
            ForEach(FormatChoices.families, id: \.family) { Text($0.name).tag($0.family) }
        }
        .labelsHidden()
        .help("글꼴")
    }
}

/// A small icon (or glyph) button, borderless as a bar's.
struct ToolIcon: View {
    let title: String, icon: AnyView, action: () -> Void
    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.init(title, icon: AnyView(Image(systemName: symbol)), action: action)
    }
    private init(_ title: String, icon: AnyView, action: @escaping () -> Void) {
        (self.title, self.icon, self.action) = (title, icon, action)
    }
    var body: some View {
        Button(action: action) { icon }
            .buttonStyle(.borderless)
            .help(title)
            .accessibilityLabel(title)
    }
}

extension View {
    /// A button that shows a choice: bordered, and in the accent color while it is on.
    @ViewBuilder func choice(_ on: Bool) -> some View {
        if on { buttonStyle(.borderedProminent).accessibilityAddTraits(.isSelected) } else { buttonStyle(.bordered) }
    }
}

struct RowDivider: View {
    var body: some View { Divider().frame(height: 18).padding(.horizontal, 4) }
}

#Preview {
    FontPicker(font: nil, language: nil, pick: { _ in }).padding()
}
