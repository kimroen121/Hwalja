import AppKit
import SwiftUI

// MARK: Keynote's inspector parts

/// The inspector's groups one under another, scrolling, with rows spread across it.
/// `fixed`, as tall as its groups and not scrolling: for what stays over the groups that do.
/// Its controls are in a scroll view all the same: out of one, macOS gives a segmented control
/// the toolbar's look, without the accent color.
struct InspectorScroll<Content: View>: View {
    var fixed = false
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
        }
        .scrollDisabled(fixed)
        .fixedSize(horizontal: false, vertical: fixed)
        .labeledContentStyle(RowStyle())
        .disclosureGroupStyle(GroupDisclosure())
        .buttonBorderShape(.roundedRectangle)
    }
}

/// A group: its title in bold over its controls, and a line under it.
struct InspectorSection<Header: View, Content: View, Footer: View>: View {
    let header: Header
    let content: Content
    let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.font(.headline.weight(.semibold))
            content
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 16) }
    }
}
extension InspectorSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { (header, self.content, footer) = (EmptyView(), content(), EmptyView()) }
}
extension InspectorSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { (header, self.content, footer) = (Text(title), content(), EmptyView()) }
}
extension InspectorSection where Header == Text {
    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        (header, self.content, self.footer) = (Text(title), content(), footer())
    }
}
extension InspectorSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        (header, self.content, self.footer) = (EmptyView(), content(), footer())
    }
}
extension InspectorSection {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        (self.header, self.content, self.footer) = (header(), content(), footer())
    }
}

/// A group that folds: its title row with the chevron opens and closes it, with
/// no more room around it than a group that does not fold.
struct GroupDisclosure: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                configuration.label
            }
            .contentShape(Rectangle())
            .onTapGesture { configuration.isExpanded.toggle() }
            if configuration.isExpanded { configuration.content }
        }
    }
}

/// A label at the leading edge and its control at the trailing one.
struct RowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

/// Commands as tiles, two to a row.
struct Tiles<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) { content }
            .flexibleButtons()
    }
}

/// A tile's face: a large icon over the name.
struct TileLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 19)).frame(height: 22)
            Text(title).lineLimit(2).multilineTextAlignment(.center).font(.callout)
        }
        .frame(maxWidth: .infinity, minHeight: 66)
        .padding(.horizontal, 4)
    }
}

/// `Choice`s as buttons in sight, two to a row (or `columns`), in place of a menu.
struct ChoiceButtons: View {
    let items: [Choice?]
    var columns = 2
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(items.compactMap { $0 }.indices, id: \.self) { index in
                let item = items.compactMap { $0 }[index]
                Button(action: item.action) {
                    HStack(spacing: 6) {
                        if let image = item.image { Image(nsImage: image) } else if let symbol = item.symbol { Image(systemName: symbol) }
                        if !item.title.isEmpty { Text(item.title).lineLimit(1).minimumScaleFactor(0.75) }
                    }
                }
                .disabled(!item.enabled)
                .help(item.title)
            }
        }
        .flexibleButtons()
    }
}

extension View {
    /// A checkbox before its name, as Keynote's, not spread as the inspector's rows are.
    func checkbox() -> some View { toggleStyle(.checkbox).labeledContentStyle(.automatic) }
    /// The pointing hand over a control, as a link's.
    @ViewBuilder func pointing() -> some View {
        if #available(macOS 15, *) { pointerStyle(.link) } else { self }
    }
    /// Buttons and pop-ups as wide as their place, as macOS 26 sizes them; fitted before it.
    @ViewBuilder func flexibleButtons() -> some View {
        if #available(macOS 26, *) { buttonSizing(.flexible) } else { self }
    }
}

/// The dialogs a group leads to: buttons as wide as the inspector, one under another, as Keynote's.
struct DialogButtons<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 8) { content }
            .controlSize(.large)
            .flexibleButtons()
    }
}

/// A choice whose rows show under it only while it is on (밑줄, 취소선, 테두리): then its
/// name is bold, as a group's title, and the group stands apart from the rows around it.
struct OpeningRows<Choice: View, Rows: View>: View {
    let title: String
    let open: Bool
    @ViewBuilder let choice: Choice
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent { choice } label: { Text(title).fontWeight(open ? .semibold : .regular) }
            if open { rows }
        }
        .padding(.vertical, open ? 6 : 0)
    }
}

