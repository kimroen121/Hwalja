import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @State private var snapshot: DocumentSnapshot?
    @State private var busy = false
    @State private var error: String?
    @State private var inspector = true
    var body: some View {
        NavigationSplitView {
            List {
                Label("문서 작업 공간", systemImage: "doc.text")
                if let snapshot {
                    Text(snapshot.sourceURL.lastPathComponent)
                    Text("\(snapshot.pageCount)쪽")
                }
                Text("읽기 전용").foregroundStyle(.secondary)
                Text("HWP / HWPX 열기 · PDF 내보내기").font(.caption)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
        VStack(spacing: 0) {
            HStack {
                Button("HWP / HWPX 열기…", action: open).disabled(busy)
                Button("PDF 내보내기…", action: export).disabled(snapshot == nil || busy)
                if busy { ProgressView().controlSize(.small); Text("문서를 열고 렌더링하는 중…") }
                Spacer()
                Button("문서 정보", systemImage: "sidebar.right") { inspector.toggle() }
            }.padding()
            Divider()
            if let snapshot { SnapshotPDFView(bytes: snapshot.pdf) }
            else { ContentUnavailableView("문서 열기", systemImage: "doc", description: Text("HWP 또는 HWPX 파일을 선택하여 PDF로 미리 봅니다.")) }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if let snapshot { Text("\(snapshot.sourceURL.lastPathComponent) · \(snapshot.pageCount)쪽") }
                Text("한컴 호환성은 검증되지 않았습니다. 글꼴 누락 시 배치가 달라질 수 있습니다. 화면과 내보내기는 동일한 PDF를 사용합니다.")
                Text("rhwp 0.8.6 (MIT) · 읽기 전용 · 원본 저장 기능 없음")
            }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding()
        }.inspector(isPresented: $inspector) {
            VStack(alignment: .leading, spacing: 12) {
                Text("문서 정보").font(.headline)
                if let snapshot {
                    Text(snapshot.sourceURL.lastPathComponent)
                    Text("원본: \(snapshot.original.count)바이트")
                    Text("PDF: \(snapshot.pdf.count)바이트")
                    Text("\(snapshot.pageCount)쪽")
                }
                Text("글꼴 대체 및 한컴 호환성: 미검증")
                Spacer()
            }.padding().inspectorColumnWidth(min: 200, ideal: 240, max: 320)
        }
        }.frame(minWidth: 900, minHeight: 540)
            .alert("문서 작업 실패", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("확인") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "hwp"), UTType(filenameExtension: "hwpx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        snapshot = nil
        busy = true
        Task {
            do { snapshot = try await Task.detached { try DocumentSnapshot.open(url) }.value }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func export() {
        guard let snapshot else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = snapshot.sourceURL.deletingPathExtension().lastPathComponent + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try snapshot.export(to: url) } catch { self.error = error.localizedDescription }
    }
}
