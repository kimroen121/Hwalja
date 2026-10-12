import AppKit
import SwiftUI

// Parts every dialog is built from, so they share one look: a title, groups of
// labeled fields, and 취소 and 확인.

/// A dialog: its title, its content, and 취소 and the confirming button, as in the web
/// editor's dialogs.
struct DialogFrame<Content: View>: View {
    let title: String
    var confirmTitle = "확인"
    var canConfirm = true
    let content: Content
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(_ title: String, confirmTitle: String = "확인", canConfirm: Bool = true,
         @ViewBuilder content: () -> Content, confirm: @escaping () -> Void) {
        (self.title, self.confirmTitle, self.canConfirm) = (title, confirmTitle, canConfirm)
        (self.content, self.confirm) = (content(), confirm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline.weight(.regular))
            content
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm).keyboardShortcut(.defaultAction).disabled(!canConfirm)
            }
        }
        .padding(20)
        .fixedSize()
    }
}

/// A dialog's tabs, in AppKit's own tab view.
struct DialogTabs<Content: View>: NSViewRepresentable {
    @Binding var selection: String
    let titles: [String]
    @ViewBuilder let content: (String) -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTabView {
        let view = SheetTabView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTabView, context: Context) {
        context.coordinator.selection = $selection
        if view.tabViewItems.map(\.label) != titles {
            view.tabViewItems.forEach(view.removeTabViewItem)
            for title in titles {
                let item = NSTabViewItem(identifier: title)
                item.label = title
                item.view = NSHostingView(rootView: AnyView(EmptyView()))
                view.addTabViewItem(item)
            }
        }
        for item in view.tabViewItems {
            (item.view as? NSHostingView<AnyView>)?.rootView =
                AnyView(content(item.label).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
        if view.selectedTabViewItem?.label != selection, let index = titles.firstIndex(of: selection) {
            view.selectTabViewItem(at: index)
        }
    }

    final class Coordinator: NSObject, NSTabViewDelegate {
        var selection: Binding<String>?
        func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
            if let label = item?.label, selection?.wrappedValue != label { selection?.wrappedValue = label }
        }
    }
}

/// One of a few choices, in the segmented control `DialogTabs`'s bar is made of.
struct DialogChoice: NSViewRepresentable {
    @Binding var selection: Int
    let titles: [String]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        // The tab view's own bar draws in the tabs' style rather than the accent color.
        let kind = NSClassFromString("NSTabViewSegmentedControl") as? NSSegmentedControl.Type ?? SheetSegments.self
        let control = kind.init(labels: titles, trackingMode: .selectOne,
                                target: context.coordinator, action: #selector(Coordinator.choose(_:)))
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        if control.selectedSegment != selection { control.selectedSegment = selection }
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Int>?
        @objc func choose(_ control: NSSegmentedControl) { selection?.wrappedValue = control.selectedSegment }
    }
}

/// Segments in a sheet, laid out again before they first draw, as `SheetTabView`.
private final class SheetSegments: NSSegmentedControl {
    private var settled = false
    override func viewWillDraw() {
        super.viewWillDraw()
        guard !settled, window != nil else { return }
        settled = true
        for index in 0..<segmentCount { setWidth(0, forSegment: index) }
        invalidateIntrinsicContentSize()
    }
}

/// A tab view in a sheet lays its tab names over one another until its tab bar is set up
/// again once the sheet is up, so that is done before it first draws.
private final class SheetTabView: NSTabView {
    private var settled = false
    override func viewWillDraw() {
        super.viewWillDraw()
        guard !settled, window != nil else { return }
        settled = true
        tabViewType = .noTabsNoBorder
        tabViewType = .topTabsBezelBorder
    }
}

extension View {
    /// The width every tabbed dialog shares.
    func dialogTabs() -> some View { frame(width: 460, alignment: .topLeading) }
}

/// A group's name, in the web dialogs' blue and the weight of the fields under it.
struct GroupTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).foregroundStyle(Color(nsColor: Self.blue)) }
    static let blue = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.53, green: 0.67, blue: 0.95, alpha: 1)
            : NSColor(srgbRed: 0.20, green: 0.33, blue: 0.62, alpha: 1)
    }
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

/// A number with its unit and a stepper, clamped to `range`.
struct SpinField: View {
    @Binding var value: Double
    let unit: String
    let range: ClosedRange<Double>
    var step = 1.0
    var digits = 1
    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding { value } set: { value = min(max($0, range.lowerBound), range.upperBound) },
                      format: .number.precision(.fractionLength(0...digits)))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
            Text(unit).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .leading).fixedSize()
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
    }
}

