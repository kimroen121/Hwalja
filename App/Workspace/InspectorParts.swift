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
            header.font(.headline.weight(.medium))
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
                    .font(.caption.weight(.medium))
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
            LabeledContent { choice } label: { Text(title).fontWeight(open ? .medium : .regular) }
            if open { rows }
        }
        .padding(.vertical, open ? 6 : 0)
    }
}

/// Rows used less, folded under their name as Pages's 여백 and 들여쓰기: a group's title, or a
/// row's name within a group; `trailing` beside the name stays in sight while folded, as the
/// 텍스트 탭's 간격 keeps its value.
struct Fold<Content: View, Trailing: View>: View {
    let title: String
    var headline = true
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing
    /// Open or closed as last left, as Pages keeps them.
    @AppStorage private var open: Bool
    init(_ title: String, headline: Bool = true, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        (self.title, self.headline, self.content, self.trailing) = (title, headline, content(), trailing())
        _open = AppStorage(wrappedValue: false, Fold<EmptyView, EmptyView>.key(title))
    }
    static func key(_ title: String) -> String { "fold." + title }
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 10) { content }
        } label: {
            HStack {
                Text(title).font(headline ? .headline.weight(.medium) : .body)
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}
extension Fold where Trailing == EmptyView {
    init(_ title: String, headline: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title, headline: headline, content: content) { EmptyView() }
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
    /// The field's width when not `wide`.
    var width: CGFloat = 48
    /// The unit in the field after the number, as Pages's 1pt, where room is short.
    var unitInside = false
    let apply: (Double) -> Void
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: wide ? nil : width)
                .frame(maxWidth: wide ? .infinity : nil)
                .onSubmit {
                    let number = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
                    Double(number).map { apply(min(max($0, range.lowerBound), range.upperBound)) }
                }
            if !unitInside { Text(unit).foregroundStyle(.secondary) }
            Stepper("", onIncrement: { apply(min((value ?? range.lowerBound) + step, range.upperBound)) },
                    onDecrement: { apply(max((value ?? range.lowerBound) - step, range.lowerBound)) })
                .labelsHidden()
        }
        .onAppear { text = label }
        .onChange(of: value) { text = label }
    }
    private var label: String {
        guard let value else { return "" }
        // Two places, for widths such as 0.12 mm.
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) + (unitInside ? unit : "")
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

/// A line's 종류, 색 and 굵기, as Pages's: in one row, the kind widest; or `stacked` beside a
/// grid of sides, one under another.
struct LineRow: View {
    @Binding var line: BorderSide
    var stacked = false
    var body: some View {
        let kind = LineKindField(kind: Binding { Int(line.line) } set: { line.line = UInt8($0) })
        if stacked {
            // A row each, beside the grid's three, as wide as their place.
            VStack(alignment: .leading, spacing: 6) {
                kind
                ColorWell(hex: $line.color, wide: true)
                Self.width(Int(line.width), wide: true) { line.width = UInt8($0) }
            }
        } else {
            HStack(spacing: 8) { kind; ColorWell(hex: $line.color); Self.width(Int(line.width)) { line.width = UInt8($0) } }
        }
    }
    /// 굵기 typed in points, its unit in the field, a step moving along HWP's widths; `apply`
    /// takes the width's number.
    static func width(_ index: Int, wide: Bool = false, apply: @escaping (Int) -> Void) -> NumberStepper {
        let now = min(max(index, 0), Swatches.widths.count - 1), points = Swatches.widthPoints
        return NumberStepper(value: points[now], unit: "pt", range: points.first!...points.last!, step: Swatches.widthStep,
                             wide: wide, width: 58, unitInside: true) { apply(Swatches.widthIndex($0, from: now, in: points)) }
    }
}

/// 테두리 종류 as a pop-up as wide as its place, each line drawn across it, as Pages's.
struct LineKindField: View {
    @Binding var kind: Int
    /// The kinds offered: all, or the first of them.
    var count = Swatches.lineKinds.count
    @State private var images = Swatches.lineKinds(width: 24)
    var body: some View {
        ChoiceField($kind, (0..<count).map { ($0, "") }, images: Array(images.prefix(count)), flexible: true)
            .frame(maxWidth: .infinity)
            .background {
                // The line runs up to the pop-up's arrows.
                GeometryReader { geometry in
                    let width = max(24, (geometry.size.width - 48).rounded())
                    Color.clear
                        .onAppear { draw(width) }
                        .onChange(of: width) { draw(width) }
                }
            }
    }
    private func draw(_ width: CGFloat) {
        if images.first?.size.width != width { images = Swatches.lineKinds(width: width) }
    }
}

