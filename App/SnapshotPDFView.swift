import SwiftUI
import PDFKit

struct SnapshotPDFView: NSViewRepresentable {
    let bytes: Data
    final class Coordinator { var bytes: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.bytes != bytes {
            view.document = PDFDocument(data: bytes)
            context.coordinator.bytes = bytes
        }
    }
}
