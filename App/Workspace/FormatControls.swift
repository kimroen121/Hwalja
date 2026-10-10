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

/// 서식 도구 상자, a thin bar as Scrivener's and TextEdit's: style, font, size, character
/// styles with line shapes, colors, alignment, line spacing and lists, in macOS's own
/// controls. It observes only the document's format and context, so typing never rebuilds it.
struct FormatRow: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor
    /// The 언어 the font box shows and changes; nil for 대표 (all of them).
    @State private var language: Int?

    var body: some View {
        let context = document.context
        HStack(spacing: 6) {
            StyleField(document: document, editor: editor)
            Group {
                LanguageField(language: $language)
                FontField(document: document, editor: editor, language: language)
                SizeField(size: document.format?.text.size, editor: editor)
                RowDivider()
                CharacterButtons(document: document, editor: editor)
            }
            .disabled(!context.canFormat)
            RowDivider()
            Group {
                AlignmentButtons(document: document, editor: editor)
                RowDivider()
                SpacingField(paragraph: document.format?.paragraph, editor: editor)
                ListButtons(document: document, editor: editor)
            }
            .disabled(!context.canFormat)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    static func styles(_ document: HwpDocument, _ editor: PageEditor) -> [Choice?] {
        document.styles.map { style in
            Choice(title: style.name, on: style.id == document.format?.style) {
                document.applyStyle(style.id, editor.undoManager)
            }
        }
    }
}

/// 스타일 of the caret's paragraph, picked from the document's styles.
struct StyleField: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor
    var body: some View {
        Picker("스타일", selection: Binding(get: { document.format?.style }, set: { id in
            if let id { document.applyStyle(id, editor.undoManager) }
        })) {
            if document.format == nil { Text("스타일").tag(UInt32?.none) }
            ForEach(document.styles) { Text($0.name).tag(UInt32?.some($0.id)) }
        }
        .labelsHidden()
        .frame(width: 110)
        .help("스타일")
        .disabled(!document.context.canApplyStyle)
    }
}

/// The 언어 the font field shows and changes: 대표 (all) or one.
struct LanguageField: View {
    @Binding var language: Int?
    var body: some View {
        Picker("언어", selection: $language) {
            Text("대표").tag(Int?.none)
            ForEach(CharShapeSheet.languageNames.indices, id: \.self) { Text(CharShapeSheet.languageNames[$0]).tag(Int?.some($0)) }
        }
        .labelsHidden()
        .fixedSize()
        .help("언어")
    }
}

/// 글꼴 of `language`, picked from the installed families; a font that is not installed is shown as it is named.
struct FontField: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor
    let language: Int?
    var body: some View {
        let languages = document.format?.languages ?? []
        let font = language.flatMap { languages.indices.contains($0) ? languages[$0].font : nil } ?? document.format?.text.font
        let family = font.map { font in FormatChoices.families.first { $0.name == font || $0.family == font }?.family ?? font }
        Picker("글꼴", selection: Binding(get: { family ?? "" }, set: { editor.format(CharStyle(language: language, font: $0)) })) {
            if let family, !FormatChoices.families.contains(where: { $0.family == family }) { Text(family).tag(family) }
            if family == nil { Text("글꼴").tag("") }
            ForEach(FormatChoices.families, id: \.family) { Text($0.name).tag($0.family) }
        }
        .labelsHidden()
        .frame(width: 140)
        .help("글꼴")
    }
}

