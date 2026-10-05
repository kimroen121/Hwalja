import SwiftUI

// The macOS menu bar follows Hancom Office Web's menus: their order (파일·편집·보기·입력·
// 서식·쪽·표), groups, names and icons. It lists only commands that work
// (docs/ROADMAP.md has the full list); the system's own File and Edit items stay.

/// Sends an action to the focused document through the responder chain.
@MainActor func send(_ action: Selector) {
    NSApp.sendAction(action, to: nil, from: nil)
}

/// The items of each menu, for a window's document and viewer (nil when no window is focused).
@MainActor
struct MenuItems {
    let document: HwpDocument?
    let viewer: Viewer?

    private var context: EditingContext { document?.context ?? EditingContext() }
    private var editor: PageEditor? { viewer?.canvas.editor }
    private func toggle(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
    }
    private func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
    }

    /// The 찾기 drop-down of the tool row; the same commands as the 찾기 menu.
    static func findChoices(_ viewer: Viewer) -> [Choice?] {
        [
            Choice(title: "찾기…", symbol: Icon.find, key: "f") { viewer.showFind(replace: false) },
            Choice(title: "찾아 바꾸기…", symbol: Icon.replace, key: "f", modifiers: [.command, .option]) {
                viewer.showFind(replace: true)
            },
            Choice(title: "찾아가기…", symbol: Icon.goTo, key: "g", modifiers: [.command, .option]) {
                viewer.goingToPage = true
            },
        ]
    }
    /// 머리말 or 꼬리말 shapes, as in Hancom Office Web.
    static let headerShapes: [(title: String, placement: Placement?)] = [
        ("(모양 없음)", nil), ("왼쪽 쪽 번호", .left), ("가운데 쪽 번호", .center), ("오른쪽 쪽 번호", .right),
    ]
    static func headerChoices(_ viewer: Viewer, footer: Bool) -> [Choice?] {
        headerShapes.map { shape in
            Choice(title: shape.title, symbol: Icon.placement(shape.placement)) {
                viewer.headerFooter(footer: footer, pageNumber: shape.placement)
            }
        }
    }

    /// 파일 items beyond the system's New, Open, Save and Revert.
    @ViewBuilder var file: some View {
        item("PDF로 내보내기…", Icon.pdf) { send(#selector(DocumentCanvas.exportAsPDF(_:))) }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        Divider()
        item("편집 용지…", Icon.pageSetup) { viewer?.showPageSetup() }
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), modifiers: [])
            .disabled(viewer == nil)
        item("프린트…", Icon.print) { send(#selector(DocumentCanvas.printDocument(_:))) }
            .keyboardShortcut("p")
    }

    /// 편집 items after the system's clipboard commands.
    @ViewBuilder var styleCopy: some View {
        item("모양 복사", Icon.styleCopy) { viewer?.paintFormat() }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!context.hasSelection)
    }
    @ViewBuilder var find: some View {
        Group {
            item("찾기…", Icon.find) { viewer?.showFind(replace: false) }
                .keyboardShortcut("f")
            item("찾아 바꾸기…", Icon.replace) { viewer?.showFind(replace: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            item("찾아가기…", Icon.goTo) { viewer?.goingToPage = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Divider()
            Button("다음 찾기") { viewer?.findNext() }
                .keyboardShortcut("g")
            Button("이전 찾기") { viewer?.findNext(backward: true) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("선택 부분으로 찾기") { viewer?.findSelection() }
                .keyboardShortcut("e")
        }
        .disabled(viewer == nil)
    }

    @ViewBuilder var view: some View {
        if let viewer {
            Menu {
                Button("확대") { send(#selector(DocumentCanvas.zoomIn(_:))) }.keyboardShortcut("+")
                Button("축소") { send(#selector(DocumentCanvas.zoomOut(_:))) }.keyboardShortcut("-")
                Button("실제 크기") { send(#selector(DocumentCanvas.zoomToActualSize(_:))) }.keyboardShortcut("0")
                Divider()
                ZoomItems(viewer: viewer, position: viewer.position)
            } label: { Label("확대/축소", systemImage: "plus.magnifyingglass") }
            Menu {
                ForEach([(1, "한 쪽"), (2, "두 쪽"), (3, "세 쪽")], id: \.0) { count, title in
                    toggle(title, viewer.columns == count) { viewer.columns = count }
                }
            } label: { Label("쪽 모양", systemImage: "rectangle.split.2x1") }
            Divider()
            Menu {
                toggle("기본", viewer.showsTools) { viewer.showsTools.toggle() }
                toggle("서식", viewer.showsFormat) { viewer.showsFormat.toggle() }
            } label: { Label("도구 상자", systemImage: "menubar.rectangle") }
            Button(viewer.showsThumbnails ? "사이드바 가리기" : "사이드바 보기") { viewer.showsThumbnails.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }

    @ViewBuilder var insert: some View {
        Group {
            item("표…", Icon.table) { viewer?.insertingTable = true }
                .disabled(!context.hasSelection || context.inTable)
            Divider()
            item("문자표…", Icon.symbols) { NSApp.orderFrontCharacterPalette(nil) }
                .disabled(!context.hasSelection)
        }
    }

    @ViewBuilder var format: some View {
        let text = document?.format?.text
        Group {
            item("글자 모양…", Icon.charShape) { viewer?.editingCharShape = true }.keyboardShortcut("l")
            Divider()
            item("문단 모양…", Icon.paraShape) { viewer?.editingParaShape = true }.keyboardShortcut("t")
        }
        .disabled(!context.hasSelection)
        Divider()
        Group {
            toggle("진하게", text?.bold == true) { editor?.toggleBold() }.keyboardShortcut("b")
            toggle("기울임", text?.italic == true) { editor?.toggleItalic() }.keyboardShortcut("i")
            toggle("밑줄", text?.underline == true) { editor?.toggleUnderline() }.keyboardShortcut("u")
            toggle("취소선", text?.strikethrough == true) { editor?.toggleStrikethrough() }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Button("글자 크게") { editor?.stepFontSize(by: 1) }.keyboardShortcut(".", modifiers: [.command, .shift])
            Button("글자 작게") { editor?.stepFontSize(by: -1) }.keyboardShortcut(",", modifiers: [.command, .shift])
        }
        .disabled(!context.hasSelection)
        Divider()
        Group {
            ForEach(Alignment.allCases, id: \.self) { alignment in
                let shortcut: KeyboardShortcut? = switch alignment {
                case .left: KeyboardShortcut("[", modifiers: [.command, .shift])
                case .center: KeyboardShortcut("\\", modifiers: [.command, .shift])
                case .right: KeyboardShortcut("]", modifiers: [.command, .shift])
                case .justify: KeyboardShortcut("\\", modifiers: [.command, .option, .shift])
                default: nil
                }
                toggle(FormatChoices.label(alignment).title, document?.format?.paragraph.alignment == alignment) {
                    editor?.setAlignment(alignment)
                }
                .keyboardShortcut(shortcut)
            }
            Menu("줄 간격") {
                ForEach(FormatChoices.lineSpacings, id: \.self) { percent in
                    toggle("\(Int(percent))%", document?.format?.paragraph.lineSpacing == percent) {
                        editor?.setLineSpacing(percent)
                    }
                }
            }
        }
        .disabled(!context.hasSelection)
    }

    @ViewBuilder var page: some View {
        item("편집 용지…", Icon.pageSetup) { viewer?.showPageSetup() }
            .disabled(viewer == nil)
        Divider()
        Group {
            Menu { headerItems(footer: false) } label: { Label("머리말", systemImage: Icon.header) }
            Menu { headerItems(footer: true) } label: { Label("꼬리말", systemImage: Icon.footer) }
        }
        .disabled(viewer == nil)
        Divider()
        Group {
            item("쪽 나누기", Icon.pageBreak) { viewer?.insertBreak(column: false) }
                .keyboardShortcut(.return)
            item("단 나누기", Icon.columnBreak) { viewer?.insertBreak(column: true) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
        .disabled(!context.hasSelection || context.inTable)
    }
    private func headerItems(footer: Bool) -> some View {
        ForEach(Self.headerShapes, id: \.title) { shape in
            item(shape.title, Icon.placement(shape.placement)) {
                viewer?.headerFooter(footer: footer, pageNumber: shape.placement)
            }
        }
    }

    @ViewBuilder var table: some View {
        item("표 만들기…", Icon.table) { viewer?.insertingTable = true }
            .disabled(!context.hasSelection || context.inTable)
        Divider()
        Group {
            Menu {
                Button("위쪽에 줄 추가하기") { viewer?.editTable(.insertRowAbove) }
                Button("아래쪽에 줄 추가하기") { viewer?.editTable(.insertRowBelow) }
                Divider()
                Button("왼쪽에 칸 추가하기") { viewer?.editTable(.insertColumnLeft) }
                Button("오른쪽에 칸 추가하기") { viewer?.editTable(.insertColumnRight) }
            } label: { Label("줄/칸 추가하기", systemImage: Icon.insertRow) }
            Menu {
                Button("줄 지우기") { viewer?.editTable(.deleteRow) }
                Divider()
                Button("칸 지우기") { viewer?.editTable(.deleteColumn) }
            } label: { Label("줄/칸 지우기", systemImage: Icon.deleteRow) }
        }
        .disabled(!context.inTable)
    }
}

/// The macOS menu bar.
struct MenuBarCommands: Commands {
    @FocusedObject private var document: HwpDocument?
    @FocusedObject private var viewer: Viewer?
    private var items: MenuItems { MenuItems(document: document, viewer: viewer) }

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            items.file
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .pasteboard) {
            Divider()
            items.styleCopy
        }
        CommandGroup(replacing: .textEditing) {
            Menu { items.find } label: { Label("찾기", systemImage: Icon.find) }
        }
        CommandGroup(after: .toolbar) {
            items.view
            Divider()
        }
        CommandMenu("입력") { items.insert }
        CommandMenu("서식") { items.format }
        CommandMenu("쪽") { items.page }
        CommandMenu("표") { items.table }
    }
}
