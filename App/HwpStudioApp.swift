import SwiftUI

@main
struct HwpStudioApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    var body: some Scene { WindowGroup { WorkspaceView() } }
}

/// Receives Finder/`open` documents, including the ones that launch the app,
/// which arrive before any SwiftUI view can observe `onOpenURL`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var openedURL: URL?
    func application(_ application: NSApplication, open urls: [URL]) { openedURL = urls.first }
}