/// 진하게, 기울임, 밑줄 and 취소선, 밑줄 and 취소선 holding their line shapes and colors in
/// their menus, and 글자 색 and 형광펜.
struct CharacterButtons: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor
    var body: some View {
        let text = document.format?.text
        let styles: [(title: String, symbol: String, on: Bool?, toggle: () -> Void, menu: [Choice?])] = [
            ("진하게", "bold", text?.bold, editor.toggleBold, []),
            ("기울임", "italic", text?.italic, editor.toggleItalic, []),
            ("밑줄", "underline", text?.underline, editor.toggleUnderline,
             lines("밑줄 색", { CharStyle(underline: true, underlineShape: $0) }, { CharStyle(underline: true, underlineColor: $0) })),
            ("취소선", "strikethrough", text?.strikethrough, editor.toggleStrikethrough,
             lines("취소선 색", { CharStyle(strikethrough: true, strikeShape: $0) }, { CharStyle(strikethrough: true, strikeColor: $0) })),
        ]
        Segments(segments: styles.map { .init(symbol: $0.symbol, help: $0.title, menu: $0.menu) }, on: styles.map { $0.on == true }, any: true) {
            styles[$0].toggle()
        }
        .fixedSize()
        ColorPicker("글자 색", selection: color(text?.color ?? "#000000") { editor.format(CharStyle(color: $0)) }, supportsOpacity: false)
            .labelsHidden()
            .help("글자 색")
        ColorPicker("형광펜", selection: color(text?.shade ?? FormatChoices.none) { editor.format(CharStyle(shade: $0)) }, supportsOpacity: false)
            .labelsHidden()
            .help("형광펜")
    }

    /// Line shapes for underline or strikethrough, drawn as in the web editor, and the line's colors.
    private func lines(_ colorTitle: String, _ shape: @escaping (Int) -> CharStyle,
                       _ color: @escaping (String) -> CharStyle) -> [Choice?] {
        LineShapes.names.indices.map { index in Choice(title: "", image: LineShapes.images[index]) { editor.format(shape(index)) } }
            + [nil, Choice(title: colorTitle, symbol: "paintbrush.pointed", submenu: FormatChoices.colors.map { hex in
                Choice(title: "", image: FormatChoices.swatch(hex)) { editor.format(color(hex)) }
            })]
    }
    private func color(_ hex: String, set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { HexColor.color(hex) }, set: { set(HexColor.hex($0)) })
    }
}

/// The paragraph alignments, the caret's picked.
struct AlignmentButtons: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor
    var body: some View {
        Segments(Alignment.allCases.map(Optional.some),
                 selection: Binding(get: { document.format?.paragraph.alignment }, set: { if let alignment = $0 { editor.format(ParaStyle(alignment: alignment)) } })) {
            let label = FormatChoices.label($0!)
            return .init(symbol: label.symbol, help: label.title)
        }
        .fixedSize()
    }
}

/// 글머리표 and 문단 번호, each turned on or off, its shapes in its menu.
struct ListButtons: View {
    @ObservedObject var document: HwpDocument
    let editor: PageEditor
    var body: some View {
        let head = document.format?.paragraph.head
        let bullets = FormatChoices.bullets.map { bullet in Choice(title: bullet) { editor.format(ParaStyle(head: "Bullet", bullet: bullet)) } }
        let numberings = FormatChoices.numberings.indices.map { kind in
            Choice(title: FormatChoices.numberings[kind].joined(separator: " ")) { editor.format(ParaStyle(head: "Number", numbering: kind)) }
        }
        Segments(segments: [.init(symbol: Icon.bullets, help: "글머리표", menu: bullets), .init(symbol: Icon.numbering, help: "문단 번호", menu: numberings)],
                 on: [head == "Bullet", head == "Number"], any: true) {
            MenuItems.toggleList(editor, head: head, bullet: $0 == 0)
        }
        .fixedSize()
    }
}

/// The size in points: typed, stepped by one, or picked.
struct SizeField: View {
    let size: Double?
    let editor: PageEditor
    var body: some View {
        HStack(spacing: 2) {
            ComboField(value: size.map(Self.label) ?? "", items: FormatChoices.sizes.map(Self.label)) { text in
                if let value = Double(text), value != size { editor.format(CharStyle(size: min(max(value, 1), 4096))) }
            }
            .frame(width: 58)
            Text("pt").foregroundStyle(.secondary)
            Stepper("글자 크기", onIncrement: { editor.stepFontSize(by: 1) }, onDecrement: { editor.stepFontSize(by: -1) })
                .labelsHidden()
        }
        .help("글자 크기")
    }
    private static func label(_ size: Double) -> String {
        size.rounded() == size ? "\(Int(size))" : String(format: "%.1f", size)
    }
}

/// 줄 간격: the value of the caret's paragraph, typed or picked as a percentage.
struct SpacingField: View {
    let paragraph: ParaStyle?
    let editor: PageEditor
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up.and.down.text.horizontal").foregroundStyle(.secondary)
            ComboField(value: paragraph?.lineSpacing.map(Self.label) ?? "", items: FormatChoices.lineSpacings.map(Self.label)) { text in
                if let value = Double(text), value != paragraph?.lineSpacing || paragraph?.lineSpacingKind != .percent {
                    editor.format(ParaStyle(lineSpacing: min(max(value, 50), 500), lineSpacingKind: .percent))
                }
            }
            .frame(width: 58)
            Text(paragraph?.lineSpacingKind == .percent || paragraph == nil ? "%" : "pt").foregroundStyle(.secondary)
        }
        .help("줄 간격")
    }
    private static func label(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
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
