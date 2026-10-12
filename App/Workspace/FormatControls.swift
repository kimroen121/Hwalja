import AppKit
import SwiftUI

/// Formatting choices shared by the toolbar and the Format menu.
enum FormatChoices {
    /// 언어별 설정's choices, in the web editor's order.
    static let languageNames = ["한글", "영문", "한자", "일어", "외국어", "기호", "사용자"]
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
        Picker("글꼴", selection: Binding(get: { family ?? "" }, set: { pick($0) })) {
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

#Preview {
    FontPicker(font: nil, language: nil, pick: { _ in }).padding()
}
