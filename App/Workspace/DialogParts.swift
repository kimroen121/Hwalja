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
            Text(title).font(.headline)
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
            if let none {
                Button { hex = none } label: { Image(nsImage: FormatChoices.swatch(none, none: true)) }
                    .buttonStyle(ToolButtonStyle(on: hex == none))
            }
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
