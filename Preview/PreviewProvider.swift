import Foundation
import QuickLookUI

/// Finder's Quick Look (space bar): the document's pages as a PDF, drawn as the app draws them.
/// A document locked with a password throws, leaving the system's own preview.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let pages = try EditSession.open(try Data(contentsOf: request.fileURL)).1.pages
        let pdf = try pdfData(drawing: pages)
        return QLPreviewReply(dataOfContentType: .pdf, contentSize: pages[0].size) { _ in pdf }
    }
}
