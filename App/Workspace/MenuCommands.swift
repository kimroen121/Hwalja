import SwiftUI

// The menu bar follows Hancom Office Web's menus in order (파일·편집·보기·입력·서식·쪽·표)
// and lists only commands that work. See docs/ROADMAP.md for the full list.

/// Sends a menu command to the focused document's canvas through the responder chain.
@MainActor private func send(_ action: Selector) {
    NSApp.sendAction(action, to: nil, from: nil)
}

struct FileCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button("PDF로 내보내기…") { send(#selector(DocumentCanvas.exportAsPDF(_:))) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .printItem) {
            Button("프린트…") { send(#selector(DocumentCanvas.printDocument(_:))) }
                .keyboardShortcut("p")
        }
    }
}

struct EditCommands: Commands {
    @FocusedObject private var document: HwpDocument?
    @FocusedObject private var viewer: Viewer?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            let editor = viewer?.canvas.editor
            let hasRange = document?.selection.map { $0.anchor != $0.focus } ?? false
            Divider()
            Button("모양 복사") { editor?.copyFont(nil) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(document?.format == nil)
            Button("모양 붙이기") { editor?.pasteFont(nil) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!hasRange || PageEditor.copiedStyle == nil)
        }
        CommandGroup(replacing: .textEditing) {
            Menu("찾기") {
                Button("찾기…") { viewer?.showFind(replace: false) }
                    .keyboardShortcut("f")
                Button("찾아 바꾸기…") { viewer?.showFind(replace: true) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("다음 찾기") { viewer?.findNext() }
                    .keyboardShortcut("g")
                Button("이전 찾기") { viewer?.findNext(backward: true) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("선택 부분으로 찾기") { viewer?.findSelection() }
                    .keyboardShortcut("e")
            }
            .disabled(viewer == nil)
            Button("쪽으로 이동…") { viewer?.goingToPage = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(viewer == nil)
        }
    }
}

struct ViewCommands: Commands {
    @FocusedObject private var viewer: Viewer?

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("실제 크기") { send(#selector(DocumentCanvas.zoomToActualSize(_:))) }
                .keyboardShortcut("0")
            Button("확대") { send(#selector(DocumentCanvas.zoomIn(_:))) }
                .keyboardShortcut("+")
            Button("축소") { send(#selector(DocumentCanvas.zoomOut(_:))) }
                .keyboardShortcut("-")
            Button("쪽 맞춤") { send(#selector(DocumentCanvas.zoomToFit(_:))) }
                .keyboardShortcut("9")
            if let viewer {
                Menu("확대/축소") { ZoomItems(viewer: viewer) }
                Menu("쪽 모양") {
                    ForEach([(1, "한 쪽"), (2, "두 쪽"), (3, "세 쪽")], id: \.0) { count, title in
                        Toggle(title, isOn: Binding(get: { viewer.columns == count }, set: { _ in viewer.columns = count }))
                    }
                }
            }
            Divider()
        }
    }
}
