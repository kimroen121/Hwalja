import SwiftUI

/// Keys of the 설정 window.
enum Options {
    /// 개체 탭's 일부분 선택만으로 개체 전체 선택.
    static let partialKey = "partialObjectSelection"
}

/// 설정 (환경 설정): 개체 탭's 선택.
struct SettingsView: View {
    @AppStorage(Options.partialKey) private var partial = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupTitle("선택")
            Toggle("일부분 선택만으로 개체 전체 선택", isOn: $partial).padding(.leading, 12)
        }
        .padding(20)
        .frame(width: 420, alignment: .topLeading)
    }
}

#Preview {
    SettingsView()
}
