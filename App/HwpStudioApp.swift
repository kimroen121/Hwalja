import SwiftUI

@main
struct HwpStudioApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { HwpDocument() }) { file in
            DocumentWindow(document: file.document)
        }
        .commands { MenuBarCommands() }
    }
}
