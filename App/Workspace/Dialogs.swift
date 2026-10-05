import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

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
    /// Asks for an image file and puts it at the caret.
    func insertPicture() {
        guard document?.selection != nil else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return NSSound.beep() }
            document?.insertPicture(data, name: url.lastPathComponent, undoManager)
        }
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
    @State private var rows = 5.0
    @State private var columns = 5.0

    var body: some View {
        DialogFrame {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { FieldLabel("줄 개수"); SpinField(value: $rows, unit: "", range: 1...1000) }
                GridRow { FieldLabel("칸 개수"); SpinField(value: $columns, unit: "", range: 1...256) }
            }
        } confirm: {
            viewer.insertTable(rows: Int(rows), columns: Int(columns))
            dismiss()
        }
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

    var body: some View {
        DialogFrame {
            VStack(alignment: .leading, spacing: 14) {
                GroupTitle("용지 종류")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        FieldLabel("종류")
                        Picker("종류", selection: paper) {
                            ForEach(Self.papers, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                            Text("사용자 정의").tag(String?.none)
                        }
                        .labelsHidden()
                        .fixedSize()
                        FieldLabel("용지 방향")
                        Picker("용지 방향", selection: $page.landscape) {
                            Text("세로").tag(false)
                            Text("가로").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow { field("폭", \.width); field("길이", \.height) }
                }
                .padding(.leading, 12)
                GroupTitle("용지 여백")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { field("위쪽", \.marginTop); field("아래쪽", \.marginBottom) }
                    GridRow { field("왼쪽", \.marginLeft); field("오른쪽", \.marginRight) }
                    GridRow { field("머리말", \.marginHeader); field("꼬리말", \.marginFooter) }
                    GridRow { field("제본", \.marginGutter) }
                }
                .padding(.leading, 12)
            }
        } confirm: {
            viewer.setPage(page, section: section)
            dismiss()
        }
    }

    /// The named paper matching the size within half a millimeter.
    private var paper: Binding<String?> {
        Binding {
            let size = (Units.millimeters(page.width), Units.millimeters(page.height))
            return Self.papers.first { abs($0.width - size.0) < 0.5 && abs($0.height - size.1) < 0.5 }?.name
        } set: { name in
            guard let paper = Self.papers.first(where: { $0.name == name }) else { return }
            page.width = Units.units(paper.width)
            page.height = Units.units(paper.height)
        }
    }
    @ViewBuilder private func field(_ title: String, _ key: WritableKeyPath<PageSetup, UInt32>) -> some View {
        FieldLabel(title)
        SpinField(value: Binding { Units.millimeters(page[keyPath: key]) } set: { page[keyPath: key] = Units.units($0) },
                  unit: "mm", range: 0...1000)
    }
}

extension HwpDocument {
    /// Puts an image at the caret in the body, at its own size up to the text width, in
    /// the line like a character. PNG and JPEG go in as they are; other images as PNG, or
    /// as JPEG when they would not fit the engine's 5 MB.
    func insertPicture(_ data: Data, name: String, _ undoManager: UndoManager?) {
        guard let position = selection?.ordered.start, position.target.cell == nil, position.target.note == nil,
              let picture = Picture(data)
        else { return NSSound.beep() }
        Task {
            let page = try? await pageSetup(section: position.target.section)
            let pixels = Double(picture.width) * 75
            let text = page.map { Double(($0.landscape ? $0.height : $0.width) - $0.marginLeft - $0.marginRight - $0.marginGutter) }
            let scale = min(1, (text ?? pixels) / pixels)
            edit(undoManager) { _ in
                .insertPicture(position, data: picture.data, width: UInt32(max(1, (pixels * scale).rounded())),
                               height: UInt32(max(1, (Double(picture.height) * 75 * scale).rounded())),
                               naturalWidth: picture.width, naturalHeight: picture.height,
                               extension: picture.ext, description: name)
            }
        }
    }
}

/// An image as the engine embeds it.
private struct Picture {
    let data: Data, ext: String, width: UInt32, height: UInt32
    private static let limit = 5 * 1024 * 1024

    init?(_ original: Data) {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              (1...20_000).contains(image.width), (1...20_000).contains(image.height),
              image.width * image.height <= 100_000_000
        else { return nil }
        (width, height) = (UInt32(image.width), UInt32(image.height))
        if (type == .png || type == .jpeg), original.count <= Self.limit {
            (data, ext) = (original, type == .png ? "png" : "jpg")
        } else if let png = Self.encode(image, as: .png), png.count <= Self.limit {
            (data, ext) = (png, "png")
        } else if let jpeg = Self.encode(image, as: .jpeg), jpeg.count <= Self.limit {
            (data, ext) = (jpeg, "jpg")
        } else {
            return nil
        }
    }
    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
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

