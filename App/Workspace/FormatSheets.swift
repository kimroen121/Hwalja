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
        DialogFrame("글자 모양") {
            TabView {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledField("기준 크기") { SpinField(value: value(\.size, 10), unit: "pt", range: 1...4096) }
                    GroupTitle("언어별 설정")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            FieldLabel("글꼴")
                            ChoiceField(value(\.font, ""), fonts, minWidth: 200)
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
            .dialogTabs()
        } confirm: {
            viewer.applyCharShape(style.changes(from: original))
            dismiss()
        }
    }

    private func value<T>(_ key: WritableKeyPath<CharStyle, T?>, _ fallback: T) -> Binding<T> {
        Binding { style[keyPath: key] ?? fallback } set: { style[keyPath: key] = $0 }
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
                    ChoiceField(value(shape, 0), LineShapes.names.indices.map { ($0, LineShapes.names[$0]) },
                                images: LineShapes.images)
                    FieldLabel("색")
                    ColorWell(hex: value(color, "#000000"))
                }
            }
            .padding(.leading, 12)
        }
    }
}

/// 문단 모양, laid out like the web editor's 기본 tab: alignment, margins, first line,
/// spacing and line breaking. Only changed attributes apply.
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
        DialogFrame("문단 모양") {
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
                        ChoiceField(unit(\.koreanBreakUnit, 1), [(1, "글자"), (0, "어절")])
                    }
                    GridRow {
                        FieldLabel("영문 단위")
                        ChoiceField(unit(\.englishBreakUnit, 0), [(0, "단어"), (1, "하이픈"), (2, "글자")])
                    }
                }
                .padding(.leading, 12)
            }
            .dialogTabs()
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
    private func unit(_ key: WritableKeyPath<ParaStyle, Int?>, _ fallback: Int) -> Binding<Int> {
        Binding { style[keyPath: key] ?? fallback } set: { style[keyPath: key] = $0 }
    }
}
