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

    let id = UUID()
    private let queue = DispatchQueue(label: "app.hwpstudio.edit-session")
    private var handle: OpaquePointer?

    private init(handle: OpaquePointer) { self.handle = handle }
    deinit { hwp_edit_close(handle) }

    /// Opens a session over `original`; the bytes are copied by the engine.
    static func open(_ original: Data) async throws -> (EditSession, Output) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var raw: OpaquePointer?
                let result = original.withUnsafeBytes {
                    hwp_edit_open($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &raw)
                }
                continuation.resume(with: Result {
                    let output = try Output(take(result))
                    guard let raw else { throw EditError.invalidInput }
                    return (EditSession(handle: raw), output)
                })
            }
        }
    }

    func state() async throws -> Output { try await Output(send(.state)) }
    func apply(_ command: EditCommand, at revision: UInt64) async throws -> Output {
        try await Output(send(.apply(revision: revision, command)))
    }
    func paragraph(_ target: EditTarget) async throws -> ParagraphInfo { try await decode(send(.paragraph(target))) }
    func hitTest(revision: UInt64, page: UInt32, x: Double, y: Double) async throws -> EditPosition {
        try await decode(send(.hitTest(revision: revision, page: page, x: x, y: y)))
    }
    func caret(revision: UInt64, at position: EditPosition) async throws -> PageRect {
        try await decode(send(.caret(revision: revision, position)))
    }

    private func send(_ request: EngineRequest) async throws -> Payload {
        let body = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    guard let handle else { throw EditError.locked }
                    return try Self.take(body.withUnsafeBytes {
                        hwp_edit_request(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
                    })
                })
            }
        }
    }
    /// Owned copies of a successful result's JSON and PDF.
    fileprivate typealias Payload = (json: Data, pdf: Data)

    /// Copies out and frees an engine result, turning failures into `EditError`.
    private static func take(_ result: OpaquePointer?) throws -> Payload {
        defer { hwp_edit_result_free(result) }
        guard let text = hwp_edit_result_json(result) else { throw EditError.invalidInput }
        let json = Data(bytes: text, count: strlen(text))
        guard hwp_edit_result_status(result) == 0 else {
            struct Failure: Decodable { var error: EditError }
            throw (try? JSONDecoder().decode(Failure.self, from: json))?.error ?? EditError.invalidInput
        }
        let pdf = hwp_edit_result_pdf_data(result).map { Data(bytes: $0, count: hwp_edit_result_pdf_length(result)) }
        return (json, pdf ?? Data())
    }
}

private func decode<T: Decodable>(_ payload: EditSession.Payload) throws -> T {
    try JSONDecoder().decode(T.self, from: payload.json)
}
private extension EditSession.Output {
    init(_ payload: EditSession.Payload) throws {
        self.init(reply: try decode(payload), pdf: payload.pdf)
    }
}
