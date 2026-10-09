import CHwpEngine
import Foundation
import PDFKit
import OSLog

private let renderLog = Logger(subsystem: "app.hwpstudio.mac", category: "Rendering")

/// Owns one engine edit session. Every call to the raw handle runs on `queue`,
/// so the handle is never touched concurrently; callers only see owned values.
final class EditSession: @unchecked Sendable {
    /// Engine state with the pages it re-rendered (`reply.changedPages`), decoded off the
    /// main actor.
    struct Output: Sendable {
        var reply: EditReply
        var pages: [RenderedPage]
    }

    private let queue = DispatchQueue(label: "app.hwpstudio.edit-session")
    private let handle: OpaquePointer

    private init(handle: OpaquePointer) { self.handle = handle }
    deinit { hwp_edit_close(handle) }

    /// Opens `original` (copied by the engine), or a blank document when `nil`. Blocks.
    /// A document locked with a password opens only with `password`; a wrong one throws
    /// `passwordRequired`, and saving locks it again.
    static func open(_ original: Data?, password: String? = nil) throws -> (EditSession, Output) {
        if original?.isEmpty == true { throw EditError.invalidInput }
        var raw: OpaquePointer?
        let result = if let original, let password {
            original.withUnsafeBytes { data in
                Array(password.utf8).withUnsafeBufferPointer { secret in
                    hwp_edit_open_password(EditProtocolVersion.current, data.bindMemory(to: UInt8.self).baseAddress, data.count,
                                           secret.baseAddress, secret.count, &raw)
                }
            }
        } else if let original {
            original.withUnsafeBytes {
                hwp_edit_open_v2(EditProtocolVersion.current,
                                 $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &raw)
            }
        } else {
            hwp_edit_open_v2(EditProtocolVersion.current, nil, 0, &raw)
        }
        // The engine may succeed but Swift may reject its rendering payload.
        // In that case ownership has not transferred to an EditSession yet.
        var transferred = false
        defer { if !transferred { hwp_edit_close(raw) } }
        let output = try Output(take(result))
        guard let raw else { throw EditError.invalidInput }
        transferred = true
        return (EditSession(handle: raw), output)
    }

    /// Verified document bytes for saving. Blocks until queued edits finish.
    func export(_ format: SaveFormat) throws -> Data {
        try queue.sync { try request(.export(format)).data }
    }

    /// `amend` folds the edit into the latest undo step (IME composition).
    func apply(_ command: EditCommand, at revision: UInt64, amend: Bool = false,
               selection: EditSelection? = nil) async throws -> Output {
        try await send(.apply(revision: revision, command, amend: amend, selection: selection), Output.init)
    }
    func paragraph(_ target: EditTarget) async throws -> ParagraphInfo {
        try await decode(send(.paragraph(target)))
    }
    func hitTest(revision: UInt64, page: UInt32, x: Double, y: Double,
                 includeHeaderFooter: Bool = false) async throws -> EditPosition {
        try await decode(send(.hitTest(revision: revision, page: page, x: x, y: y,
                                       includeHeaderFooter: includeHeaderFooter)))
    }
    func caret(revision: UInt64, at position: EditPosition) async throws -> PageRect {
        try await decode(send(.caret(revision: revision, position)))
    }
    func selectionRects(revision: UInt64, for selection: EditSelection) async throws -> [PageRect] {
        try await decode(send(.selectionRects(revision: revision, selection)))
    }
    func navigate(revision: UInt64, from position: EditPosition, _ motion: Motion, goalX: Double?) async throws -> Navigation {
        try await decode(send(.navigate(revision: revision, position, motion, goalX: goalX)))
    }
    /// The format at `position`; with `from`, unset where the characters between them differ.
    func format(revision: UInt64, at position: EditPosition, from: EditPosition? = nil) async throws -> Format {
        try await decode(send(.format(revision: revision, position, from: from)))
    }

    /// Every match of `query` the editor can select, in document order.
    func find(_ query: String, _ options: FindOptions = FindOptions()) async throws -> [EditSelection] {
        try await decode(send(.find(query: query, options)))
    }

