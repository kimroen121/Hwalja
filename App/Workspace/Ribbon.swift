import AppKit
import SwiftUI

/// 도구 상자: small tabs, as in Word's ribbon, each switching a row of large labeled
/// icons. 기본 is Hancom Office Web's 기본 도구 상자; the others hold the commands of
/// the menus of the same names. Commands that do not work yet are left out.
struct ToolRow: View {
    @ObservedObject var document: HwpDocument
    let viewer: Viewer
    @AppStorage("toolTab") private var tab = "기본"
    @State private var hovered: String?
    @State private var spans: [String: CGRect] = [:]
    static let tabs = ["기본", "편집", "보기", "입력", "서식", "쪽", "표"]

    var body: some View {
        let context = document.context
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Self.tabs, id: \.self) { name in
                    Button { tab = name } label: {
                        // Laid out bold either way, so choosing a tab moves nothing and the line slides undisturbed.
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .hidden()
                            .overlay {
                                Text(name)
                                    .font(.system(size: 13, weight: tab == name ? .semibold : .regular))
                                    .foregroundStyle(tab == name ? .primary : .secondary)
                            }
                            .padding(.vertical, 4)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabs")) } action: { spans[name] = $0 }
                            // The gap between tabs is part of them, so a click beside a name still lands.
                            .padding(.horizontal, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? name : (hovered == name ? nil : hovered) }
                }
            }
            .coordinateSpace(.named("tabs"))
            .overlay(alignment: .topLeading) {
                // As in Word: one line under the selected tab, moved from tab to tab, a little longer under the pointer.
                if let span = spans[tab] {
                    let grow: CGFloat = hovered == tab ? 4 : 0
                    Capsule()
                        .frame(width: span.width + grow * 2, height: 3)
                        .offset(x: span.minX - grow, y: span.maxY - 1.5)
                        .allowsHitTesting(false)
                }
            }
            // A change to stored settings comes without the click's animation.
            .animation(.snappy(duration: 0.25), value: tab)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .padding(.horizontal, 7)
            .padding(.top, 5)
            // A narrow window scrolls the row instead of squeezing it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 2) { tiles(context) }
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private func tiles(_ context: EditingContext) -> some View {
        switch tab {
        case "편집": edit(context)
        case "보기": view
        case "입력": insert(context)
        case "서식": format(context)
        case "쪽": page(context)
        case "표": table(context)
        default: basic(context)
        }
        // The selected picture's tools, last so the row never shifts.
        if context.object == .picture {
            RowDivider()
            ToolTile("색조 조정", Icon.pictureEffect, choices: { MenuItems.pictureEffects(viewer) })
            ToolTile("밝기", Icon.brightness, choices: { MenuItems.brightness(viewer) })
            ToolTile("대비", Icon.contrast, choices: { MenuItems.contrast(viewer) })
            ToolTile("원래 그림으로", Icon.originalPicture) { MenuItems.restorePicture(viewer) }
        }
    }

