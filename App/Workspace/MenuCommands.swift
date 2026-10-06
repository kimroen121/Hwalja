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
    /// 그리기 개체, as in Hancom Office Web's 도형.
    static let shapes: [(title: String, shape: String, symbol: String)] = [
        ("가로 글상자", "textbox", Icon.textbox), ("직사각형", "rectangle", Icon.rectangle),
        ("타원", "ellipse", Icon.ellipse), ("직선", "line", Icon.line), ("호", "arc", Icon.arc),
    ]
    static func shapeChoices(_ viewer: Viewer) -> [Choice?] {
        shapes.map { item in Choice(title: item.title, symbol: item.symbol) { viewer.draw(item.shape) } }
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

    /// 그림 drop-downs: 색조 조정, 밝기 and 대비, as in Hancom Office Web.
    static func pictureEffects(_ viewer: Viewer) -> [Choice?] {
        [("효과 없음", "RealPic"), ("회색조", "GrayScale"), ("흑백", "BlackWhite")].map { title, effect in
            Choice(title: title) { viewer.adjustPicture { $0.effect = effect } }
        } + [Choice(title: "워터마크") {
            viewer.adjustPicture { ($0.effect, $0.brightness, $0.contrast) = ("RealPic", 70, -50) }
        }]
    }
    static func brightness(_ viewer: Viewer) -> [Choice?] {
        steps(viewer, \.brightness, more: "밝게", less: "어둡게", none: "밝기 없음")
    }
    static func contrast(_ viewer: Viewer) -> [Choice?] {
        steps(viewer, \.contrast, more: "선명하게", less: "희미하게", none: "대비 없음")
    }
    private static func steps(_ viewer: Viewer, _ key: WritableKeyPath<ObjectProps, Int32?>,
                              more: String, less: String, none: String) -> [Choice?] {
        [
            Choice(title: more) { viewer.adjustPicture { $0[keyPath: key] = min(100, ($0[keyPath: key] ?? 0) + 10) } },
            Choice(title: less) { viewer.adjustPicture { $0[keyPath: key] = max(-100, ($0[keyPath: key] ?? 0) - 10) } },
            nil,
            Choice(title: none) { viewer.adjustPicture { $0[keyPath: key] = 0 } },
        ]
    }
    /// 원래 그림으로: no effect, crop or turn, at the size it was put in.
    static func restorePicture(_ viewer: Viewer) {
        viewer.adjustPicture { props in
            (props.effect, props.brightness, props.contrast, props.rotationAngle) = ("RealPic", 0, 0, 0)
            (props.cropLeft, props.cropRight, props.cropTop, props.cropBottom) = (0, 0, 0, 0)
            (props.width, props.height) = (props.originalWidth ?? props.width, props.originalHeight ?? props.height)
        }
    }

    /// 빠른 메뉴 (right click), in Hancom Office Web's order and names, for what the
    /// selection is: text, an object, or cells.
    static func quickMenu(_ viewer: Viewer, _ context: EditingContext) -> [Choice?] {
        let editor = viewer.canvas.editor
        let selected = context.hasRange || context.object != nil
        var items: [Choice?] = [
            Choice(title: "오려 두기", symbol: Icon.cut, key: "x", enabled: context.hasRange) { send(#selector(PageEditor.cut(_:))) },
            Choice(title: "복사하기", symbol: Icon.copy, key: "c", enabled: context.hasRange) { send(#selector(PageEditor.copy(_:))) },
            Choice(title: "붙이기", symbol: Icon.paste, key: "v", enabled: context.hasSelection) { send(#selector(PageEditor.paste(_:))) },
        ]
        if selected {
            items.append(Choice(title: "지우기") { editor.doCommand(by: #selector(NSResponder.deleteBackward(_:))) })
        }
        if context.canFormat, context.object == nil {
            items += [
                nil,
                Choice(title: "글자 모양…", symbol: Icon.charShape, key: "l") { viewer.editingCharShape = true },
                Choice(title: "문단 모양…", symbol: Icon.paraShape, key: "t") { viewer.editingParaShape = true },
            ]
        }
        if let shape = viewer.document?.object, shape.object.kind == .shape {
            items += [nil, Choice(title: "순서", submenu: [
                Choice(title: "맨 앞으로") { viewer.change { .order($0, .front) } },
                Choice(title: "앞으로") { viewer.change { .order($0, .forward) } },
                Choice(title: "맨 뒤로") { viewer.change { .order($0, .back) } },
                Choice(title: "뒤로") { viewer.change { .order($0, .backward) } },
            ])]
            if shape.group {
                items.append(Choice(title: "개체 풀기") { viewer.change { .ungroup($0) } })
            }
            switch shape.textBox {
            case false?: items.append(Choice(title: "도형 안에 글자 넣기") { viewer.change { .setTextBox($0, attach: true) } })
            case true?: items.append(Choice(title: "글상자 속성 없애기") { viewer.change { .setTextBox($0, attach: false) } })
            case nil: break
            }
        }
        if context.inTable, context.object == nil {
            let block = context.cellBlock
            items += [
                nil,
                Choice(title: "표/셀 속성…", symbol: Icon.objectProps) { viewer.showObjectProperties() },
                Choice(title: "셀 높이를 같게", key: "h", modifiers: [], enabled: block) {
                    viewer.editCells { .equalizeCells($0, height: true) }
                },
                Choice(title: "셀 너비를 같게", key: "w", modifiers: [], enabled: block) {
                    viewer.editCells { .equalizeCells($0, height: false) }
                },
                Choice(title: "셀 합치기", symbol: Icon.mergeCells, key: "m", modifiers: [], enabled: block) {
                    viewer.editCells { .mergeCells($0) }
                },
                Choice(title: "셀 나누기…", symbol: Icon.splitCells, key: "s", modifiers: []) { viewer.splittingCells = true },
                Choice(title: "줄/칸 추가하기", symbol: Icon.insertRow, submenu: [
                    Choice(title: "위쪽에 줄 추가하기") { viewer.editTable(.insertRowAbove) },
                    Choice(title: "아래쪽에 줄 추가하기") { viewer.editTable(.insertRowBelow) },
                    Choice(title: "왼쪽에 칸 추가하기") { viewer.editTable(.insertColumnLeft) },
                    Choice(title: "오른쪽에 칸 추가하기") { viewer.editTable(.insertColumnRight) },
                ]),
                Choice(title: "줄/칸 지우기", symbol: Icon.deleteRow, submenu: [
                    Choice(title: "줄 지우기") { viewer.editTable(.deleteRow) },
                    Choice(title: "칸 지우기") { viewer.editTable(.deleteColumn) },
                ]),
            ]
        }
        if context.canCaption {
            items += [
                nil,
                Choice(title: "캡션 넣기", symbol: Icon.caption) { viewer.insertCaption("Bottom") },
                Choice(title: "캡션 지우기") { viewer.insertCaption("None") },
            ]
        }
        if context.object == .picture {
            items += [
                nil,
                Choice(title: "색조 조정", symbol: Icon.pictureEffect, submenu: pictureEffects(viewer)),
                Choice(title: "밝기", symbol: Icon.brightness, submenu: brightness(viewer)),
                Choice(title: "대비", symbol: Icon.contrast, submenu: contrast(viewer)),
                Choice(title: "원래 그림으로", symbol: Icon.originalPicture) { restorePicture(viewer) },
            ]
        }
        if context.object != nil {
            items += [nil, Choice(title: "개체 속성…", symbol: Icon.objectProps, key: "p", modifiers: []) { viewer.showObjectProperties() }]
        }
        return items
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
            .disabled(!context.canFormat)
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
            Menu {
                toggle("조판 부호", viewer.showsControlCodes) { viewer.showsControlCodes.toggle() }
                toggle("문단 부호", viewer.showsParagraphMarks) { viewer.showsParagraphMarks.toggle() }
                toggle("격자 보기", viewer.showsGrid) { viewer.showsGrid.toggle() }
            } label: { Label("표시/숨기기", systemImage: Icon.paragraphMarks) }
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
        Menu {
            ForEach(Self.shapes, id: \.shape) { item in
                self.item(item.title, item.symbol) { viewer?.draw(item.shape) }
            }
        } label: { Label("도형", systemImage: Icon.shape) }
            .disabled(!context.inBody)
        item("그림…", Icon.picture) { viewer?.insertPicture() }
            .disabled(!context.canPicture)
        Group {
            item("표…", Icon.table) { viewer?.insertingTable = true }
            item("글상자", Icon.textbox) { viewer?.draw("textbox") }
            item("수식…", Icon.equation) { viewer?.newEquation() }
        }
        .disabled(!context.inBody)
        Group {
            Divider()
            item("문자표…", Icon.symbols) { NSApp.orderFrontCharacterPalette(nil) }
                .disabled(!context.hasSelection)
            Divider()
            Menu {
                item("각주", Icon.footnote) { viewer?.insertNote(endnote: false) }
                item("미주", Icon.endnote) { viewer?.insertNote(endnote: true) }
            } label: { Label("주석", systemImage: Icon.footnote) }
                .disabled(!context.inBody)
            Menu {
                ForEach(Captions.all, id: \.value) { caption in
                    if caption.value == "None" { Divider() }
                    Button(caption.title) { viewer?.insertCaption(caption.value) }
                }
            } label: { Label("캡션 넣기", systemImage: Icon.caption) }
                .disabled(!context.canCaption)
        }
    }

    @ViewBuilder var format: some View {
        let text = document?.format?.text
        Group {
            item("글자 모양…", Icon.charShape) { viewer?.editingCharShape = true }.keyboardShortcut("l")
            Divider()
            item("문단 모양…", Icon.paraShape) { viewer?.editingParaShape = true }.keyboardShortcut("t")
        }
        .disabled(!context.canFormat)
        Group {
            Button("한 수준 증가") { editor?.stepLevel(by: 1) }
            Button("한 수준 감소") { editor?.stepLevel(by: -1) }
        }
        .disabled(!context.canFormat || !context.inList)
        Divider()
        item("개체 속성…", Icon.objectProps) { viewer?.showObjectProperties() }
            .disabled(context.object == nil && !context.inTable)
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
        .disabled(!context.canFormat)
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
                    editor?.format(ParaStyle(alignment: alignment))
                }
                .keyboardShortcut(shortcut)
            }
            Menu("줄 간격") {
                ForEach(FormatChoices.lineSpacings, id: \.self) { percent in
                    toggle("\(Int(percent))%", document?.format?.paragraph.lineSpacing == percent) {
                        editor?.format(ParaStyle(lineSpacing: percent, lineSpacingKind: .percent))
                    }
                }
            }
        }
        .disabled(!context.canFormat)
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
        .disabled(!context.inBody)
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
            .disabled(!context.inBody)
        item("표/셀 속성…", Icon.objectProps) { viewer?.showObjectProperties() }
            .disabled(!context.inTable)
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
            Divider()
            item("셀 나누기…", Icon.splitCells) { viewer?.splittingCells = true }
        }
        .disabled(!context.inTable)
        Group {
            item("셀 합치기", Icon.mergeCells) { viewer?.editCells { .mergeCells($0) } }
            Button("셀 높이를 같게") { viewer?.editCells { .equalizeCells($0, height: true) } }
            Button("셀 너비를 같게") { viewer?.editCells { .equalizeCells($0, height: false) } }
        }
        .disabled(!context.cellBlock)
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
