import CHwpEngine
import Foundation
import PDFKit

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
    static func open(_ original: Data?) throws -> (EditSession, Output) {
        if original?.isEmpty == true { throw EditError.invalidInput }
        var raw: OpaquePointer?
        let result = if let original {
            original.withUnsafeBytes { hwp_edit_open($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &raw) }
        } else {
            hwp_edit_open(nil, 0, &raw)
        }
        let output = try Output(take(result))
        guard let raw else { throw EditError.invalidInput }
        return (EditSession(handle: raw), output)
    }

    /// Verified document bytes for saving. Blocks until queued edits finish.
    func export(_ format: SaveFormat) throws -> Data {
        try queue.sync { try request(.export(format)).data }
    }
    /// The whole document as PDF.
    func pdf() async throws -> Data {
        try await send(.export(.pdf)).data
    }

    /// `amend` folds the edit into the latest undo step (IME composition).
    func apply(_ command: EditCommand, at revision: UInt64, amend: Bool = false) async throws -> Output {
        try await send(.apply(revision: revision, command, amend: amend), Output.init)
    }
    func paragraph(_ target: EditTarget) async throws -> ParagraphInfo {
        try await decode(send(.paragraph(target)))
    }
    func hitTest(revision: UInt64, page: UInt32, x: Double, y: Double) async throws -> EditPosition {
        try await decode(send(.hitTest(revision: revision, page: page, x: x, y: y)))
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
    func format(revision: UInt64, at position: EditPosition) async throws -> Format {
        try await decode(send(.format(revision: revision, position)))
    }

    /// Every match of `query` the editor can select, in document order.
    func find(_ query: String) async throws -> [EditSelection] {
        try await decode(send(.find(query: query, caseSensitive: false)))
    }

    func pageSetup(section: UInt32) async throws -> PageSetup {
        try await decode(send(.pageSetup(section: section)))
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
    fileprivate typealias Payload = (json: Data, data: Data)

    /// Copies out and frees an engine result, turning failures into `EditError`.
    private static func take(_ result: OpaquePointer?) throws -> Payload {
        defer { hwp_edit_result_free(result) }
        guard let text = hwp_edit_result_json(result) else { throw EditError.invalidInput }
        let json = Data(bytes: text, count: strlen(text))
        guard hwp_edit_result_status(result) == 0 else {
            struct Failure: Decodable { var error: EditError }
            throw (try? JSONDecoder().decode(Failure.self, from: json))?.error ?? EditError.invalidInput
        }
        let data = hwp_edit_result_data(result).map { Data(bytes: $0, count: hwp_edit_result_length(result)) }
        return (json, data ?? Data())
    }
}

private func decode<T: Decodable>(_ payload: EditSession.Payload) throws -> T {
    try JSONDecoder().decode(T.self, from: payload.json)
}
private extension EditSession.Output {
    /// The data holds per changed page a byte, 1 and its display list or 0 for a page in
    /// the PDF that follows them (`EditSession::rendering` in the engine).
    init(_ payload: EditSession.Payload) throws {
        let reply: EditReply = try decode(payload)
        var reader = ByteReader(payload.data)
        let displays = try reply.changedPages.map { _ in try reader.u8() == 1 ? PageDisplay(&reader) : nil }
        let pdf = displays.contains { $0 == nil } ? PDFDocument(data: reader.remaining) : nil
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
