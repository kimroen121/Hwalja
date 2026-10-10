import AppKit
import SwiftUI

/// Saving as 한/글 does: the file changes only on 저장하기, and 자동 저장 keeps a 복구용 임시
/// 파일 instead, which macOS deletes when the document closes and offers again after a crash.
@MainActor
enum Saving {
    static let timedKey = "autosaveTimed", minutesKey = "autosaveMinutes"
    static let idleKey = "autosaveIdle", secondsKey = "autosaveSeconds"

    /// 무조건 자동 저장's interval in seconds, or nil when it is off.
    static var timed: TimeInterval? { value(timedKey, minutesKey).map { $0 * 60 } }
    /// 쉴 때 자동 저장's rest in seconds, or nil when it is off.
    static var idle: TimeInterval? { value(idleKey, secondsKey) }
    private static func value(_ on: String, _ amount: String) -> Double? {
        let store = UserDefaults.standard
        store.register(defaults: [timedKey: true, minutesKey: 30.0, idleKey: true, secondsKey: 60.0])
        return store.bool(forKey: on) ? store.double(forKey: amount) : nil
    }

    /// Makes the document of `window` save in place only when told, and applies 무조건 자동 저장.
    static func adopt(_ window: NSWindow) {
        DispatchQueue.main.async {
            guard let document = window.windowController?.document as? NSDocument,
                  let meta = object_getClass(type(of: document)),
                  let original = class_getClassMethod(NSDocument.self, #selector(getter: NSDocument.autosavesInPlace))
            else { return }
            let never: @convention(block) (AnyObject) -> Bool = { _ in false }
            class_replaceMethod(meta, #selector(getter: NSDocument.autosavesInPlace), imp_implementationWithBlock(never),
                                method_getTypeEncoding(original))
            apply()
        }
    }
    static func apply() {
        NSDocumentController.shared.autosavingDelay = timed ?? 0
    }
    /// 쉴 때 자동 저장, once the keys have rested.
    static func rested(_ window: NSWindow?) {
        guard let document = window?.windowController?.document as? NSDocument, document.hasUnautosavedChanges
        else { return }
        document.autosave(withImplicitCancellability: true) { _ in }
    }
}

/// 설정 (환경 설정): 파일 탭's 복구용 임시 파일 자동 저장.
struct SettingsView: View {
    @AppStorage(Saving.timedKey) private var timed = true
    @AppStorage(Saving.minutesKey) private var minutes = 30.0
    @AppStorage(Saving.idleKey) private var idle = true
    @AppStorage(Saving.secondsKey) private var seconds = 60.0

    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 8) {
                GroupTitle("복구용 임시 파일 자동 저장")
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Toggle("무조건 자동 저장", isOn: $timed)
                        SpinField(value: $minutes, unit: "분", range: 1...60, digits: 0).disabled(!timed)
                    }
                    GridRow {
                        Toggle("쉴 때 자동 저장", isOn: $idle)
                        SpinField(value: $seconds, unit: "초", range: 1...360, digits: 0).disabled(!idle)
                    }
                }
                .padding(.leading, 12)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .tabItem { Label("파일", systemImage: "doc") }
        }
        .frame(width: 420)
        .onChange(of: [timed ? minutes : 0]) { Saving.apply() }
    }
}
