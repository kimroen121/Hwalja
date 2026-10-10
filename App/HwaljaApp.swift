import SwiftUI

@main
struct HwaljaApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { HwpDocument() }) { file in
            DocumentWindow(document: file.document)
        }
        .commands {
            MenuBarCommands()
            SidebarCommands()
            ToolbarCommands()
        }
        Settings { SettingsView() }
    }
}