/// A border as Pages's 단락 테두리: the line, then 위쪽, 아래쪽, 왼쪽 and 오른쪽 each turned on
/// or off, and 모두. `sides` are 왼쪽, 오른쪽, 위쪽, 아래쪽 as they are; `line`, the one last
/// chosen, shows while none is on. `apply` takes the sides to change.
struct BorderSides: View {
    let sides: [BorderSide]?
    @Binding var line: BorderSide
    let apply: ([Int: BorderSide]) -> Void
    private static let order = [2, 3, 0, 1]
    private static let names = ["왼쪽", "오른쪽", "위쪽", "아래쪽"]
    /// Sides clicked whose change is not read back yet: shown as clicked, not as they were.
    @State private var clicked: [Int: Bool] = [:]
    var body: some View {
        let on = (0..<4).map { clicked[$0] ?? ((sides?[$0].line ?? 0) != 0) }
        let shown = sides?.first { $0.line != 0 } ?? line
        var put = shown
        if put.line == 0 { put.line = 1 }
        return VStack(alignment: .leading, spacing: 8) {
            LineRow(line: Binding(get: { shown }, set: { new in
                line = new
                apply(Dictionary(uniqueKeysWithValues: (0..<4).filter { on[$0] }.map { ($0, new) }))
            }))
            HStack(spacing: 8) {
                Segments(segments: Self.order.map { .init(image: SideIcon.image([$0]), help: Self.names[$0]) },
                         on: Self.order.map { on[$0] }, any: true) { i in
                    let side = Self.order[i]
                    clicked[side] = !on[side]
                    apply([side: on[side] ? BorderSide(line: 0, width: put.width, color: put.color) : put])
                }
                Button {
                    for side in 0..<4 { clicked[side] = true }
                    apply([0: put, 1: put, 2: put, 3: put])
                } label: {
                    Image(nsImage: SideIcon.image([0, 1, 2, 3])).frame(maxWidth: .infinity)
                }
                .help("모두")
                .accessibilityLabel("모두")
                .frame(width: 64)
            }
            .flexibleButtons()
        }
        // A read from before a click leaves it shown as clicked.
        .onChange(of: sides) { clicked = clicked.filter { side, on in ((sides?[side].line ?? 0) != 0) != on } }
    }
}

/// Two numbers at the trailing edge, each named under it, as Pages's 위치.
struct Pair<First: View, Second: View>: View {
    let titles: (String, String)
    let first: First
    let second: Second
    init(_ firstTitle: String, _ first: First, _ secondTitle: String, _ second: Second) {
        (titles, self.first, self.second) = ((firstTitle, secondTitle), first, second)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 0)
            VStack(spacing: 3) { first; Text(titles.0).font(.caption) }
            VStack(spacing: 3) { second; Text(titles.1).font(.caption) }
        }
    }
}

/// Commands side by side, each its own button named in its help, as Pages's 뒤집기.
struct ActionButtons: View {
    let actions: [(title: String, symbol: String, run: () -> Void)]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions.indices, id: \.self) { i in
                // One size whatever the symbol's height.
                Button(action: actions[i].run) { Image(systemName: actions[i].symbol).frame(width: 24, height: 18) }
                    .help(actions[i].title)
                    .accessibilityLabel(actions[i].title)
            }
        }
        .fixedSize()
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

