import SwiftUI

// Menus follow Hancom Office Web's menus in order (파일·편집·보기·입력·서식·쪽·표) and list
// only commands that work (docs/ROADMAP.md has the full list). The same items fill the
// macOS menu bar and the window's menu row; only the menu bar carries key equivalents.

/// Sends an action to the focused document through the responder chain.
@MainActor func send(_ action: Selector) {
    NSApp.sendAction(action, to: nil, from: nil)
}

/// The items of each menu, for a window's document and viewer (nil when no window is focused).
@MainActor
struct MenuItems {
    let document: HwpDocument?
    let viewer: Viewer?
    /// Whether items carry key equivalents (menu bar only).
    let shortcuts: Bool

    private var context: EditingContext { document?.context ?? EditingContext() }
    private var editor: PageEditor? { viewer?.canvas.editor }
    private func key(_ key: KeyEquivalent, _ modifiers: EventModifiers = .command) -> KeyboardShortcut? {
        shortcuts ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }
    private func toggle(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
    }

    /// File items beyond the system's New, Open, Save and Revert.
    @ViewBuilder var file: some View {
        Button("PDF로 내보내기…") { send(#selector(DocumentCanvas.exportAsPDF(_:))) }
            .keyboardShortcut(key("e", [.command, .shift]))
        Button("편집 용지…") { viewer?.showPageSetup() }
            .keyboardShortcut(key(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), []))
            .disabled(viewer == nil)
        Button("프린트…") { send(#selector(DocumentCanvas.printDocument(_:))) }
            .keyboardShortcut(key("p"))
    }
    /// The whole File menu for the window's menu row.
    @ViewBuilder var fileMenu: some View {
        Button("새 문서") { NSDocumentController.shared.newDocument(nil) }
        Button("열기…") { NSDocumentController.shared.openDocument(nil) }
        Divider()
        Button("저장하기") { send(#selector(NSDocument.save(_:))) }
        Button("다른 이름으로 저장하기…") { send(#selector(NSDocument.saveAs(_:))) }
        Divider()
        file
    }

    @ViewBuilder var styleCopy: some View {
        Button("모양 복사") { editor?.copyFont(nil) }
            .keyboardShortcut(key("c", [.command, .option]))
            .disabled(document?.format == nil)
        Button("모양 붙이기") { editor?.pasteFont(nil) }
            .keyboardShortcut(key("v", [.command, .option]))
            .disabled(!context.hasRange || PageEditor.copiedStyle == nil)
    }
    @ViewBuilder var find: some View {
        Group {
            Button("찾기…") { viewer?.showFind(replace: false) }
                .keyboardShortcut(key("f"))
            Button("찾아 바꾸기…") { viewer?.showFind(replace: true) }
                .keyboardShortcut(key("f", [.command, .option]))
            Button("다음 찾기") { viewer?.findNext() }
                .keyboardShortcut(key("g"))
            Button("이전 찾기") { viewer?.findNext(backward: true) }
                .keyboardShortcut(key("g", [.command, .shift]))
            Button("선택 부분으로 찾기") { viewer?.findSelection() }
                .keyboardShortcut(key("e"))
            Button("쪽으로 이동…") { viewer?.goingToPage = true }
                .keyboardShortcut(key("g", [.command, .option]))
        }
        .disabled(viewer == nil)
    }
    /// The whole Edit menu for the window's menu row.
    @ViewBuilder var editMenu: some View {
        Button("되돌리기") { send(Selector(("undo:"))) }.disabled(!context.canUndo)
        Button("다시 실행") { send(Selector(("redo:"))) }.disabled(!context.canRedo)
        Divider()
        Group {
            Button("오려 두기") { send(#selector(NSText.cut(_:))) }
            Button("복사하기") { send(#selector(NSText.copy(_:))) }
        }
        .disabled(!context.hasRange)
        Button("붙이기") { send(#selector(NSText.paste(_:))) }.disabled(!context.hasSelection)
        Button("지우기") { send(#selector(NSText.delete(_:))) }.disabled(!context.hasRange)
        Divider()
        styleCopy
        Divider()
        Button("모두 선택") { send(#selector(NSText.selectAll(_:))) }.disabled(!context.hasSelection)
        Divider()
        find
    }

    @ViewBuilder var view: some View {
        if let viewer {
            Menu("확대/축소") { ZoomItems(viewer: viewer, position: viewer.position) }
            Menu("쪽 모양") {
                ForEach([(1, "한 쪽"), (2, "두 쪽"), (3, "세 쪽")], id: \.0) { count, title in
                    toggle(title, viewer.columns == count) { viewer.columns = count }
                }
            }
            Menu("도구 상자") {
                toggle("기본", viewer.showsTools) { viewer.showsTools.toggle() }
                toggle("서식", viewer.showsFormat) { viewer.showsFormat.toggle() }
            }
            toggle("쪽 미리 보기", viewer.showsThumbnails) { viewer.showsThumbnails.toggle() }
        }
    }
    /// The whole View menu for the window's menu row.
    @ViewBuilder var viewMenu: some View {
        Button("실제 크기") { send(#selector(DocumentCanvas.zoomToActualSize(_:))) }
        Button("확대") { send(#selector(DocumentCanvas.zoomIn(_:))) }
        Button("축소") { send(#selector(DocumentCanvas.zoomOut(_:))) }
        Divider()
        view
    }

    @ViewBuilder var insert: some View {
        Button("표…") { viewer?.insertingTable = true }
            .disabled(!context.hasSelection || context.inTable)
        Button("문자표…") { NSApp.orderFrontCharacterPalette(nil) }
            .disabled(!context.hasSelection)
    }

    @ViewBuilder var format: some View {
        let text = document?.format?.text
        Group {
            toggle("굵게", text?.bold == true) { editor?.toggleBold() }.keyboardShortcut(key("b"))
            toggle("기울임꼴", text?.italic == true) { editor?.toggleItalic() }.keyboardShortcut(key("i"))
            toggle("밑줄", text?.underline == true) { editor?.toggleUnderline() }.keyboardShortcut(key("u"))
            toggle("취소선", text?.strikethrough == true) { editor?.toggleStrikethrough() }
                .keyboardShortcut(key("x", [.command, .shift]))
            Divider()
            Button("글자 크게") { editor?.stepFontSize(by: 1) }.keyboardShortcut(key(".", [.command, .shift]))
            Button("글자 작게") { editor?.stepFontSize(by: -1) }.keyboardShortcut(key(",", [.command, .shift]))
        }
        .disabled(!context.hasRange)
        Divider()
        Group {
            ForEach(Alignment.allCases, id: \.self) { alignment in
                let shortcut: KeyboardShortcut? = switch alignment {
                case .left: key("[", [.command, .shift])
                case .center: key("\\", [.command, .shift])
                case .right: key("]", [.command, .shift])
                case .justify: key("\\", [.command, .option, .shift])
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
        Button("편집 용지…") { viewer?.showPageSetup() }
            .disabled(viewer == nil)
        Divider()
        Group {
            Button("쪽 나누기") { viewer?.insertBreak(column: false) }
                .keyboardShortcut(key(.return))
            Button("단 나누기") { viewer?.insertBreak(column: true) }
                .keyboardShortcut(key(.return, [.command, .shift]))
        }
        .disabled(!context.hasSelection || context.inTable)
    }

    @ViewBuilder var table: some View {
        Button("표 만들기…") { viewer?.insertingTable = true }
            .disabled(!context.hasSelection || context.inTable)
        Divider()
        Group {
            Menu("줄/칸 추가하기") {
                Button("위쪽에 줄 추가하기") { viewer?.editTable(.insertRowAbove) }
                Button("아래쪽에 줄 추가하기") { viewer?.editTable(.insertRowBelow) }
                Button("왼쪽에 칸 추가하기") { viewer?.editTable(.insertColumnLeft) }
                Button("오른쪽에 칸 추가하기") { viewer?.editTable(.insertColumnRight) }
            }
            Menu("줄/칸 지우기") {
                Button("줄 지우기") { viewer?.editTable(.deleteRow) }
                Button("칸 지우기") { viewer?.editTable(.deleteColumn) }
            }
        }
        .disabled(!context.inTable)
    }
}

/// The macOS menu bar.
struct MenuBarCommands: Commands {
    @FocusedObject private var document: HwpDocument?
    @FocusedObject private var viewer: Viewer?
    private var items: MenuItems { MenuItems(document: document, viewer: viewer, shortcuts: true) }

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
            Menu("찾기") { items.find }
        }
        CommandGroup(after: .toolbar) {
            Button("실제 크기") { send(#selector(DocumentCanvas.zoomToActualSize(_:))) }
                .keyboardShortcut("0")
            Button("확대") { send(#selector(DocumentCanvas.zoomIn(_:))) }
                .keyboardShortcut("+")
            Button("축소") { send(#selector(DocumentCanvas.zoomOut(_:))) }
                .keyboardShortcut("-")
            Button("쪽 맞춤") { send(#selector(DocumentCanvas.zoomToFit(_:))) }
                .keyboardShortcut("9")
            items.view
            Divider()
        }
        CommandMenu("입력") { items.insert }
        CommandMenu("서식") { items.format }
        CommandMenu("쪽") { items.page }
        CommandMenu("표") { items.table }
    }
}