/// Rows used less, folded under their name as Pages's 여백 and 들여쓰기: a group's title, or a
/// row's name within a group.
struct Fold<Content: View>: View {
    let title: String
    var headline = true
    @ViewBuilder let content: Content
    init(_ title: String, headline: Bool = true, @ViewBuilder content: () -> Content) {
        (self.title, self.headline, self.content) = (title, headline, content())
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { content }
        } label: { Text(title).font(headline ? .headline.weight(.semibold) : .body) }
    }
}

/// Four lengths as 용지 여백's: 위쪽 and 아래쪽 over 왼쪽 and 오른쪽, each named under it.
/// `field` takes them in HWP's order: 왼쪽, 오른쪽, 위쪽, 아래쪽.
struct Sides<Field: View>: View {
    @ViewBuilder let field: (Int) -> Field
    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach([2, 0], id: \.self) { row in
                GridRow {
                    ForEach(row..<row + 2, id: \.self) { i in
                        VStack(spacing: 3) {
                            field(i)
                            Text(["왼쪽", "오른쪽", "위쪽", "아래쪽"][i]).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

/// A number typed or stepped, with its unit; it applies on Return or a step.
struct NumberStepper: View {
    let value: Double?
    let unit: String
    let range: ClosedRange<Double>
    var step: Double = 1
    /// As wide as its place, rather than a number's width.
    var wide = false
    let apply: (Double) -> Void
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: wide ? nil : 48)
                .frame(maxWidth: wide ? .infinity : nil)
                .onSubmit { Double(text).map { apply(min(max($0, range.lowerBound), range.upperBound)) } }
            Text(unit).foregroundStyle(.secondary)
            Stepper("", onIncrement: { apply(min((value ?? range.lowerBound) + step, range.upperBound)) },
                    onDecrement: { apply(max((value ?? range.lowerBound) - step, range.lowerBound)) })
                .labelsHidden()
        }
        .onAppear { text = Self.label(value) }
        .onChange(of: value) { text = Self.label(value) }
    }
    private static func label(_ value: Double?) -> String {
        guard let value else { return "" }
        // Two places, for widths such as 0.12 mm.
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

/// 밝기 or 대비 of a picture, applied when the slider is let go.
struct PictureSlider: View {
    let title: String
    let value: Int32?
    let apply: (Int32) -> Void
    @State private var shown = 0.0
    var body: some View {
        // As Pages's: the name over the slider, the number beside it.
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            HStack(spacing: 8) {
                Slider(value: $shown, in: -100...100, step: 5) { editing in
                    if !editing, Int32(shown) != value { apply(Int32(shown)) }
                }
                NumberStepper(value: value.map(Double.init), unit: "%", range: -100...100, step: 5) { apply(Int32($0)) }
            }
        }
        .onAppear { shown = Double(value ?? 0) }
        .onChange(of: value) { shown = Double(value ?? 0) }
    }
}

/// A line's 종류, 색 and 굵기, each on its own line; or only 색 and 굵기 side by side, the
/// kind shown beside a title.
struct LineRow: View {
    @Binding var line: BorderSide
    var stacked = false
    var body: some View {
        let color = ColorWell(hex: $line.color, flexible: true)
        let width = ChoiceField(Binding { Int(line.width) } set: { line.width = UInt8($0) },
                                Swatches.widths.indices.map { ($0, "") }, images: Swatches.widthImages, flexible: true)
        if stacked {
            VStack(alignment: .leading, spacing: 8) { Self.kind($line, flexible: true); color; width }
        } else {
            HStack(spacing: 8) { color; width }
        }
    }
    static func kind(_ line: Binding<BorderSide>, flexible: Bool = false) -> some View {
        ChoiceField(Binding { Int(line.wrappedValue.line) } set: { line.wrappedValue.line = UInt8($0) },
                    Swatches.lineKinds.indices.map { ($0, "") }, images: Swatches.lineKinds, flexible: flexible)
    }
}

/// The sides a line goes on, as Pages's: buttons in one box, the ones last chosen marked.
struct SideButtons: View {
    let rows: [[(title: String, sides: [Int])]]
    let chosen: [Int]
    let pick: ([Int]) -> Void
    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.title) { title, sides in
                        Button { pick(sides) } label: { SideIcon(sides: sides) }
                            .buttonStyle(.borderless)
                            .background(chosen == sides ? Color.secondary.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .help(title)
                            .accessibilityLabel(title)
                    }
                }
            }
        }
        // In one box, as Pages's.
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .fixedSize()
    }
}

