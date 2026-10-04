import Combine
import PDFKit
import SwiftUI

/// One document window: page thumbnails in the sidebar, the editable pages in the detail.
struct DocumentWindow: View {
    @ObservedObject var document: HwpDocument
    @StateObject private var viewer = Viewer()

    var body: some View {
        NavigationSplitView {
            PageThumbnails(canvas: viewer.canvas)
                .navigationSplitViewColumnWidth(min: 120, ideal: 150, max: 220)
        } detail: {
            Canvas(canvas: viewer.canvas, document: document)
                .frame(minWidth: 480, minHeight: 400)
        }
        .toolbar {
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
                        Button("\(percent)%") { viewer.zoom(to: percent) }
                    }
                    Divider()
                    Button("쪽 맞춤") { viewer.canvas.zoomToFitPage() }
                    Button("폭 맞춤") { viewer.canvas.autoScales = true }
                }
                .help("확대/축소")
            }
        }
    }
}

/// Owns the window's canvas and publishes what the toolbar shows.
@MainActor
final class Viewer: ObservableObject {
    let canvas = DocumentCanvas(frame: .zero)
    @Published private(set) var zoomPercent = 100
    private var observer: AnyCancellable?

    init() {
        observer = NotificationCenter.default.publisher(for: .PDFViewScaleChanged, object: canvas)
            .merge(with: NotificationCenter.default.publisher(for: .PDFViewDocumentChanged, object: canvas))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                zoomPercent = Int((canvas.scaleFactor * 100).rounded())
            }
    }
    func zoom(to percent: Int) {
        canvas.autoScales = false
        canvas.scaleFactor = CGFloat(percent) / 100
    }
}

extension PDFView {
    func go(to index: Int) {
        guard let page = document?.page(at: index) else { return }
        go(to: page)
    }
}

private struct Canvas: NSViewRepresentable {
    let canvas: DocumentCanvas
    let document: HwpDocument
    func makeNSView(context: Context) -> DocumentCanvas { canvas }
    func updateNSView(_ view: DocumentCanvas, context: Context) { view.bind(document) }
}

private struct PageThumbnails: NSViewRepresentable {
    let canvas: DocumentCanvas
    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = canvas
        view.thumbnailSize = NSSize(width: 110, height: 150)
        view.backgroundColor = .clear
        return view
    }
    func updateNSView(_ view: PDFThumbnailView, context: Context) {}
}
