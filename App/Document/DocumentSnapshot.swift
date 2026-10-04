import Foundation
import CHwpEngine
import PDFKit

struct DocumentSnapshot: Sendable {
    let sourceURL: URL
    let original: Data
    let pdf: Data
    let pageCount: UInt32
    var layoutWarnings: String = ""

    static func open(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let limit = 64 * 1024 * 1024
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let original = try file.read(upToCount: limit + 1) ?? Data()
        guard original.count <= limit else { throw SnapshotError.message("64 MiB보다 큰 파일은 지원하지 않습니다.") }
        let result = original.withUnsafeBytes { hwp_engine_open($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        defer { hwp_engine_string_free(result.message); hwp_engine_snapshot_free(result.snapshot) }
        guard result.status == 0, let handle = result.snapshot else {
            let text = result.message.map { String(cString: $0) } ?? "문서를 열 수 없습니다."
            throw SnapshotError.message(text)
        }
        guard let pointer = hwp_engine_pdf_data(handle) else { throw SnapshotError.message("PDF가 생성되지 않았습니다.") }
        let pdf = Data(bytes: pointer, count: hwp_engine_pdf_length(handle))
        guard let document = PDFDocument(data: pdf), document.pageCount == Int(hwp_engine_page_count(handle)), document.pageCount > 0 else {
            throw SnapshotError.message("생성된 PDF의 페이지를 검증할 수 없습니다.")
        }
        let warnings = hwp_engine_layout_warnings(handle).map { String(cString: $0) } ?? ""
        return Self(sourceURL: url, original: original, pdf: pdf, pageCount: hwp_engine_page_count(handle), layoutWarnings: warnings)
    }

    func export(to url: URL, acknowledgingLayoutWarnings: Bool = false) throws {
        guard layoutWarnings.isEmpty || acknowledgingLayoutWarnings else {
            throw SnapshotError.message(layoutWarnings)
        }
        let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
        let destinationAccess = url.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
            if destinationAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard url.standardizedFileURL.resolvingSymlinksInPath() != sourceURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw SnapshotError.message("원본을 보존하려면 다른 저장 위치를 선택하세요.")
        }
        if FileManager.default.fileExists(atPath: url.path),
           let sourceID = try sourceURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
           let destinationID = try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
           sourceID == destinationID {
            throw SnapshotError.message("이 위치는 원본 문서입니다. 다른 파일을 선택하세요.")
        }
        try pdf.write(to: url, options: .atomic)
    }
}

enum SnapshotError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}