    func copyObject(_ object: ObjectRef) async throws -> Copied {
        try await decode(send(.copyObject(object)))
    }
    func copy(revision: UInt64, _ selection: EditSelection) async throws -> Copied {
        try await decode(send(.copy(revision: revision, selection)))
    }
    func pageSetup(section: UInt32) async throws -> PageSetup {
        try await decode(send(.pageSetup(section: section)))
    }
    func styleFormat(_ style: UInt32) async throws -> Format {
        try await decode(send(.styleFormat(style)))
    }
    func pageBorder(section: UInt32) async throws -> PageBorder {
        try await decode(send(.pageBorder(section: section)))
    }
    func sectionSetup(section: UInt32) async throws -> SectionSetup {
        try await decode(send(.sectionSetup(section: section)))
    }
    func noteShape(section: UInt32, footnote: Bool) async throws -> NoteShape {
        try await decode(send(.noteShape(section: section, footnote: footnote)))
    }
    func pageHide(_ target: EditTarget) async throws -> PageHide {
        try await decode(send(.pageHide(target)))
    }
    func bookmarks() async throws -> [Bookmark] {
        try await decode(send(.bookmarks))
    }
    func clickHere(at position: EditPosition) async throws -> ClickHere? {
        try await decode(send(.clickHereAt(position)))
    }
    func hyperlink(at position: EditPosition) async throws -> Hyperlink? {
        try await decode(send(.hyperlinkAt(position)))
    }
    func fonts() async throws -> [[UsedFont]] {
        try await decode(send(.fonts))
    }
    func pictures() async throws -> [PictureInfo] {
        try await decode(send(.pictures))
    }
    func textDocument() async throws -> String {
        try await decode(send(.textDocument))
    }
    func webDocument() async throws -> String {
        try await decode(send(.webDocument))
    }
    func hasPassword() async throws -> Bool {
        try await decode(send(.hasPassword))
    }
    func setPassword(current: String?, new: String?) async throws -> Bool {
        try await decode(send(.setPassword(current: current, new: new)))
    }
    func outline() async throws -> [OutlineItem] {
        try await decode(send(.outline))
    }
    func statistics() async throws -> Statistics {
        try await decode(send(.statistics))
    }
    func status(revision: UInt64, at position: EditPosition) async throws -> CaretStatus {
        try await decode(send(.status(revision: revision, position)))
    }

    func styles() async throws -> [StyleInfo] {
        try await decode(send(.styles))
    }
    /// Shows or hides 문단 부호 and 조판 부호; the pages that change come back.
    func showMarks(paragraph: Bool, control: Bool, borders: Bool) async throws -> Output {
        try await send(.showMarks(paragraph: paragraph, control: control, borders: borders), Output.init)
    }
    /// The topmost picture or equation under a page point.
    func objectAt(revision: UInt64, page: UInt32, x: Double, y: Double) async throws -> PlacedObject? {
        try await decode(send(.objectAt(revision: revision, page: page, x: x, y: y)))
    }
    func chartData(_ chart: UInt32) async throws -> ChartData {
        try await decode(send(.chartData(chart)))
    }
    func form(revision: UInt64, page: UInt32, x: Double, y: Double) async throws -> FormInfo? {
        try await decode(send(.formAt(revision: revision, page: page, x: x, y: y)))
    }
    func objects(revision: UInt64, page: UInt32) async throws -> [PlacedObject] {
        try await decode(send(.objects(revision: revision, page: page)))
    }
    func tableLines(revision: UInt64, page: UInt32) async throws -> [TableLine] {
        try await decode(send(.tableLines(revision: revision, page: page)))
    }
    /// Where `object` is laid out, looking from `page` outward.
    func place(revision: UInt64, _ object: ObjectRef, page: UInt32) async throws -> PlacedObject {
        try await decode(send(.place(revision: revision, object, page: page)))
    }
    func objectProps(_ object: ObjectRef) async throws -> ObjectProps {
        try await decode(send(.objectProps(object)))
    }
    /// The image a picture shows, as stored, and its file extension.
    func pictureFile(_ object: ObjectRef) async throws -> (data: Data, extension: String) {
        try await send(.pictureFile(object)) { payload in
            struct File: Decodable { var `extension`: String }
            return (payload.data, try JSONDecoder().decode(File.self, from: payload.json).extension)
        }
    }
    func cellProps(_ cell: EditTarget) async throws -> CellProps {
        try await decode(send(.cellProps(cell)))
    }
    func cellBorder(_ cell: EditTarget) async throws -> CellBorder {
        try await decode(send(.cellBorder(cell)))
    }
    /// An equation laid out by the engine's renderer, as on the page.
    func equationPreview(_ script: String, fontSize: UInt32, color: UInt32) async throws -> PageDisplay {
        try await send(.equationPreview(script: script, fontSize: fontSize, color: color)) { payload in
            var reader = ByteReader(payload.data)
            return try PageDisplay(&reader)
        }
    }
    /// An equation script as LaTeX, or with `fromLatex`, LaTeX as a script.
    func convertEquation(_ text: String, fromLatex: Bool) async throws -> String {
        struct Converted: Decodable { var text: String }
        let converted: Converted = try await decode(send(.convertEquation(text, fromLatex: fromLatex)))
        return converted.text
    }