/// A color: macOS's color well, its swatch joined to the color wheel in one piece, as Pages's.
/// A click on the swatch shows the swatches, on the wheel the color panel. Where `none`
/// offers no color, the well's own: no color is clear, shown with its slash.
struct ColorWell: View {
    @Binding var hex: String
    var none: String?
    /// Only the swatch, as a circle.
    var circle = false
    /// Only the swatch, as a small square: a 그러데이션's stop.
    var chip = false
    /// The swatch as wide as its place.
    var wide = false
    /// Counts clicks on the wheel, each bringing up the color panel for this well.
    @State private var panel = 0
    @Environment(\.isEnabled) private var enabled
    /// The color, or no color as white with a red slash.
    @ViewBuilder private var swatch: some View {
        if hex == none {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height)); $0.addLine(to: CGPoint(x: size.width, y: 0)) },
                               with: .color(.red), lineWidth: 1.5)
            }
        } else {
            HexColor.color(hex)
        }
    }
    var body: some View {
        let well = SystemColorWell(hex: hex == none ? nil : hex, clearable: none != nil, panel: panel) { hex = $0 ?? none ?? hex }
        if circle {
            well.frame(width: 18, height: 18).clipShape(Circle())
        } else if chip {
            well.frame(width: 14, height: 14)
                .overlay { swatch.opacity(enabled ? 1 : 0.4).allowsHitTesting(false) }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
        } else {
            HStack(spacing: 0) {
                // The color fills its part, as Pages's; clicks go to the well under it.
                well.frame(minWidth: 36, maxWidth: wide ? .infinity : 36)
                    .overlay { swatch.opacity(enabled ? 1 : 0.4).allowsHitTesting(false) }
                Button { panel += 1 } label: {
                    Image(nsImage: NSImage(named: NSImage.colorPanelName)!).resizable().frame(width: 18, height: 18)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .background(.quaternary)
                .help("색상 보기")
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }
}

/// The swatch part of macOS's color well; a new `panel` count brings up the color panel for it.
private struct SystemColorWell: NSViewRepresentable {
    let hex: String?
    let clearable: Bool
    var panel = 0
    let set: (String?) -> Void

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(style: .minimal)
        well.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        well.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        well.supportsAlpha = clearable
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        return well
    }
    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.set = set
        context.coordinator.hex = hex
        well.isEnabled = context.environment.isEnabled
        if Coordinator.hex(well.color) != hex { well.color = hex.map { NSColor(HexColor.color($0)) } ?? .clear }
        if panel != context.coordinator.panel {
            context.coordinator.panel = panel
            well.activate(true)
            NSColorPanel.shared.orderFront(nil)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(hex: hex, set: set) }

    @MainActor final class Coordinator: NSObject {
        var hex: String?
        var set: (String?) -> Void
        var panel = 0
        init(hex: String?, set: @escaping (String?) -> Void) { (self.hex, self.set) = (hex, set) }
        /// The color as `#rrggbb`, or nil when clear.
        static func hex(_ color: NSColor) -> String? {
            color.alphaComponent == 0 ? nil : HexColor.hex(Color(nsColor: color))
        }
        @objc func changed(_ well: NSColorWell) {
            let picked = Self.hex(well.color)
            guard picked != hex else { return }
            hex = picked
            set(picked)
        }
    }
}

/// Pictures for the line, width, color and pattern drop-downs, as the web dialogs draw them.
enum Swatches {
    private static func slash(_ box: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: box.minX, y: box.maxY))
        path.line(to: NSPoint(x: box.maxX, y: box.minY))
        NSColor.systemRed.setStroke()
        path.stroke()
    }
    /// 테두리 종류 0 (none) to 13, drawn with `LineShapes` (whose shape n is kind n + 1).
    static let lineKinds = lineKinds(width: 64)
    static func lineKinds(width: CGFloat) -> [NSImage] {
        [
            NSImage(size: NSSize(width: width, height: 10), flipped: true) { rect in
                let box = rect.insetBy(dx: 1, dy: 0.5)
                NSColor.secondaryLabelColor.setStroke()
                NSBezierPath(rect: box).stroke()
                slash(box)
                return true
            },
        ] + LineShapes.images(width: width)
    }
    /// 굵기 as a number: a step moves along the list (by `widthStep`, which no width is
    /// apart by), a typed width takes the nearest.
    static let widthStep = 0.001
    static func widthIndex(_ value: Double, from now: Int, in list: [Double] = widths) -> Int {
        abs(value - (list[now] + widthStep)) < 1e-9 ? min(now + 1, list.count - 1)
            : abs(value - (list[now] - widthStep)) < 1e-9 ? max(now - 1, 0)
            : list.indices.min { abs(list[$0] - value) < abs(list[$1] - value) }!
    }
    /// 그러데이션 모양 1 줄무늬, 2 원형, 3 원뿔형 and 4 사각형, light to dark.
    static let gradientKinds: [NSImage] = (1...4).map { kind in
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let light = NSColor(white: 0.95, alpha: 1), dark = NSColor(white: 0.25, alpha: 1)
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
            box.addClip()
            switch kind {
            case 1: NSGradient(starting: light, ending: dark)?.draw(in: rect, angle: -45)
            case 2: NSGradient(starting: light, ending: dark)?.draw(in: NSBezierPath(rect: rect), relativeCenterPosition: .zero)
            case 3:
                // Around the middle, as wedges.
                let middle = NSPoint(x: rect.midX, y: rect.midY)
                for step in 0..<36 {
                    let wedge = NSBezierPath()
                    wedge.move(to: middle)
                    wedge.appendArc(withCenter: middle, radius: rect.width, startAngle: CGFloat(step) * 10, endAngle: CGFloat(step + 1) * 10 + 0.5)
                    wedge.close()
                    (light.blended(withFraction: CGFloat(step) / 35, of: dark) ?? dark).setFill()
                    wedge.fill()
                }
            default:
                for step in 0..<8 {
                    let inset = CGFloat(step) * rect.width / 16
                    (dark.blended(withFraction: CGFloat(step) / 7, of: light) ?? light).setFill()
                    NSBezierPath(rect: rect.insetBy(dx: inset, dy: inset)).fill()
                }
            }
            return true
        }
    }
    /// 굵기: the widths rhwp numbers 0–15, in millimeters.
    static let widths: [Double] = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1, 1.5, 2, 3, 4, 5]
    /// The same in points, as Pages shows a line's width.
    static let widthPoints = widths.map { ($0 * 72 / 25.4 * 100).rounded() / 100 }
    /// 선 끝 모양 0 (round) and 1 (flat), on a thick line.
    static let lineEnds: [NSImage] = [NSBezierPath.LineCapStyle.round, .butt].map { cap in
        NSImage(size: NSSize(width: 64, height: 12), flipped: true) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 8, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX - 8, y: rect.midY))
            path.lineWidth = 6
            path.lineCapStyle = cap
            NSColor.labelColor.setStroke()
            path.stroke()
            return true
        }
    }
    /// 화살표 모양 0 (none) to 6 (arrow, lined arrow, concave arrow, diamond, circle, square),
    /// at the start or end of a line, and the nine 화살표 크기 (width by length, small to large).
    static let arrowStarts = (0...6).map { arrow($0, size: 4, start: true) }
    static let arrowEnds = (0...6).map { arrow($0, size: 4, start: false) }
    static let arrowStartSizes = (0...8).map { arrow(1, size: $0, start: true) }
    static let arrowEndSizes = (0...8).map { arrow(1, size: $0, start: false) }
    private static func arrow(_ kind: Int, size: Int, start: Bool) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 14), flipped: true) { rect in
            let y = rect.midY, length = CGFloat(5 + 2 * (size % 3)), half = CGFloat(2 + 1.5 * Double(size / 3))
            // Drawn pointing right at the end, mirrored for the start.
            if start {
                let flip = NSAffineTransform()
                flip.translateX(by: rect.maxX, yBy: 0)
                flip.scaleX(by: -1, yBy: 1)
                flip.concat()
            }
            let tip = rect.maxX - 4
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 4, y: y))
            line.line(to: NSPoint(x: kind == 0 || kind == 2 ? tip : tip - length / 2, y: y))
            line.lineWidth = 1
            NSColor.labelColor.set()
            line.stroke()
            let head = NSBezierPath()
            switch kind {
            case 1, 3:
                head.move(to: NSPoint(x: tip, y: y))
                head.line(to: NSPoint(x: tip - length, y: y - half))
                if kind == 3 { head.line(to: NSPoint(x: tip - length * 0.6, y: y)) }
                head.line(to: NSPoint(x: tip - length, y: y + half))
                head.close()
                head.fill()
            case 2:
                head.move(to: NSPoint(x: tip - length, y: y - half))
                head.line(to: NSPoint(x: tip, y: y))
                head.line(to: NSPoint(x: tip - length, y: y + half))
                head.stroke()
            case 4:
                head.move(to: NSPoint(x: tip, y: y))
                head.line(to: NSPoint(x: tip - length / 2, y: y - half))
                head.line(to: NSPoint(x: tip - length, y: y))
                head.line(to: NSPoint(x: tip - length / 2, y: y + half))
                head.close()
                head.stroke()
            case 5:
                head.appendOval(in: NSRect(x: tip - length, y: y - half, width: length, height: 2 * half))
                head.stroke()
            case 6:
                head.appendRect(NSRect(x: tip - length, y: y - half, width: length, height: 2 * half))
                head.stroke()
            default: break
            }
            return true
        }
    }
    /// 무늬 모양 0 (none) to 6: horizontal, vertical, back slant, slant, cross and slant cross.
    static let patterns: [NSImage] = (0...6).map { kind in
        NSImage(size: NSSize(width: 56, height: 12), flipped: true) { rect in
            let box = rect.insetBy(dx: 0.5, dy: 0.5)
            NSColor.white.setFill()
            box.fill()
            let path = NSBezierPath()
            let step: CGFloat = 4
            if [1, 5].contains(kind) {
                for y in stride(from: box.minY + 2, to: box.maxY, by: step) {
                    path.move(to: NSPoint(x: box.minX, y: y)); path.line(to: NSPoint(x: box.maxX, y: y))
                }
            }
            if [2, 5].contains(kind) {
                for x in stride(from: box.minX + 2, to: box.maxX, by: step) {
                    path.move(to: NSPoint(x: x, y: box.minY)); path.line(to: NSPoint(x: x, y: box.maxY))
                }
            }
            if [3, 6].contains(kind) {
                for x in stride(from: box.minX - box.height, to: box.maxX, by: step) {
                    path.move(to: NSPoint(x: x, y: box.minY)); path.line(to: NSPoint(x: x + box.height, y: box.maxY))
                }
            }
            if [4, 6].contains(kind) {
                for x in stride(from: box.minX, to: box.maxX + box.height, by: step) {
                    path.move(to: NSPoint(x: x, y: box.minY)); path.line(to: NSPoint(x: x - box.height, y: box.maxY))
                }
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: box).addClip()
            path.lineWidth = 0.75
            NSColor.darkGray.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(rect: box).stroke()
            return true
        }
    }
}