    @ViewBuilder private func basic(_ context: EditingContext) -> some View {
        ToolTile("저장하기", Icon.save) { send(#selector(NSDocument.save(_:))) }
        RowDivider()
        clipboard(context)
        ToolTile("모양 복사", Icon.styleCopy) { viewer.paintFormat() }
            .disabled(!context.canFormat)
        RowDivider()
        find
        RowDivider()
        ToolTile("도형", Icon.shape, choices: { MenuItems.shapeChoices(viewer) })
            .disabled(!context.inBody)
        ToolTile("그림", Icon.picture) { viewer.insertPicture() }
            .disabled(!context.canPicture)
        ToolTile("표", Icon.table, action: { viewer.insertingTable = true }, panel: AnyView(TableGrid(viewer: viewer)))
            .disabled(!context.inBody)
        RowDivider()
        notes(context)
        RowDivider()
        ToolTile("문자표", Icon.symbols) { viewer.insertingSymbols = true }
            .disabled(!context.hasSelection)
        RowDivider()
        shapes(context)
        RowDivider()
        objectProperties(context)
        RowDivider()
        headers(context)
        MarkTiles(viewer: viewer)
    }

    @ViewBuilder private func edit(_ context: EditingContext) -> some View {
        ToolTile("되돌리기", Icon.undo) { send(Selector(("undo:"))) }
            .disabled(!context.canUndo)
        ToolTile("다시 실행", Icon.redo) { send(Selector(("redo:"))) }
            .disabled(!context.canRedo)
        RowDivider()
        clipboard(context)
        ToolTile("모양 복사", Icon.styleCopy) { viewer.paintFormat() }
            .disabled(!context.canFormat)
        ToolTile("지우기", Icon.delete) { viewer.canvas.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
            .disabled(context.locked || (!context.hasRange && context.object == nil))
        RowDivider()
        ToolTile("모두 선택", Icon.selectAll) { send(#selector(NSText.selectAll(_:))) }
            .disabled(!context.hasSelection)
        RowDivider()
        find
        ToolTile("찾아 바꾸기", Icon.replace) { viewer.showFind(replace: true) }
        ToolTile("찾아가기", Icon.goTo) { viewer.goingToPage = true }
    }

    @ViewBuilder private var view: some View {
        ToolTile("확대/축소", Icon.zoom, choices: {
            [50, 75, 100, 125, 150, 200, 300].map { percent in
                Choice(title: "\(percent)%", on: viewer.position.zoomPercent == percent && viewer.canvas.fit == nil) {
                    viewer.canvas.setZoom(CGFloat(percent) / 100)
                }
            } + [nil, Choice(title: "쪽 맞춤", on: viewer.canvas.fit == .page) { viewer.canvas.fit(.page) },
                 Choice(title: "폭 맞춤", on: viewer.canvas.fit == .width) { viewer.canvas.fit(.width) }]
        })
        ToolTile("쪽 모양", Icon.pageLayout, choices: {
            [(1, "한 쪽"), (2, "두 쪽"), (3, "세 쪽")].map { count, title in
                Choice(title: title, on: viewer.columns == count) { viewer.columns = count }
            }
        })
        RowDivider()
        MarkTiles(viewer: viewer)
    }

    @ViewBuilder private func insert(_ context: EditingContext) -> some View {
        ToolTile("도형", Icon.shape, choices: { MenuItems.shapeChoices(viewer) })
            .disabled(!context.inBody)
        ToolTile("그림", Icon.picture) { viewer.insertPicture() }
            .disabled(!context.canPicture)
        Group {
            ToolTile("표", Icon.table, action: { viewer.insertingTable = true }, panel: AnyView(TableGrid(viewer: viewer)))
            ToolTile("글상자", Icon.textbox) { viewer.draw("textbox") }
        }
        .disabled(!context.inBody)
        ToolTile("수식", Icon.equation) { viewer.newEquation() }
            .disabled(!context.canPicture)
        ToolTile("문자표", Icon.symbols) { viewer.insertingSymbols = true }
            .disabled(!context.hasSelection)
        RowDivider()
        notes(context)
        RowDivider()
        ToolTile("캡션 넣기", Icon.caption, choices: {
            Captions.all.map { caption in Choice(title: caption.title) { viewer.insertCaption(caption.value) } }
        })
        .disabled(!context.canCaption)
    }

    @ViewBuilder private func format(_ context: EditingContext) -> some View {
        shapes(context)
        RowDivider()
        Group {
            ToolTile("한 수준 증가", Icon.levelUp) { viewer.canvas.editor.stepLevel(by: 1) }
            ToolTile("한 수준 감소", Icon.levelDown) { viewer.canvas.editor.stepLevel(by: -1) }
        }
        .disabled(!context.canFormat || !context.inList)
        RowDivider()
        objectProperties(context)
    }

    @ViewBuilder private func page(_ context: EditingContext) -> some View {
        ToolTile("편집 용지", Icon.pageSetup) { viewer.showPageSetup() }
            .disabled(context.locked)
        RowDivider()
        headers(context)
        RowDivider()
        Group {
            ToolTile("쪽 나누기", Icon.pageBreak) { viewer.insertBreak(column: false) }
            ToolTile("단 나누기", Icon.columnBreak) { viewer.insertBreak(column: true) }
        }
        .disabled(!context.inBody)
    }

    @ViewBuilder private func table(_ context: EditingContext) -> some View {
        ToolTile("표", Icon.table, action: { viewer.insertingTable = true }, panel: AnyView(TableGrid(viewer: viewer)))
            .disabled(!context.inBody)
        ToolTile("표/셀 속성", Icon.objectProps) { viewer.showObjectProperties() }
            .disabled(!context.inTable)
        RowDivider()
        Group {
            ToolTile("줄/칸 추가하기", Icon.insertRow, choices: {
                [Choice(title: "위쪽에 줄 추가하기") { viewer.editTable(.insertRowAbove) },
                 Choice(title: "아래쪽에 줄 추가하기") { viewer.editTable(.insertRowBelow) }, nil,
                 Choice(title: "왼쪽에 칸 추가하기") { viewer.editTable(.insertColumnLeft) },
                 Choice(title: "오른쪽에 칸 추가하기") { viewer.editTable(.insertColumnRight) }]
            })
            ToolTile("줄/칸 지우기", Icon.deleteRow, choices: {
                [Choice(title: "줄 지우기") { viewer.editTable(.deleteRow) }, nil,
                 Choice(title: "칸 지우기") { viewer.editTable(.deleteColumn) }]
            })
            RowDivider()
            ToolTile("셀 나누기", Icon.splitCells) { viewer.splittingCells = true }
        }
        .disabled(!context.inTable)
        Group {
            ToolTile("셀 합치기", Icon.mergeCells) { viewer.editCells { .mergeCells($0) } }
            ToolTile("셀 높이를 같게", Icon.equalHeight) { viewer.editCells { .equalizeCells($0, height: true) } }
            ToolTile("셀 너비를 같게", Icon.equalWidth) { viewer.editCells { .equalizeCells($0, height: false) } }
            ToolTile("블록 계산식", Icon.blockCalculation, choices: {
                MenuItems.blockFunctions.map { function in
                    Choice(title: function.title) { viewer.editCells { .calculateBlock($0, function.function) } }
                }
            })
        }
        .disabled(!context.cellBlock)
    }

    // MARK: Groups shared by tabs

    @ViewBuilder private func clipboard(_ context: EditingContext) -> some View {
        ToolTile("오려 두기", Icon.cut) { send(#selector(NSText.cut(_:))) }
            .disabled(context.locked || (!context.hasRange && context.object == nil))
        ToolTile("복사하기", Icon.copy) { send(#selector(NSText.copy(_:))) }
            .disabled(!context.hasRange && context.object == nil)
        ToolTile("붙이기", Icon.paste) { send(#selector(NSText.paste(_:))) }
            .disabled(!context.hasSelection || context.locked)
    }
    private var find: some View {
        ToolTile("찾기", Icon.find, action: { viewer.showFind(replace: false) }, choices: { MenuItems.findChoices(viewer) })
    }
    @ViewBuilder private func notes(_ context: EditingContext) -> some View {
        Group {
            ToolTile("각주", Icon.footnote) { viewer.insertNote(endnote: false) }
            ToolTile("미주", Icon.endnote) { viewer.insertNote(endnote: true) }
        }
        .disabled(!context.inBody)
    }
    @ViewBuilder private func shapes(_ context: EditingContext) -> some View {
        Group {
            ToolTile("글자 모양", Icon.charShape) { viewer.editingCharShape = true }
            ToolTile("문단 모양", Icon.paraShape) { viewer.editingParaShape = true }
        }
        .disabled(!context.canFormat)
    }
    private func objectProperties(_ context: EditingContext) -> some View {
        ToolTile("개체 속성", Icon.objectProps) { viewer.showObjectProperties() }
            .disabled(context.locked || (context.object == nil && !context.inTable))
    }
    @ViewBuilder private func headers(_ context: EditingContext) -> some View {
        Group {
            ToolTile("머리말", Icon.header, choices: { MenuItems.headerChoices(viewer, footer: false) })
            ToolTile("꼬리말", Icon.footer, choices: { MenuItems.headerChoices(viewer, footer: true) })
        }
        .disabled(context.locked)
    }
}

/// 조판 부호, 문단 부호 and 격자 보기, lit while shown. Apart so only they follow the viewer.
private struct MarkTiles: View {
    @ObservedObject var viewer: Viewer
    var body: some View {
        ToolTile("조판 부호", Icon.controlCodes, on: viewer.showsControlCodes) { viewer.showsControlCodes.toggle() }
        ToolTile("문단 부호", Icon.paragraphMarks, on: viewer.showsParagraphMarks) { viewer.showsParagraphMarks.toggle() }
        ToolTile("격자 보기", Icon.grid, on: viewer.showsGrid) { viewer.showsGrid.toggle() }
    }
}

/// SF Symbols shared by the tool rows and the menu bar.
enum Icon {
    static let save = "square.and.arrow.down", cut = "scissors", copy = "doc.on.doc", paste = "clipboard"
    static let styleCopy = "paintbrush", find = "magnifyingglass", replace = "arrow.left.arrow.right"
    static let goTo = "arrow.right.to.line", table = "tablecells", picture = "photo", equation = "function", symbols = "character.book.closed"
    static let charShape = "textformat", paraShape = "text.alignleft"
    static let header = "rectangle.topthird.inset.filled", footer = "rectangle.bottomthird.inset.filled"
    static let footnote = "note.text", endnote = "doc.plaintext"
    static let objectProps = "slider.horizontal.3", pictureEffect = "camera.filters"
    static let brightness = "sun.max", contrast = "circle.lefthalf.filled", originalPicture = "arrow.uturn.backward"
    static let pageSetup = "doc.text", print = "printer", pdf = "arrow.up.document"
    static let pageBreak = "arrow.down.to.line", columnBreak = "arrow.right.to.line.compact"
    static let insertRow = "plus.rectangle", deleteRow = "minus.rectangle"
    static let controlCodes = "chevron.left.forwardslash.chevron.right", paragraphMarks = "paragraphsign"
    static let documentInfo = "info.circle", eraseCodes = "eraser", bookmark = "bookmark", newNumber = "number", pageHide = "eye.slash"
    static let grid = "grid", caption = "text.below.photo", shape = "square.on.circle"
    static let textbox = "character.textbox", rectangle = "rectangle", ellipse = "circle", line = "line.diagonal", arc = "rainbow"
    static let splitCells = "square.split.2x2", mergeCells = "square.dashed"
    static let undo = "arrow.uturn.backward", redo = "arrow.uturn.forward", delete = "delete.left"
    static let selectAll = "selection.pin.in.out", zoom = "plus.magnifyingglass", pageLayout = "rectangle.split.2x1"
    static let levelUp = "increase.indent", levelDown = "decrease.indent"
    static let equalHeight = "arrow.up.and.down.square", equalWidth = "arrow.left.and.right.square"
    static let blockCalculation = "sum"
    static let columns = "rectangle.split.2x1"
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

/// A large icon over its name. With `choices` (a menu) or `panel` (a popover), an
/// arrow under the name opens them, and the icon runs `action` when there is one.
struct ToolTile: View {
    let title: String, symbol: String
    var action: (() -> Void)?
    var choices: (() -> [Choice?])?
    var panel: AnyView?
    /// Lit, for tiles that turn something on.
    var on = false
    @State private var anchor = Anchor()
    @State private var showsPanel = false

    init(_ title: String, _ symbol: String, on: Bool = false, action: @escaping () -> Void) {
        (self.title, self.symbol, self.on, self.action) = (title, symbol, on, action)
    }
    init(_ title: String, _ symbol: String, action: (() -> Void)? = nil,
         choices: (() -> [Choice?])? = nil, panel: AnyView? = nil) {
        (self.title, self.symbol, self.action, self.choices, self.panel) = (title, symbol, action, choices, panel)
    }

    var body: some View {
        if choices == nil, panel == nil {
            Button(action: { action?() }) {
                VStack(spacing: 3) { icon; label(Text(Self.lines(title))) }.tile()
            }
            .buttonStyle(ToolButtonStyle(on: on))
        } else if let action {
            VStack(spacing: 0) {
                Button(action: action) { icon.tile().padding(.bottom, 3) }
                    .buttonStyle(ToolButtonStyle())
                Button(action: open) { label(Text(title), arrow: true).tile(top: 0) }
                    .buttonStyle(ToolButtonStyle())
                    .background(AnchorView(anchor: anchor))
            }
            .popover(isPresented: $showsPanel, arrowEdge: .bottom) { panel }
        } else {
            Button(action: open) {
                VStack(spacing: 3) { icon; label(Text(title), arrow: true) }.tile()
            }
            .buttonStyle(ToolButtonStyle())
            .background(AnchorView(anchor: anchor))
        }
    }

    /// A name on one line over the arrow, or on up to two lines without one, in the same height.
    private func label(_ text: Text, arrow: Bool = false) -> some View {
        VStack(spacing: 0) {
            text.font(.system(size: 12)).multilineTextAlignment(.center).fixedSize()
            if arrow {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).frame(height: 10)
            }
        }
        .frame(height: 30, alignment: .top)
    }
    private var icon: some View {
        Image(systemName: symbol).font(.system(size: 19, weight: .light)).frame(height: 22)
    }
    /// A name of several words on two lines, broken at the space nearest the middle, as
    /// the web tool box writes 글자 모양 and 조판 부호.
    static func lines(_ title: String) -> String {
        let words = title.split(separator: " ")
        guard words.count > 1 else { return title }
        let split = (1..<words.count).min { a, b in
            let width = { (i: Int) in max(words[..<i].joined(separator: " ").count, words[i...].joined(separator: " ").count) }
            return width(a) < width(b)
        }!
        return words[..<split].joined(separator: " ") + "\n" + words[split...].joined(separator: " ")
    }
    private func open() {
        if panel != nil { showsPanel = true } else if let choices { DropDown.show(choices(), below: anchor.view) }
    }
}

private extension View {
    /// As wide as the tile's own name and icon need.
    func tile(top: CGFloat = 3) -> some View {
        frame(minWidth: 32).padding(.top, top).padding(.horizontal, 5)
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
        let y = view.isFlipped ? view.bounds.maxY + 2 : -2
        menu(choices).popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
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
private struct TableGrid: View {
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