    private func send(_ request: EngineRequest) async throws -> Payload {
        try await send(request) { $0 }
    }
    /// Runs `request` and `transform`s its result on `queue`.
    private func send<T: Sendable>(_ request: EngineRequest, _ transform: @escaping @Sendable (Payload) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try transform(self.request(request)) }) }
        }
    }
    /// Must run on `queue`.
    private func request(_ request: EngineRequest) throws -> Payload {
        let body = try JSONEncoder().encode(request)
        return try Self.take(body.withUnsafeBytes {
            hwp_edit_request(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        })
    }

    /// Owned copies of a successful result's JSON and bytes.
    typealias Payload = (json: Data, data: Data)

    /// Copies out and frees an engine result, turning failures into `EditError`.
    private static func take(_ result: OpaquePointer?) throws -> Payload {
        defer { hwp_edit_result_free(result) }
        guard let text = hwp_edit_result_json(result) else { throw EditError.invalidInput }
        let json = Data(bytes: text, count: strlen(text))
        guard hwp_edit_result_status(result) == 0 else {
            struct Failure: Decodable { var error: EditError }
            let error = (try? JSONDecoder().decode(Failure.self, from: json))?.error ?? EditError.invalidInput
            renderLog.error("Engine request failed: \(error.rawValue, privacy: .public)")
            throw error
        }
        let data = hwp_edit_result_data(result).map { Data(bytes: $0, count: hwp_edit_result_length(result)) }
        return (json, data ?? Data())
    }
}

private func decode<T: Decodable>(_ payload: EditSession.Payload) throws -> T {
    try JSONDecoder().decode(T.self, from: payload.json)
}
extension EditSession.Output {
    /// The data holds per changed page a byte, 1 and its display list or 0 for a page in
    /// the PDF that follows them (`EditSession::rendering` in the engine).
    init(_ payload: EditSession.Payload) throws {
        let reply: EditReply = try decode(payload)
        guard reply.version == EditProtocolVersion.current else {
            renderLog.error("Incompatible engine protocol: expected=\(EditProtocolVersion.current) actual=\(reply.version)")
            throw EditError.incompatibleEngine
        }
        var reader = ByteReader(payload.data)
        let displays: [PageDisplay?]
        do {
            displays = try reply.changedPages.map { _ in
                switch try reader.u8() {
                case 0: return nil
                case 1: return try PageDisplay(&reader)
                default: throw EditError.renderFailed
                }
            }
        } catch {
            let legacyPDF = payload.data.starts(with: Data("%PDF-".utf8))
            renderLog.error("Display-list decode failed: revision=\(reply.revision) changedPages=\(reply.changedPages.count) payloadBytes=\(payload.data.count) legacyPDFPayload=\(legacyPDF). Rebuild the engine and app together if the payload is from an older engine.")
            throw error
        }
        let pdfBytes = reader.remaining
        let fallbackCount = displays.filter { $0 == nil }.count
        let pdf = fallbackCount > 0 ? PDFDocument(data: pdfBytes) : nil
        if fallbackCount > 0 && pdf?.pageCount != fallbackCount {
            let hasHeader = pdfBytes.starts(with: Data("%PDF-".utf8))
            renderLog.error("PDFKit decode failed: revision=\(reply.revision) expectedPages=\(fallbackCount) decodedPages=\(pdf?.pageCount ?? -1) pdfBytes=\(pdfBytes.count) hasPDFHeader=\(hasHeader)")
            throw EditError.renderFailed
        }
        var next = 0
        let pages = try displays.map { display -> RenderedPage in
            if let display { return .display(display) }
            defer { next += 1 }
            guard let page = pdf?.page(at: next) else { throw EditError.renderFailed }
            return .pdf(page)
        }
        guard pages.count == reply.changedPages.count else { throw EditError.renderFailed }
        self.init(reply: reply, pages: pages)
    }
}
