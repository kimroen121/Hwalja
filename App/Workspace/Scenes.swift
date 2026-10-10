import SwiftUI

/// The app's scenes; in the library so the views can be previewed in Xcode.
public struct HwaljaScenes: Scene {
    public init() {}

    public var body: some Scene {
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
