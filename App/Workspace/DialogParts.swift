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

/// A number with its unit and step arrows in a box, clamped to `range`.
struct SpinField: View {
    @Binding var value: Double
    let unit: String
    let range: ClosedRange<Double>
    var step = 1.0
    var digits = 1
    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: Binding { value } set: { value = min(max($0, range.lowerBound), range.upperBound) },
                      format: .number.precision(.fractionLength(0...digits)))
                .textFieldStyle(.plain)
                .monospacedDigit()
                .frame(width: 56)
            Text(unit).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .leading).fixedSize()
            VStack(spacing: 0) {
                StepArrow(symbol: "chevron.up") { value = min(value + step, range.upperBound) }
                StepArrow(symbol: "chevron.down") { value = max(value - step, range.lowerBound) }
            }
        }
        .padding(.leading, 6)
        .fieldBox()
    }
}

/// A color as a drop-down like the others: the color in a box with ▾, opening the
/// palette and the system colors. `none` offers no color, drawn slashed.
struct ColorWell: View {
    @Binding var hex: String
    var none: String?
    @State private var open = false
    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 0) {
                Image(nsImage: Swatches.bar(hex, none: hex == none)).padding(.leading, 7)
                    .frame(minWidth: 100, alignment: .leading)
                Chevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fieldBox()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HStack(spacing: 4) {
                ForEach(([none].compactMap { $0 }) + FormatChoices.colors, id: \.self) { color in
                    Button {
                        open = false
                        hex = color
                    } label: {
                        Image(nsImage: FormatChoices.swatch(color, none: color == none)).padding(3)
                    }
                    .buttonStyle(ToolButtonStyle(on: color == hex))
                }
                ColorPicker("", selection: Binding { HexColor.color(hex) } set: { hex = HexColor.hex($0) },
                            supportsOpacity: false)
                    .labelsHidden()
            }
            .padding(8)
        }
    }
}

/// Pictures for the line, width, color and pattern drop-downs, as the web dialogs draw them.
enum Swatches {
    /// A wide box of a color; no color is white with a red slash.
    static func bar(_ hex: String, none: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: 56, height: 12), flipped: true) { rect in
            let box = rect.insetBy(dx: 0.5, dy: 0.5)
            (none ? NSColor.white : NSColor(HexColor.color(hex))).setFill()
            box.fill()
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(rect: box).stroke()
            if none { slash(box) }
            return true
        }
    }
    private static func slash(_ box: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: box.minX, y: box.maxY))
        path.line(to: NSPoint(x: box.maxX, y: box.minY))
        NSColor.systemRed.setStroke()
        path.stroke()
    }
    /// 테두리 종류 0 (none) to 13, drawn with `LineShapes` (whose shape n is kind n + 1).
    static let lineKinds: [NSImage] = [
        NSImage(size: NSSize(width: 64, height: 10), flipped: true) { rect in
            let box = rect.insetBy(dx: 1, dy: 0.5)
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(rect: box).stroke()
            slash(box)
            return true
        },
    ] + LineShapes.images
    /// 굵기: the widths rhwp numbers 0–15, in millimeters.
    static let widths: [Double] = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1, 1.5, 2, 3, 4, 5]
    static let widthImages: [NSImage] = widths.map { mm in
        let text = NSAttributedString(string: "\(mm.formatted())mm",
                                      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        let image = NSImage(size: NSSize(width: 92, height: 14), flipped: true) { rect in
            text.draw(at: NSPoint(x: 0, y: 0))
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 44, y: rect.midY))
            line.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
            line.lineWidth = max(0.5, mm * 72 / 25.4)
            NSColor.labelColor.setStroke()
            line.stroke()
            return true
        }
        return image
    }
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

/// A drop-down in a dialog, drawn like the format row's boxes (글꼴, 글자 크기): the
/// current choice in a rounded box with ▾, opening a native menu with it checked.
struct ChoiceField<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var images: [NSImage]?
    var minWidth: CGFloat = 0
    @State private var anchor = Anchor()

    init(_ selection: Binding<Value>, _ options: [(value: Value, title: String)],
         images: [NSImage]? = nil, minWidth: CGFloat = 0) {
        (_selection, self.options, self.images, self.minWidth) = (selection, options, images, minWidth)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 0) {
                label.padding(.leading, 7).frame(minWidth: minWidth, alignment: .leading)
                Spacer(minLength: 4)
                Chevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .fieldBox()
        .background(AnchorView(anchor: anchor))
        .accessibilityLabel(current?.title ?? "")
    }

    private var index: Int? { options.firstIndex { $0.value == selection } }
    private var current: (value: Value, title: String)? { index.map { options[$0] } }
    @ViewBuilder private var label: some View {
        if let images, let index {
            Image(nsImage: images[index])
        } else {
            Text(current?.title ?? "").lineLimit(1)
        }
    }
    private func open() {
        DropDown.show(options.indices.map { i in
            Choice(title: images == nil ? options[i].title : "", image: images?[i], on: options[i].value == selection) {
                selection = options[i].value
            }
        }, below: anchor.view)
    }
}

/// Choices shown as pictures in a row, as the web dialogs show 본문과의 배치 and 쪽 경계에서.
struct IconTiles<Value: Hashable, Picture: View>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @ViewBuilder let picture: (Value, Bool) -> Picture
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    picture(option.value, selection == option.value).frame(width: 30, height: 30).padding(4)
                }
                .buttonStyle(ToolButtonStyle(on: selection == option.value))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                .help(option.title)
                .accessibilityLabel(option.title)
            }
        }
    }
}