/// A 대각선 or 중심선 button's picture: its lines across a cell.
struct DiagonalIcon: View {
    let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)]
    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            context.stroke(Path(box), with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            for (x1, y1, x2, y2) in lines {
                context.stroke(Path {
                    $0.move(to: CGPoint(x: box.minX + x1 * box.width, y: box.minY + y1 * box.height))
                    $0.addLine(to: CGPoint(x: box.minX + x2 * box.width, y: box.minY + y2 * box.height))
                }, with: .color(.primary), lineWidth: 2)
            }
        }
        .frame(width: 22, height: 22)
        .padding(3)
    }
}

/// 채우기 as Pages's: its kind beside the title, the kind's rows under it: 색 with 무늬, and for
/// 셀·표 배경 a 그러데이션 or a 그림. A fill shown as none of them (a page's 그러데이션) stays
/// until a kind is chosen.
struct FillRows: View {
    let title: String
    let fill: PageFill?
    var extended = false
    let apply: (PageFill) -> Void

    /// 그림 채우기 유형, in the engine's order.
    private static let modes = ["바둑판식으로-모두", "바둑판식으로-가로/위", "바둑판식으로-가로/아래", "바둑판식으로-세로/왼쪽",
                                "바둑판식으로-세로/오른쪽", "크기에 맞추어", "가운데로", "가운데 위로", "가운데 아래로",
                                "왼쪽 가운데로", "왼쪽 위로", "왼쪽 아래로", "오른쪽 가운데로", "오른쪽 위로", "오른쪽 아래로"]
    /// 0 없음, 1 색, 2 그러데이션, 3 그림; -1 for none of them.
    private var kind: Int { Self.kind(fill) }
    static func kind(_ fill: PageFill?) -> Int {
        guard let fill else { return -1 }
        if fill.gradient != nil { return 2 }
        if fill.image != nil { return 3 }
        return fill.color == "none" && fill.pattern == 0 ? 0 : 1
    }
    private var base: PageFill { fill ?? PageFill(color: "none", patternColor: "#000000", pattern: 0) }

