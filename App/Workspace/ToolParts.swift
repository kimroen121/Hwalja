import AppKit
import SwiftUI

/// SF Symbols shared by the tool rows and the menu bar.
enum Icon {
    static let save = "square.and.arrow.down", cut = "scissors", copy = "doc.on.doc", paste = "clipboard"
    static let styleCopy = "paintbrush", find = "magnifyingglass", replace = "arrow.left.arrow.right"
    static let goTo = "arrow.right.to.line", table = "tablecells", picture = "photo", equation = "function", symbols = "character.book.closed"
    static let charShape = "textformat", paraShape = "text.alignleft"
    static let header = "rectangle.topthird.inset.filled", footer = "rectangle.bottomthird.inset.filled"
    static let footnote = "note.text", endnote = "doc.plaintext"
    static let objectProps = "slider.horizontal.3", pictureEffect = "camera.filters"
    static let brightness = "sun.max", contrast = "circle.lefthalf.filled", originalPicture = "arrow.uturn.backward",
                      selectObjects = "cursorarrow.and.square.on.square.dashed"
    static let pageSetup = "doc.text", print = "printer", pdf = "arrow.up.document"
    static let pageBorder = "square.dashed.inset.filled", section = "rectangle.split.1x2", noteShape = "text.append", styles = "textformat.alt"
    static let pageBreak = "arrow.down.to.line", columnBreak = "arrow.right.to.line.compact"
    static let insertRow = "plus.rectangle", deleteRow = "minus.rectangle"
    static let controlCodes = "chevron.left.forwardslash.chevron.right", paragraphMarks = "paragraphsign"
    static let documentInfo = "info.circle", password = "lock", passwordChange = "lock.rotation", eraseCodes = "eraser", bookmark = "bookmark", newNumber = "number", pageHide = "eye.slash"
    static let grid = "grid", caption = "text.below.photo", shape = "square.on.circle"
    static let textbox = "character.textbox", rectangle = "rectangle", ellipse = "circle", line = "line.diagonal", arc = "rainbow"
    static let splitCells = "square.split.2x2", mergeCells = "square.dashed"
    static let replacePicture = "photo.badge.arrow.down"
    static let cellBorder = "square.grid.3x3"
    static let field = "character.cursor.ibeam", modify = "square.and.pencil", chartData = "tablecells"
    static let saveAs = "square.and.arrow.down.on.square"
    static let hyperlink = "link", insertFile = "doc.badge.plus", autoText = "text.badge.plus"
    static let flipTable = "arrow.trianglehead.2.clockwise.rotate.90"
    static let splitTable = "arrow.up.and.line.horizontal.and.arrow.down", attachTable = "arrow.down.and.line.horizontal.and.arrow.up"
    static let undo = "arrow.uturn.backward", redo = "arrow.uturn.forward", delete = "delete.left"
        static let levelUp = "increase.indent", levelDown = "decrease.indent"
    static let equalHeight = "arrow.up.and.down.square", equalWidth = "arrow.left.and.right.square"
    static let blockCalculation = "sum"
    static let calculation = "function"
    static let rotate = "rotate.right"
    static let protect = "lock"
    static let privateInfo = "eye.slash"
    static let newDocument = "doc.badge.plus", open = "folder", taskPane = "sidebar.right"
    static let columns = "rectangle.split.2x1", bullets = "list.bullet", numbering = "list.number"
    static let portrait = "rectangle.portrait", landscape = "rectangle", pageOutline = "doc.richtext"
    static let zoomIn = "plus.magnifyingglass", zoomOut = "minus.magnifyingglass", actualSize = "1.magnifyingglass"
    static let fitWidth = "arrow.left.and.right", fitPage = "arrow.up.left.and.arrow.down.right", transparentLines = "rectangle.dashed"
    static let textIn = "a.square", front = "square.2.layers.3d.top.filled", back = "square.2.layers.3d.bottom.filled"
    static let group = "rectangle.3.group", previous = "chevron.up", next = "chevron.down", close = "xmark.circle"
    static let wrapSquare = "text.justify.left", wrapTopAndBottom = "rectangle.center.inset.filled"
    static let inFrontOfText = "square.3.layers.3d.top.filled", behindText = "square.3.layers.3d.bottom.filled"
    /// 머리말 or 꼬리말 shapes as the web editor draws them: a page with the number's place
    /// marked in red at its top or bottom; (모양 없음) only keeps the room.
    static func pageNumber(_ placement: Placement?, footer: Bool) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            guard let placement else { return true }
            let page = NSRect(x: 2.5, y: 0.5, width: 11, height: 15)
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(rect: page).stroke()
            let x: CGFloat = switch placement {
            case .left: page.minX + 1
            case .center: page.midX - 2
            case .right: page.maxX - 5
            }
            let mark = NSRect(x: x, y: footer ? page.maxY - 5 : page.minY + 1, width: 4, height: 4)
            NSColor.systemRed.withAlphaComponent(0.25).setFill()
            mark.fill()
            NSColor.systemRed.setStroke()
            NSBezierPath(rect: mark.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }
}