/// Converts between `#rrggbb` and SwiftUI colors.
enum HexColor {
    /// The engine's 0x00bbggrr as `#rrggbb`, and back.
    static func hex(bgr color: UInt32) -> String {
        String(format: "#%02x%02x%02x", color & 255, color >> 8 & 255, color >> 16 & 255)
    }
    static func bgr(_ hex: String) -> UInt32 {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (rgb >> 16 & 255) | (rgb & 0xff00) | (rgb & 255) << 16
    }
    /// `a` and `b` mixed, `t` (0–1) of the way to `b`.
    static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        let parts = { (hex: String) in [16, 8, 0].map { Double((Int(hex.dropFirst(), radix: 16) ?? 0) >> $0 & 255) } }
        let (x, y) = (parts(a), parts(b))
        return "#" + zip(x, y).map { String(format: "%02x", Int(($0 + ($1 - $0) * t).rounded())) }.joined()
    }
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

/// HWPUNIT (1/7200 inch) and millimeters, as dialogs show lengths.
enum Units {
    static let perMillimeter = 7200 / 25.4
    static func millimeters<T: BinaryInteger>(_ units: T) -> Double {
        (Double(units) / perMillimeter * 10).rounded() / 10
    }
    static func units<T: BinaryInteger>(_ millimeters: Double) -> T {
        T(clamping: Int((millimeters * perMillimeter).rounded()))
    }
}