/// A 대각선 or 중심선 segment's picture: its lines across a cell.
enum DiagonalIcon {
    static func image(_ lines: [(CGFloat, CGFloat, CGFloat, CGFloat)]) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let box = rect.insetBy(dx: 2.5, dy: 2.5)
            let dashed = NSBezierPath(rect: box)
            dashed.setLineDash([2, 2], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.4).setStroke()
            dashed.stroke()
            let path = NSBezierPath()
            path.lineWidth = 2
            for (x1, y1, x2, y2) in lines {
                path.move(to: NSPoint(x: box.minX + x1 * box.width, y: box.minY + y1 * box.height))
                path.line(to: NSPoint(x: box.minX + x2 * box.width, y: box.minY + y2 * box.height))
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
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
    /// 그림 chosen before a picture is: its rows show, the picture to be chosen in them.
    @State private var picking = false
    /// 0 없음, 1 색, 2 그러데이션, 3 그림; -1 for none of them.
    private var kind: Int { picking ? 3 : Self.kind(fill) }
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
        .onChange(of: fill) { picking = false }
    }
    private func choose(_ kind: Int) {
        picking = false
        var new = base
        (new.gradient, new.image) = (nil, nil)
        switch kind {
        case 0: (new.color, new.pattern) = ("none", 0)
        case 2: new.gradient = Gradient()
        case 3: picking = Self.kind(fill) != 3; return
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
        // As Pages's: the colors across a bar, in stops under it and 번짐 중심 over it;
        // then 모양 with the swap of the colors, and 기울임.
        let apply = { (colors: [String], center: Double) in set { ($0.colors, $0.stepCenter) = (colors, UInt8(center)) } }
        GradientBar(colors: g.colors, center: Double(g.stepCenter), apply: apply)
        HStack(spacing: 8) {
            Segments([UInt8(1), 2, 3, 4], selection: Binding { g.kind } set: { kind in set { $0.kind = kind } }) { kind in
                .init(image: Swatches.gradientKinds[Int(kind) - 1], help: ["줄무늬", "원형", "원뿔형", "사각형"][Int(kind) - 1])
            }
            Button { apply(g.colors.reversed(), 100 - Double(g.stepCenter)) } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 24, height: 18) }
                .help("시작 색과 끝 색 바꾸기")
                .accessibilityLabel("시작 색과 끝 색 바꾸기")
                .fixedSize()
        }
        LabeledContent("기울임") {
            HStack(spacing: 8) {
                RotationDial(angle: Double(g.angle)) { angle in set { $0.angle = Int16(angle) } }
                    .frame(width: 28, height: 28)
                NumberStepper(value: Double(g.angle), unit: "°", range: 0...359, width: 44, unitInside: true) { angle in set { $0.angle = Int16(angle) } }
            }
        }
        Pair("가로 중심", NumberStepper(value: Double(g.centerX), unit: "%", range: 0...100) { x in set { $0.centerX = Int16(x) } },
             "세로 중심", NumberStepper(value: Double(g.centerY), unit: "%", range: 0...100) { y in set { $0.centerY = Int16(y) } })
        LabeledContent("번짐 정도") {
            NumberStepper(value: Double(g.blur), unit: "", range: 0...255) { blur in set { $0.blur = UInt8(blur) } }
        }
    }
    @ViewBuilder private var imageRows: some View {
        let i = base.image ?? ImageBrush()
        let set = { (edit: (inout ImageBrush) -> Void) in change { fill in
            var new = i
            edit(&new)
            fill.image = new
        } }
        // As Pages's: the picture beside its 채우기 유형 and 그림 선택.
        HStack(spacing: 8) {
            Group {
                if let picture = i.data.flatMap(NSImage.init(data:)) {
                    Image(nsImage: picture).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 60, height: 60)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            VStack(spacing: 8) {
                Picker("채우기 유형", selection: Binding { Int(i.mode) } set: { mode in set { $0.mode = UInt8(mode) } }) {
                    ForEach(Self.modes.indices, id: \.self) { Text(Self.modes[$0]).tag($0) }
                }
                .labelsHidden()
                .help("채우기 유형")
                    .disabled(base.image == nil)
                Button("그림 선택…") { pickImage() }
            }
            .flexibleButtons()
        }
        Group {
        LabeledContent("그림 효과") {
            Picker("그림 효과", selection: Binding { i.effect } set: { effect in set { $0.effect = effect } }) {
                Text("원래 그림").tag(UInt8(0)); Text("회색조").tag(UInt8(1)); Text("흑백").tag(UInt8(2))
            }
            .labelsHidden()
            .fixedSize()
        }
        PictureSlider(title: "밝기", value: Int32(i.brightness)) { value in set { $0.brightness = Int8(value) } }
        PictureSlider(title: "대비", value: Int32(i.contrast)) { value in set { $0.contrast = Int8(value) } }
        Toggle("워터마크 효과", isOn: Binding { i.brightness == 70 && i.contrast == -50 } set: { on in
            set { ($0.brightness, $0.contrast) = on ? (70, -50) : (0, 0) }
        })
        .checkbox()
        }
        // Until there is a picture to change.
        .disabled(base.image == nil)
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

/// 그러데이션 as HWPX keeps it: its colors spread evenly in stops under a bar (a click picks
/// its color, its menu takes it away), a click on the bar adding one there, and 번짐 중심 —
/// where the middle of the spread falls, one for the whole bar — as a mark over it to drag,
/// applied when let go. The bar shows the colors moved by it.
struct GradientBar: View {
    let colors: [String]
    let center: Double
    /// The new colors and 번짐 중심, as one edit.
    let apply: ([String], Double) -> Void
    @State private var dragged: Double?
    /// A stop's width: its swatch and the frame round it.
    private static let stop: CGFloat = 20

    var body: some View {
        let center = (dragged ?? center) / 100
        GeometryReader { geometry in
            let span = max(geometry.size.width - Self.stop, 1)
            let x = { (position: Double) in Self.stop / 2 + span * position }
            let place = { (x: CGFloat) in min(max((x - Self.stop / 2) / span, 0), 1) }
            VStack(spacing: 2) {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 10)
                    .contentShape(Rectangle())
                    .help("번짐 중심")
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("gradient"))
                        .onChanged { drag in dragged = (place(drag.location.x) * 100).rounded() }
                        .onEnded { _ in
                            if let dragged, dragged != self.center { apply(colors, dragged) }
                            dragged = nil
                        })
                    .position(x: x(center), y: 5)
                    .frame(height: 10)
                // As rhwp draws it: the spread's middle moved to 번짐 중심, each half in proportion.
                let stops = colors.indices.map { i in
                    let m = Double(i) / Double(max(colors.count - 1, 1))
                    return SwiftUI.Gradient.Stop(color: HexColor.color(colors[i]),
                                                 location: m <= 0.5 ? 2 * m * center : center + (m - 0.5) * 2 * (1 - center))
                }
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(stops: stops, startPoint: UnitPoint(x: x(0) / geometry.size.width, y: 0.5),
                                         endPoint: UnitPoint(x: x(1) / geometry.size.width, y: 0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in add(at: place(tap.location.x)) })
                    .frame(height: 18)
                ZStack {
                    ForEach(colors.indices, id: \.self) { i in
                        stop(i).position(x: x(Double(i) / Double(max(colors.count - 1, 1))), y: 13)
                    }
                }
                .frame(height: 26)
            }
            .coordinateSpace(name: "gradient")
        }
        .frame(height: 58)
    }
    /// A color's stop: its swatch in a frame pointing up at the bar.
    private func stop(_ i: Int) -> some View {
        ZStack(alignment: .bottom) {
            StopFrame()
                .fill(.background.secondary)
                .overlay(StopFrame().stroke(.separator))
            ColorWell(hex: Binding { colors[i] } set: { color in
                var new = colors
                new[i] = color
                apply(new, center)
            }, chip: true)
            .padding(.bottom, 3)
        }
        .frame(width: Self.stop, height: 24)
        .help(i == 0 ? "시작 색" : i == colors.count - 1 ? "끝 색" : "")
        .contextMenu {
            Button("지우기") {
                var new = colors
                new.remove(at: i)
                apply(new, center)
            }
            .disabled(colors.count <= 2)
        }
    }
    /// A color at `t` (0–1) along the bar, mixed from the two it falls between.
    private func add(at t: Double) {
        guard colors.count < 64 else { return }
        let last = Double(colors.count - 1), place = t * last
        let after = min(max(Int(place.rounded(.up)), 1), colors.count - 1)
        var new = colors
        new.insert(HexColor.mix(colors[after - 1], colors[after], place - Double(after - 1)), at: after)
        apply(new, center)
    }
}

/// A gradient stop's outline: a box with a point on top.
private struct StopFrame: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let shoulder = rect.minY + 6
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: shoulder))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 3))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - 3, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 3), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: shoulder))
            path.closeSubpath()
        }
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