    /// A sample of each shape, as the web editor's menus show them.
    static let images: [NSImage] = names.indices.map { shape in
        let image = NSImage(size: NSSize(width: 64, height: 10), flipped: true) { rect in
            NSColor.black.set()
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

/// 글자 모양, laid out like the web editor's: 기본 (size, per-language settings,
/// attributes, colors) and 확장 (line shapes and colors). Only changed attributes apply.
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
        DialogFrame {
            TabView {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledField("기준 크기") { SpinField(value: value(\.size, 10), unit: "pt", range: 1...4096) }
                    GroupTitle("언어별 설정")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("글꼴")
                            Picker("글꼴", selection: value(\.font, "")) {
                                ForEach(FormatChoices.families, id: \.family) { Text($0.name).tag($0.family) }
                                if let font = original.font, !FormatChoices.families.contains(where: { $0.family == font }) {
                                    Text(font).tag(font)
                                }
                            }
                            .labelsHidden()
                            .gridCellColumns(3)
                        }
                        GridRow {
                            FieldLabel("장평")
                            SpinField(value: value(\.ratio, 100), unit: "%", range: 50...200)
                            FieldLabel("자간")
                            SpinField(value: value(\.spacing, 0), unit: "%", range: -50...50)
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
                        attribute("위 첨자", \.superscript) { Image(systemName: "textformat.superscript") }
                        attribute("아래 첨자", \.`subscript`) { Image(systemName: "textformat.subscript") }
                    }
                    .padding(.leading, 12)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("글자 색")
                            ColorWell(hex: value(\.color, "#000000"))
                            FieldLabel("음영 색")
                            ColorWell(hex: value(\.shade, "#ffffff"), none: "#ffffff")
                        }
                    }
                    .padding(.leading, 12)
                }
                .padding(16)
                .tabItem { Text("기본") }
                VStack(alignment: .leading, spacing: 14) {
                    line("밑줄", shape: \.underlineShape, color: \.underlineColor)
                    line("취소선", shape: \.strikeShape, color: \.strikeColor)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .tabItem { Text("확장") }
            }
        } confirm: {
            viewer.applyCharShape(style.changes(from: original))
            dismiss()
        }
    }

    private func value<T>(_ key: WritableKeyPath<CharStyle, T?>, _ fallback: T) -> Binding<T> {
        Binding { style[keyPath: key] ?? fallback } set: { style[keyPath: key] = $0 }
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
        .buttonStyle(ToolButtonStyle(on: on))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        .help(title)
        .accessibilityLabel(title)
    }
    private func line(_ title: String, shape: WritableKeyPath<CharStyle, Int?>,
                      color: WritableKeyPath<CharStyle, String?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupTitle(title)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    FieldLabel("모양")
                    Picker("모양", selection: value(shape, 0)) {
                        ForEach(LineShapes.names.indices, id: \.self) { index in
                            Image(nsImage: LineShapes.images[index]).accessibilityLabel(LineShapes.names[index]).tag(index)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    FieldLabel("색")
                    ColorWell(hex: value(color, "#000000"))
                }
            }
            .padding(.leading, 12)
        }
    }
}

/// 문단 모양, laid out like the web editor's: 기본 (alignment, margins, first line,
/// spacing) and 확장 (page-break rules). Only changed attributes apply.
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
        DialogFrame {
            TabView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupTitle("정렬 방식")
                    HStack(spacing: 6) {
                        ForEach(Alignment.allCases, id: \.self) { alignment in
                            let label = FormatChoices.label(alignment)
                            Button { style.alignment = alignment } label: {
                                Image(systemName: label.symbol).font(.system(size: 15, weight: .light)).frame(width: 32, height: 32)
                            }
                            .buttonStyle(ToolButtonStyle(on: (style.alignment ?? .justify) == alignment))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
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
                            .labelsHidden()
                            .fixedSize()
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
                }
                .padding(16)
                .tabItem { Text("기본") }
                VStack(alignment: .leading, spacing: 8) {
                    GroupTitle("기타")
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("외톨이줄 보호", isOn: flag(\.widowOrphan))
                        Toggle("다음 문단과 함께", isOn: flag(\.keepWithNext))
                        Toggle("문단 보호", isOn: flag(\.keepLines))
                        Toggle("문단 앞에서 항상 쪽 나눔", isOn: flag(\.pageBreakBefore))
                    }
                    .padding(.leading, 12)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tabItem { Text("확장") }
            }
        } confirm: {
            var change = style.changes(from: original)
            // The engine reads a line spacing by its kind, so they go together.
            if change.lineSpacing != nil || change.lineSpacingKind != nil {
                (change.lineSpacing, change.lineSpacingKind) = (style.lineSpacing, style.lineSpacingKind)
            }
            viewer.applyParaShape(change)
            dismiss()
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
    private func flag(_ key: WritableKeyPath<ParaStyle, Bool?>) -> Binding<Bool> {
        Binding { style[keyPath: key] ?? false } set: { style[keyPath: key] = $0 }
    }
}

// MARK: Dialog parts, after the web editor's dialogs

/// A dialog's content above 취소 and 확인.
struct DialogFrame<Content: View>: View {
    @ViewBuilder let content: Content
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            content
            HStack {
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("확인", action: confirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .fixedSize()
    }
}

/// A group's name.
struct GroupTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).font(.callout.weight(.semibold)) }
}

/// A field's name in a grid.
struct FieldLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).gridColumnAlignment(.trailing) }
}

/// A named field outside a grid.
struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { (self.title, self.content) = (title, content()) }
    var body: some View { HStack(spacing: 10) { Text(title); content } }
}

/// A number with its unit and step arrows in a box, clamped to `range`.
struct SpinField: View {
    @Binding var value: Double
    let unit: String
    let range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: Binding { value } set: { value = min(max($0, range.lowerBound), range.upperBound) },
                      format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.plain)
                .monospacedDigit()
                .frame(width: 56)
            Text(unit).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .leading).fixedSize()
            VStack(spacing: 0) {
                StepArrow(symbol: "chevron.up") { value = min(value + 1, range.upperBound) }
                StepArrow(symbol: "chevron.down") { value = max(value - 1, range.lowerBound) }
            }
        }
        .padding(.leading, 6)
        .fieldBox()
    }
}

/// A color in a box that opens the system color panel; `none` offers to clear it.
struct ColorWell: View {
    @Binding var hex: String
    var none: String?
    var body: some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: Binding { HexColor.color(hex) } set: { hex = HexColor.hex($0) }, supportsOpacity: false)
                .labelsHidden()
            if let none, hex != none {
                Button("없음") { hex = none }.buttonStyle(.borderless)
            }
        }
    }
}
