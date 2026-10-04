import SwiftUI
import PDFKit

@MainActor
final class PDFWorkspaceState: NSObject, ObservableObject {
    let view = PDFView()
    @Published private(set) var pageNumber = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var zoomPercent = 100

    override init() {
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 4
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .PDFViewScaleChanged, object: view)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    func load(_ bytes: Data) {
        view.document = PDFDocument(data: bytes)
        fit()
        go(to: 0)
        refresh()
    }
    func go(to index: Int) {
        guard let document = view.document, document.pageCount > 0,
              let page = document.page(at: min(max(index, 0), document.pageCount - 1)) else { return }
        view.go(to: page)
        refresh()
    }
    func zoom(by factor: Double) {
        view.autoScales = false
        view.scaleFactor = min(max(view.scaleFactor * factor, 0.25), 4)
        refresh()
    }
    func fit() {
        view.autoScales = true
        refresh()
    }
    @objc private func refresh() {
        pageCount = view.document?.pageCount ?? 0
        if let page = view.currentPage, let document = view.document {
            pageNumber = document.index(for: page) + 1
        } else {
            pageNumber = 0
        }
        zoomPercent = Int((view.scaleFactor * 100).rounded())
    }
}

struct SnapshotPDFView: NSViewRepresentable {
    let state: PDFWorkspaceState
    func makeNSView(context: Context) -> PDFView { state.view }
    func updateNSView(_ view: PDFView, context: Context) {}
}

struct SnapshotThumbnails: NSViewRepresentable {
    let state: PDFWorkspaceState
    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = state.view
        view.thumbnailSize = NSSize(width: 110, height: 150)
        view.backgroundColor = .clear
        return view
    }
    func updateNSView(_ view: PDFThumbnailView, context: Context) {}
}