    var body: some View {
        OpeningRows(title: title, open: kind > 0) {
            Picker(title, selection: Binding { kind } set: { choose($0) }) {
                if kind < 0 { Text("").tag(-1) }
                Text("없음").tag(0)
                Text("색").tag(1)
                if extended {
                    Text("그러데이션").tag(2)
                    Text("그림").tag(3)
                }
            }
            .labelsHidden()
            .fixedSize()
        } rows: {
            switch kind {
            case 1: colorRows
            case 2: gradientRows
            case 3: imageRows
            default: EmptyView()
            }
        }
    }
    private func choose(_ kind: Int) {
        var new = base
        (new.gradient, new.image) = (nil, nil)
        switch kind {
        case 0: (new.color, new.pattern) = ("none", 0)
        case 2: new.gradient = Gradient()
        case 3: return pickImage()
        default: if new.color == "none" { new.color = "#ffffff" }
        }
        apply(new)
    }
    private func change(_ edit: (inout PageFill) -> Void) {
        var new = base
        edit(&new)
        if new != fill { apply(new) }
    }
    @ViewBuilder private var colorRows: some View {
        LabeledContent("면 색") {
            ColorWell(hex: Binding { base.color == "none" ? "#ffffff" : base.color } set: { color in change { $0.color = color } })
        }
        LabeledContent("무늬") {
            HStack(spacing: 8) {
                ChoiceField(Binding { Int(base.pattern) } set: { pattern in change { $0.pattern = UInt8(pattern) } },
                            Swatches.patterns.indices.map { ($0, "") }, images: Swatches.patterns)
                ColorWell(hex: Binding { base.patternColor } set: { color in change { $0.patternColor = color } })
            }
        }
    }
    @ViewBuilder private var gradientRows: some View {
        let g = base.gradient ?? Gradient()
        let set = { (edit: (inout Gradient) -> Void) in change { fill in
            var new = g
            edit(&new)
            fill.gradient = new
        } }
        LabeledContent("모양") {
            Picker("모양", selection: Binding { g.kind } set: { kind in set { $0.kind = kind } }) {
                Text("줄무늬").tag(UInt8(1)); Text("원형").tag(UInt8(2)); Text("원뿔형").tag(UInt8(3)); Text("사각형").tag(UInt8(4))
            }
            .labelsHidden()
            .fixedSize()
        }
        HStack(spacing: 8) {
            ForEach(0..<2) { i in
                VStack(spacing: 3) {
                    ColorWell(hex: Binding { g.colors[i] } set: { color in set { $0.colors[i] = color } }, flexible: true)
                    Text(i == 0 ? "시작 색" : "끝 색").font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
        }
        LabeledContent("기울임") {
            NumberStepper(value: Double(g.angle), unit: "°", range: 0...359) { angle in set { $0.angle = Int16(angle) } }
        }
        LabeledContent("가로 중심") {
            NumberStepper(value: Double(g.centerX), unit: "%", range: 0...100) { x in set { $0.centerX = Int16(x) } }
        }
        LabeledContent("세로 중심") {
            NumberStepper(value: Double(g.centerY), unit: "%", range: 0...100) { y in set { $0.centerY = Int16(y) } }
        }
        LabeledContent("번짐 정도") {
            NumberStepper(value: Double(g.blur), unit: "", range: 0...255) { blur in set { $0.blur = UInt8(blur) } }
        }
        LabeledContent("번짐 중심") {
            NumberStepper(value: Double(g.stepCenter), unit: "", range: 0...100) { center in set { $0.stepCenter = UInt8(center) } }
        }
    }
    @ViewBuilder private var imageRows: some View {
        let i = base.image ?? ImageBrush()
        let set = { (edit: (inout ImageBrush) -> Void) in change { fill in
            var new = i
            edit(&new)
            fill.image = new
        } }
        Button("그림 선택…") { pickImage() }.flexibleButtons()
        LabeledContent("채우기 유형") {
            Picker("채우기 유형", selection: Binding { Int(i.mode) } set: { mode in set { $0.mode = UInt8(mode) } }) {
                ForEach(Self.modes.indices, id: \.self) { Text(Self.modes[$0]).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        LabeledContent("그림 효과") {
            Picker("그림 효과", selection: Binding { i.effect } set: { effect in set { $0.effect = effect } }) {
                Text("원래 그림").tag(UInt8(0)); Text("회색조").tag(UInt8(1)); Text("흑백").tag(UInt8(2))
            }
            .labelsHidden()
            .fixedSize()
        }
        LabeledContent("밝기") {
            NumberStepper(value: Double(i.brightness), unit: "%", range: -100...100) { value in set { $0.brightness = Int8(value) } }
        }
        LabeledContent("대비") {
            NumberStepper(value: Double(i.contrast), unit: "%", range: -100...100) { value in set { $0.contrast = Int8(value) } }
        }
        Toggle("워터마크 효과", isOn: Binding { i.brightness == 70 && i.contrast == -50 } set: { on in
            set { ($0.brightness, $0.contrast) = on ? (70, -50) : (0, 0) }
        })
        .checkbox()
    }
    /// 그림 선택: an image file for the 배경, kept in the document.
    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        var new = base
        new.gradient = nil
        var image = new.image ?? ImageBrush()
        (image.data, image.extension, image.binId) = (data, url.pathExtension.lowercased(), 0)
        new.image = image
        apply(new)
    }
}

/// 회전 as Pages's: a round slider, its knob at the angle.
struct RotationDial: NSViewRepresentable {
    let angle: Double?
    let apply: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let dial = NSSlider(value: 0, minValue: 0, maxValue: 360, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        dial.sliderType = .circular
        // Applied when let go: each change is one edit to undo.
        dial.isContinuous = false
        return dial
    }
    func updateNSView(_ dial: NSSlider, context: Context) {
        context.coordinator.apply = apply
        dial.isEnabled = context.environment.isEnabled
        if let angle, dial.doubleValue != angle { dial.doubleValue = angle }
    }
    func makeCoordinator() -> Coordinator { Coordinator(apply: apply) }
    @MainActor final class Coordinator: NSObject {
        var apply: (Double) -> Void
        init(apply: @escaping (Double) -> Void) { self.apply = apply }
        @objc func changed(_ dial: NSSlider) { apply(dial.doubleValue.rounded().truncatingRemainder(dividingBy: 360)) }
    }
}

/// 셀's 투명 선.
struct TransparentLinesToggle: View {
    @ObservedObject var viewer: Viewer
    var body: some View {
        Toggle("투명 선", isOn: $viewer.showsTransparentLines).checkbox()
    }
}
