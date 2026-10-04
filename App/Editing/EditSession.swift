import Foundation
import CHwpEngine

/// Owns one engine edit session. Every call to the raw handle runs on `queue`,
/// so the handle is never touched concurrently; callers only see owned values.
final class EditSession: @unchecked Sendable {
    /// Engine state with the PDF of the same revision.
    struct Output: Sendable {
        var reply: EditReply
        var pdf: Data
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

    func apply(_ command: EditCommand, at revision: UInt64) async throws -> Output {
        try await Output(send(.apply(revision: revision, command)))
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

    private func send(_ request: EngineRequest) async throws -> Payload {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.request(request) }) }
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
    init(_ payload: EditSession.Payload) throws {
        self.init(reply: try decode(payload), pdf: payload.data)
    }
}
