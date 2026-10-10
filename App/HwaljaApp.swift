import SwiftUI

@main
struct HwaljaApp: App {
    // A run without the bundle (Xcode, swift run) starts as a background process with no windows shown.
    init() { if Bundle.main.bundleURL.pathExtension != "app" { NSApplication.shared.setActivationPolicy(.regular) } }

    var body: some Scene {
        DocumentGroup(newDocument: { HwpDocument() }) { file in
            DocumentWindow(document: file.document)
        }
        .commands {
            MenuBarCommands()
            SidebarCommands()
        }
        Settings { SettingsView() }
    }
}
