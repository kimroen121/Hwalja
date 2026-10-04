import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @State private var snapshot: DocumentSnapshot?
    @State private var busy = false
    @State private var error: String?
    @State private var inspector = false
    @StateObject private var reader = PDFWorkspaceState()
    @EnvironmentObject private var app: AppDelegate
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Label("쪽 미리보기", systemImage: "square.grid.1x2")
                    .font(.headline).padding(.horizontal).padding(.top)
                if let snapshot {
                    Text(snapshot.sourceURL.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal)
                    SnapshotThumbnails(state: reader)
                } else {
                    Text("문서를 열면 쪽이 표시됩니다.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    Spacer()
                }
            }.navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 240)
        } detail: {
        VStack(spacing: 0) {
            if busy {
                HStack { ProgressView().controlSize(.small); Text("문서를 열고 렌더링하는 중…").font(.callout) }
                    .padding(10).frame(maxWidth: .infinity)
            }
            if let snapshot, !snapshot.layoutWarnings.isEmpty {
                Label(snapshot.layoutWarnings, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            if snapshot != nil { SnapshotPDFView(state: reader) }
            else {
                ContentUnavailableView {
                    Label("문서 작업 공간", systemImage: "doc.richtext")
                } description: {
                    Text("HWP · HWPX를 열어 원본을 보존하며 확인하세요.")
                } actions: {
                    Button("문서 열기…", action: open).buttonStyle(.borderedProminent).disabled(busy)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Label("읽기 전용 · 원본 보존", systemImage: "lock")
                Spacer()
                if snapshot != nil {
                    Button { reader.go(to: reader.pageNumber - 2) } label: { Image(systemName: "chevron.left") }
                        .disabled(reader.pageNumber <= 1).help("이전 쪽")
                    Text("\(reader.pageNumber) / \(reader.pageCount)쪽").monospacedDigit()
                    Button { reader.go(to: reader.pageNumber) } label: { Image(systemName: "chevron.right") }
                        .disabled(reader.pageNumber >= reader.pageCount).help("다음 쪽")
                    Divider().frame(height: 14)
                    Button { reader.zoom(by: 1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }.help("축소")
                    Text("\(reader.zoomPercent)%").monospacedDigit().frame(minWidth: 38)
                    Button { reader.zoom(by: 1.2) } label: { Image(systemName: "plus.magnifyingglass") }.help("확대")
                    Button("쪽 맞춤") { reader.fit() }
                }
            }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 9)
        }.inspector(isPresented: $inspector) {
            VStack(alignment: .leading, spacing: 12) {
                Text("문서 정보").font(.headline)
                if let snapshot {
                    Text(snapshot.sourceURL.lastPathComponent)
                    Text("원본: \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.original.count), countStyle: .file))")
                    Text("PDF: \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.pdf.count), countStyle: .file))")
                    Text("\(snapshot.pageCount)쪽")
                }
                Text("글꼴 대체 및 한컴 호환성: 미검증")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                Text("화면과 내보내기는 같은 PDF를 사용합니다. 한컴과 글꼴·쪽 나눔이 다를 수 있으므로 제출 전에 확인하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("현재는 읽기 전용이며 HWP/HWPX 편집·저장은 지원하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("rhwp 0.8.6 · MIT").font(.caption2).foregroundStyle(.tertiary)
            }.padding().inspectorColumnWidth(min: 200, ideal: 240, max: 320)
        }
        }.frame(minWidth: 900, minHeight: 540)
            .navigationTitle(snapshot?.sourceURL.deletingPathExtension().lastPathComponent ?? "HwpStudio")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("열기", systemImage: "folder", action: open).disabled(busy).keyboardShortcut("o")
                    Button("인쇄", systemImage: "printer") { reader.view.print(with: .shared, autoRotate: true) }
                        .disabled(snapshot == nil || busy).keyboardShortcut("p")
                    Button("PDF 내보내기", systemImage: "square.and.arrow.up", action: export)
                        .disabled(snapshot == nil || busy).keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("문서 정보", systemImage: "sidebar.right") { inspector.toggle() }
                }
            }
            .onReceive(app.$openedURL.compactMap { $0 }, perform: load)
            .alert("문서 작업 실패", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("확인") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "hwp"), UTType(filenameExtension: "hwpx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }
    private func load(_ url: URL) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let opened = try await Task.detached { try DocumentSnapshot.open(url) }.value
                reader.load(opened.pdf)
                snapshot = opened
            }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func export() {
        guard let snapshot else { return }
        if !snapshot.layoutWarnings.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "배치 문제가 있는 PDF입니다"
            alert.informativeText = snapshot.layoutWarnings + "\n검사용 사본만 내보내시겠습니까?"
            alert.addButton(withTitle: "취소")
            alert.addButton(withTitle: "검사용 사본 내보내기")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = snapshot.sourceURL.deletingPathExtension().lastPathComponent + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try snapshot.export(to: url, acknowledgingLayoutWarnings: !snapshot.layoutWarnings.isEmpty) } catch { self.error = error.localizedDescription }
    }
}
