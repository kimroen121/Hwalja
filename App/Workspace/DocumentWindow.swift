import PDFKit
import SwiftUI

/// One document window: page thumbnails in the sidebar, the editable pages in the detail.
struct DocumentWindow: View {
    @ObservedObject var document: HwpDocument
    @StateObject private var viewer = Viewer()

    var body: some View {
        NavigationSplitView {
            PageThumbnails(document: document, viewer: viewer)
                .navigationSplitViewColumnWidth(min: 120, ideal: 150, max: 220)
        } detail: {
            Canvas(canvas: viewer.canvas, document: document)
                .frame(minWidth: 480, minHeight: 400)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        Spacer()
                        Text("\(viewer.page + 1) / \(document.reply.pageCount)쪽")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.bar)
                }
        }
        .focusedSceneObject(document)
        .focusedSceneObject(viewer)
        .toolbar {
            FormatBar(document: document, editor: viewer.canvas.editor)
            if let first = document.reply.suspectPages.first {
                ToolbarItem {
                    Button { viewer.canvas.go(to: Int(first)) } label: {
                        Label("배치 확인", systemImage: "exclamationmark.triangle")
                    }
                    .help(document.reply.suspectPages.map { "\($0 + 1)쪽" }.joined(separator: ", "))
                }
            }
            ToolbarItem {
                Menu("\(viewer.zoomPercent)%") {
                    ForEach([50, 75, 100, 125, 150, 200, 300], id: \.self) { percent in
                        Button("\(percent)%") { viewer.canvas.setZoom(CGFloat(percent) / 100) }
                    }
                    Divider()
                    Button("쪽 맞춤") { viewer.canvas.fit(.page) }
                    Button("폭 맞춤") { viewer.canvas.fit(.width) }
                }
                .help("확대/축소")
            }
        }
    }
}

/// Owns the window's canvas and publishes what the toolbar and sidebar show.
@MainActor
final class Viewer: ObservableObject {
    let canvas = DocumentCanvas(frame: .zero)
    @Published private(set) var zoomPercent = 100
    /// Zero-based page in view.
    @Published private(set) var page = 0

    init() {
        canvas.onViewChange = { [weak self] in
            guard let self else { return }
            let zoom = Int((canvas.zoom * 100).rounded()), page = canvas.currentPage
            if zoom != zoomPercent { zoomPercent = zoom }
            if page != self.page { self.page = page }
        }
    }
}

private struct Canvas: NSViewRepresentable {
    let canvas: DocumentCanvas
    let document: HwpDocument
    func makeNSView(context: Context) -> DocumentCanvas { canvas }
    func updateNSView(_ view: DocumentCanvas, context: Context) { view.bind(document) }
}

/// Page thumbnails; a page's image is redrawn only when the engine replaced that page.
private struct PageThumbnails: View {
    @ObservedObject var document: HwpDocument
    @ObservedObject var viewer: Viewer

    var body: some View {
        let pages = document.pages
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<pages.pageCount, id: \.self) { index in
                        if let page = pages.page(at: index) {
                            Button { viewer.canvas.go(to: index) } label: {
                                VStack(spacing: 4) {
                                    Thumbnail(page: page)
                                        .padding(3)
                                        .background(RoundedRectangle(cornerRadius: 4)
                                            .fill(index == viewer.page ? Color.accentColor.opacity(0.35) : .clear))
                                    Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: viewer.page) { proxy.scrollTo(viewer.page) }
        }
    }
}

/// Draws off the main actor once a page has stopped changing, keeping the previous image
/// meanwhile, so typing never waits for a thumbnail.
private struct Thumbnail: View {
    let page: PDFPage
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image) } else { Color.white.frame(width: 106, height: 150) }
        }
        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        .task(id: ObjectIdentifier(page)) {
            if image != nil { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            nonisolated(unsafe) let page = page
            let drawn = await Task.detached(priority: .utility) { Drawn(page.thumbnail(of: NSSize(width: 110, height: 150), for: .mediaBox)) }.value
            if !Task.isCancelled { image = drawn.image }
        }
    }
}

private struct Drawn: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}