/// A drop-down in a dialog: macOS's pop-up button, its choices as names or pictures.
struct ChoiceField<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var images: [NSImage]?
    var minWidth: CGFloat = 0
    /// As wide as its place.
    var flexible = false

    init(_ selection: Binding<Value>, _ options: [(value: Value, title: String)],
         images: [NSImage]? = nil, minWidth: CGFloat = 0, flexible: Bool = false) {
        (_selection, self.options, self.images, self.minWidth, self.flexible) = (selection, options, images, minWidth, flexible)
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { i in
                Group {
                    if let images { Image(nsImage: images[i]).accessibilityLabel(options[i].title) } else { Text(options[i].title) }
                }
                .tag(options[i].value)
            }
        }
        .labelsHidden()
        .buttonSizing(flexible)
        .frame(minWidth: minWidth, maxWidth: flexible ? .infinity : nil)
        .fixedSize(horizontal: !flexible, vertical: true)
    }
}

/// Choices shown as pictures in a row, as the web dialogs show 본문과의 배치 and 쪽 경계에서.
struct IconTiles<Value: Hashable, Picture: View>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// The tiles share the width they are given, as the inspector's rows do.
    var fill = false
    @ViewBuilder let picture: (Value, Bool) -> Picture
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    picture(option.value, selection == option.value).frame(width: 30, height: 30).padding(4)
                        .frame(maxWidth: fill ? .infinity : nil)
                }
                .choice(selection == option.value)
                .help(option.title)
                .accessibilityLabel(option.title)
            }
        }
    }
}

/// A small icon button beside a list, named by its help tag.
func listTool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 20) }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
}

#Preview {
    ColorWell(hex: .constant("FF0000")).padding()
}

private extension View {
    /// As wide as its place on macOS 26, where pop-ups otherwise fit their title.
    @ViewBuilder func buttonSizing(_ flexible: Bool) -> some View {
        if #available(macOS 26, *), flexible { buttonSizing(.flexible) } else { self }
    }
}
