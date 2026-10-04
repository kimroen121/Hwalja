import PDFKit
import SwiftUI

@main
struct HwpStudioApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { HwpDocument() }) { file in
            DocumentWindow(document: file.document)
        }
        .commands {
            CommandGroup(after: .saveItem) {
                Divider()
                Button("PDF로 내보내기…") { send(#selector(DocumentCanvas.exportAsPDF(_:))) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .printItem) {
                Button("프린트…") { send(#selector(DocumentCanvas.printDocument(_:))) }
                    .keyboardShortcut("p")
            }
            CommandGroup(after: .toolbar) {
                Button("실제 크기") { send(#selector(DocumentCanvas.zoomToActualSize(_:))) }
                    .keyboardShortcut("0")
                Button("확대") { send(#selector(PDFView.zoomIn(_:))) }
                    .keyboardShortcut("+")
                Button("축소") { send(#selector(PDFView.zoomOut(_:))) }
                    .keyboardShortcut("-")
                Button("쪽 맞춤") { send(#selector(DocumentCanvas.zoomToFit(_:))) }
                    .keyboardShortcut("9")
                Divider()
            }
            FormatCommands()
        }
    }

    /// Menu commands go to the focused document's canvas through the responder chain.
    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