/// One drop-down command; `nil` in a list separates groups.
struct Choice {
    let title: String
    var symbol: String?
    var image: NSImage?
    var key = ""
    var modifiers: NSEvent.ModifierFlags = .command
    var enabled = true
    var on = false
    /// Shown as a submenu instead of running `action`.
    var submenu: [Choice?] = []
    var action: () -> Void = {}
}

/// Native menus made of `Choice`s.
@MainActor
enum DropDown {
    static func menu(_ choices: [Choice?]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in choices {
            guard let choice else {
                menu.addItem(.separator())
                continue
            }
            let handler = Handler(choice.action)
            let item = NSMenuItem(title: choice.title, action: #selector(Handler.run), keyEquivalent: choice.key)
            (item.target, item.representedObject) = (handler, handler)
            item.keyEquivalentModifierMask = choice.modifiers
            item.isEnabled = choice.enabled
            item.state = choice.on ? .on : .off
            if choice.title.isEmpty, let image = choice.image {
                // A picture alone is left out of the menu's width, so it goes in as the title.
                let picture = NSTextAttachment()
                picture.image = image
                item.attributedTitle = NSAttributedString(attachment: picture)
            } else {
                item.image = choice.image ?? choice.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            }
            if !choice.submenu.isEmpty { item.submenu = Self.menu(choice.submenu) }
            menu.addItem(item)
        }
        return menu
    }
    private final class Handler: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}

/// 표 drop-down: pick the size on a grid, or open 표 만들기.
struct TableGrid: View {
    let viewer: Viewer
    @State private var rows = 0
    @State private var columns = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // As in the web editor: 취소 until a size is pointed at.
            Button(rows > 0 ? "\(rows) × \(columns)" : "취소") { dismiss() }
                .buttonStyle(.borderless)
                .monospacedDigit()
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(1...8, id: \.self) { row in
                    GridRow {
                        ForEach(1...10, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(row <= rows && column <= columns ? Color.accentColor.opacity(0.3) : .clear)
                                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.separator))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                                .onHover { if $0 { (rows, columns) = (row, column) } }
                                .onTapGesture {
                                    dismiss()
                                    viewer.insertTable(rows: row, columns: column)
                                }
                        }
                    }
                }
            }
            Divider()
            Button("표 만들기…") {
                dismiss()
                viewer.insertingTable = true
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
    }
}

/// 도형: the shapes as large tiles, as Keynote's shape popover.
struct ShapeTiles: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 8), count: 3), spacing: 8) {
            ForEach(MenuItems.shapes, id: \.shape) { item in
                Button {
                    dismiss()
                    viewer.draw(item.shape)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: item.symbol).symbolVariant(.fill).font(.system(size: 30)).frame(height: 36)
                        Text(item.title).font(.callout)
                    }
                    .frame(width: 84, height: 84)
                }
            }
        }
        .padding(14)
        .buttonBorderShape(.roundedRectangle)
    }
}

