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

extension View {
    /// The width every tabbed dialog shares.
    func dialogTabs() -> some View { frame(width: 460, alignment: .topLeading) }
    /// A tab of a dialog, named and tagged `title`.
    func tab(_ title: String) -> some View {
        frame(maxWidth: .infinity, alignment: .topLeading).tabItem { Text(title) }.tag(title)
    }
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
