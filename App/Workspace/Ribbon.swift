import AppKit
import SwiftUI

/// 기본 도구 상자: the most used commands as large labeled icons, in Hancom Office Web's
/// order. Commands that do not work yet are left out.
struct ToolRow: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer

    var body: some View {
        let context = document.context
        HStack(spacing: 2) {
            ToolTile("저장하기", Icon.save) { send(#selector(NSDocument.save(_:))) }
            RowDivider()
            ToolTile("오려 두기", Icon.cut) { send(#selector(NSText.cut(_:))) }
                .disabled(!context.hasRange)
            ToolTile("복사하기", Icon.copy) { send(#selector(NSText.copy(_:))) }
                .disabled(!context.hasRange)
            ToolTile("붙이기", Icon.paste) { send(#selector(NSText.paste(_:))) }
                .disabled(!context.hasSelection)
            ToolTile("모양 복사", Icon.styleCopy) { viewer.paintFormat() }
                .disabled(!context.canFormat)
            RowDivider()
            ToolTile("찾기", Icon.find, action: { viewer.showFind(replace: false) },
                     choices: { MenuItems.findChoices(viewer) })
            RowDivider()
            ToolTile("표", Icon.table, action: { viewer.insertingTable = true },
                     panel: AnyView(TableGrid(viewer: viewer)))
                .disabled(!context.inBody)
            RowDivider()
            Group {
                ToolTile("각주", Icon.footnote) { viewer.insertNote(endnote: false) }
                ToolTile("미주", Icon.endnote) { viewer.insertNote(endnote: true) }
            }
            .disabled(!context.inBody)
            RowDivider()
            ToolTile("문자표", Icon.symbols) { NSApp.orderFrontCharacterPalette(nil) }
                .disabled(!context.hasSelection)
            RowDivider()
            Group {
                ToolTile("글자 모양", Icon.charShape) { viewer.editingCharShape = true }
                ToolTile("문단 모양", Icon.paraShape) { viewer.editingParaShape = true }
            }
            .disabled(!context.canFormat)
            RowDivider()
            ToolTile("머리말", Icon.header, choices: { MenuItems.headerChoices(viewer, footer: false) })
            ToolTile("꼬리말", Icon.footer, choices: { MenuItems.headerChoices(viewer, footer: true) })
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// SF Symbols shared by the tool rows and the menu bar.
enum Icon {
    static let save = "square.and.arrow.down", cut = "scissors", copy = "doc.on.doc", paste = "clipboard"
    static let styleCopy = "paintbrush", find = "magnifyingglass", replace = "arrow.left.arrow.right"
    static let goTo = "arrow.right.to.line", table = "tablecells", symbols = "character.book.closed"
    static let charShape = "textformat", paraShape = "text.alignleft"
    static let header = "rectangle.topthird.inset.filled", footer = "rectangle.bottomthird.inset.filled"
    static let footnote = "note.text", endnote = "doc.plaintext"
    static let pageSetup = "doc.text", print = "printer", pdf = "arrow.up.document"
    static let pageBreak = "arrow.down.to.line", columnBreak = "arrow.right.to.line.compact"
    static let insertRow = "plus.rectangle", deleteRow = "minus.rectangle"
    static func placement(_ placement: Placement?) -> String {
        switch placement {
        case nil: "rectangle"
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
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
    let action: () -> Void
}

/// A large icon over its name. With `choices` (a menu) or `panel` (a popover), the name
/// carries an arrow that opens them, and the icon runs `action` when there is one.
struct ToolTile: View {
    let title: String, symbol: String
    var action: (() -> Void)?
    var choices: (() -> [Choice?])?
    var panel: AnyView?
    @State private var anchor = Anchor()
    @State private var showsPanel = false

    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        (self.title, self.symbol, self.action) = (title, symbol, action)
    }
    init(_ title: String, _ symbol: String, action: (() -> Void)? = nil,
         choices: (() -> [Choice?])? = nil, panel: AnyView? = nil) {
        (self.title, self.symbol, self.action, self.choices, self.panel) = (title, symbol, action, choices, panel)
    }

    var body: some View {
        if choices == nil, panel == nil {
            Button(action: { action?() }) {
                // The arrow's room stays empty, so every name sits on one line.
                VStack(spacing: 3) { icon; VStack(spacing: 0) { name; arrow.hidden() } }
                    .frame(minWidth: 52).padding(.top, 3).padding(.horizontal, 2)
            }
            .buttonStyle(ToolButtonStyle())
        } else if let action {
            VStack(spacing: 0) {
                Button(action: action) { icon.frame(minWidth: 52).padding(.top, 3).padding(.bottom, 3) }
                    .buttonStyle(ToolButtonStyle())
                Button(action: open) { VStack(spacing: 0) { name; arrow }.frame(minWidth: 52) }
                    .buttonStyle(ToolButtonStyle())
                    .background(AnchorView(anchor: anchor))
            }
            .popover(isPresented: $showsPanel, arrowEdge: .bottom) { panel }
        } else {
            Button(action: open) {
                VStack(spacing: 3) { icon; VStack(spacing: 0) { name; arrow } }
                    .frame(minWidth: 52).padding(.top, 3).padding(.horizontal, 2)
            }
            .buttonStyle(ToolButtonStyle())
            .background(AnchorView(anchor: anchor))
        }
    }

    private var icon: some View {
        Image(systemName: symbol).font(.system(size: 19, weight: .light)).frame(height: 22)
    }
    private var name: some View { Text(title).font(.system(size: 11)) }
    private var arrow: some View {
        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).frame(height: 10)
    }
    private func open() {
        if panel != nil { showsPanel = true } else if let choices { DropDown.show(choices(), below: anchor.view) }
    }
}

/// The view a drop-down opens below.
final class Anchor {
    weak var view: NSView?
}
struct AnchorView: NSViewRepresentable {
    let anchor: Anchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// Native pop-up menus for the tool rows.
@MainActor
enum DropDown {
    static func show(_ choices: [Choice?], below view: NSView?) {
        guard let view else { return }
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
            item.image = choice.image ?? choice.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        let y = view.isFlipped ? view.bounds.maxY + 2 : -2
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
    private final class Handler: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
}

/// 표 drop-down: pick the size on a grid, or open 표 만들기.
private struct TableGrid: View {
    let viewer: Viewer
    @State private var rows = 0
    @State private var columns = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(rows)줄 × \(columns)칸").font(.callout).monospacedDigit().opacity(rows > 0 ? 1 : 0)
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