/// Pane navigation keeps one selection surface alive as it moves between tabs.
struct PaneTabs<Value: Hashable, Content: View>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @ViewBuilder let label: (Value) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    var body: some View {
        GeometryReader { geometry in
            tabs
                .contentShape(Capsule())
                // Once dragging starts, consume the button's click so mouse-up cannot
                // reselect the tab where the drag began.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { drag in select(at: drag.location.x, width: geometry.size.width) }
                        .onEnded { drag in select(at: drag.location.x, width: geometry.size.width) }
                )
        }
        .frame(height: 24)
    }

    private func select(at x: CGFloat, width: CGFloat) {
        guard !values.isEmpty, width > 6 else { return }
        let fraction = min(max((x - 3) / (width - 6), 0), 1)
        let index = min(Int(fraction * CGFloat(values.count)), values.count - 1)
        guard selection != values[index] else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.15)) { selection = values[index] }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { selection = value }
                } label: {
                    label(value)
                        .font(.system(size: 12, weight: selection == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    if selection == value {
                        selectionSurface
                            .matchedGeometryEffect(id: "selection", in: indicator)
                    }
                }
                .accessibilityLabel(title(value))
                .accessibilityAddTraits(selection == value ? [.isSelected] : [])
                .help(title(value))
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    @ViewBuilder private var selectionSurface: some View {
        if #available(macOS 26, *) {
            Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(.regularMaterial)
        }
    }
}

/// macOS's segmented control as wide as it is given, the segments sharing the width: one
/// picked, or with `any` each on or off as a toggle.
struct Segments: NSViewRepresentable {
    struct Segment {
        var title: String?
        var symbol: String?
        var help: String
        /// Choices the segment holds, shown by its menu arrow.
        var menu: [Choice?] = []
    }
    let segments: [Segment]
    let on: [Bool]
    var any = false
    var size: NSControl.ControlSize = .regular
    /// The selection in the accent color, as tabs.
    var accent = false
    /// A capsule, as a pane's tabs; else a rounded rectangle, as the controls in a pane.
    var capsule = false
    let pick: (Int) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }
    /// Sets only what changed: setting a value again restarts the control's selection
    /// animation, which made the tabs swell and shrink on a click.
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.segments = self
        func set<T: Equatable>(_ key: ReferenceWritableKeyPath<NSSegmentedControl, T>, _ value: T) {
            if control[keyPath: key] != value { control[keyPath: key] = value }
        }
        set(\.trackingMode, any ? .selectAny : .selectOne)
        set(\.controlSize, size)
        set(\.selectedSegmentBezelColor, accent ? .controlAccentColor : nil)
        set(\.isEnabled, context.environment.isEnabled)
        if #available(macOS 26, *) { set(\.borderShape, capsule ? .capsule : .roundedRectangle) }
        set(\.segmentCount, segments.count)
        for (index, segment) in segments.enumerated() {
            if control.label(forSegment: index) ?? "" != segment.title ?? "" { control.setLabel(segment.title ?? "", forSegment: index) }
            if (control.image(forSegment: index) == nil) != (segment.symbol == nil) || control.toolTip(forSegment: index) != segment.help {
                control.setImage(segment.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: segment.help) }, forSegment: index)
                control.setToolTip(segment.help, forSegment: index)
            }
            if !segment.menu.isEmpty || control.menu(forSegment: index) != nil {
                control.setMenu(segment.menu.isEmpty ? nil : DropDown.menu(segment.menu), forSegment: index)
                control.setShowsMenuIndicator(!segment.menu.isEmpty, forSegment: index)
            }
            let on = on.indices.contains(index) && on[index]
            if control.isSelected(forSegment: index) != on { control.setSelected(on, forSegment: index) }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var segments: Segments
        init(_ segments: Segments) { self.segments = segments }
        @objc func changed(_ control: NSSegmentedControl) {
            // With `any`, the segment whose state now differs is the one clicked.
            let index = segments.any
                ? (0..<control.segmentCount).first { control.isSelected(forSegment: $0) != (segments.on.indices.contains($0) && segments.on[$0]) }
                : control.selectedSegment
            if let index, index >= 0 { segments.pick(index) }
        }
    }
}
extension Segments {
    /// One of `values`, bound to `selection`.
    init<Value: Hashable>(_ values: [Value], selection: Binding<Value>, size: NSControl.ControlSize = .regular,
                          accent: Bool = false, capsule: Bool = false, segment: (Value) -> Segment) {
        self.init(segments: values.map(segment), on: values.map { $0 == selection.wrappedValue }, size: size, accent: accent,
                  capsule: capsule) {
            selection.wrappedValue = values[$0]
        }
    }
}

#Preview {
    TableGrid(viewer: Viewer())
}
