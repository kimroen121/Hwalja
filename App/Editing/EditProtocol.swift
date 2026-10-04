import Foundation

// Mirrors Engine/crates/hwp-engine-abi/src/editing/protocol.rs (JSON, version 1).
// Offsets (`scalar`) count Unicode scalars, not UTF-16 units.

struct CellTarget: Codable, Hashable, Sendable {
    var control: UInt32
    var cell: UInt32
    var paragraph: UInt32
}

struct EditTarget: Codable, Hashable, Sendable {
    var section: UInt32
    var paragraph: UInt32
    var cell: CellTarget?
}

struct EditPosition: Codable, Hashable, Sendable {
    var target: EditTarget
    var scalar: UInt32
}

struct EditSelection: Codable, Hashable, Sendable {
    var anchor: EditPosition
    var focus: EditPosition
    static func caret(_ position: EditPosition) -> Self { Self(anchor: position, focus: position) }
}

enum EditCommand: Encodable, Sendable {
    case replace(EditSelection, text: String)
    case split(EditPosition)
    case mergePrevious(EditPosition)
    case undo
    case redo

    private enum Key: String, CodingKey { case kind, selection, text, position }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .replace(selection, text):
            try c.encode("replace", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(text, forKey: .text)
        case let .split(position):
            try c.encode("split", forKey: .kind)
            try c.encode(position, forKey: .position)
        case let .mergePrevious(position):
            try c.encode("mergePrevious", forKey: .kind)
            try c.encode(position, forKey: .position)
        case .undo: try c.encode("undo", forKey: .kind)
        case .redo: try c.encode("redo", forKey: .kind)
        }
    }
}

struct EditReply: Decodable, Sendable {
    var revision: UInt64
    var selection: EditSelection?
    var pageCount: UInt32
    /// Zero-based pages with suspected overlap or text outside the page.
    var suspectPages: [UInt32]
    var canUndo: Bool
    var canRedo: Bool
    var dirty: Bool
    var locked: Bool
}

struct ParagraphInfo: Decodable, Sendable {
    var target: EditTarget
    var text: String
    var editable: Bool
    var reason: String
}

/// 96 dpi, top-left origin within `page`.
struct PageRect: Decodable, Sendable {
    var page: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum EditError: String, Error, Decodable, Sendable {
    case invalidInput = "InvalidInput"
    case passwordRequired = "PasswordRequired"
    case unsupportedFormat = "UnsupportedFormat"
    case staleRevision = "StaleRevision"
    case unsupportedTarget = "UnsupportedTarget"
    case invalidBoundary = "InvalidBoundary"
    case resourceLimit = "ResourceLimit"
    case renderFailed = "RenderFailed"
    case preservationFailed = "PreservationFailed"
    case saveFailed = "SaveFailed"
    case locked = "Locked"
}

enum SaveFormat: String, Encodable, Sendable {
    case hwp, hwpx
}

/// The `op`-tagged request envelope understood by `hwp_edit_request`.
enum EngineRequest: Encodable, Sendable {
    case state
    case apply(revision: UInt64, EditCommand)
    case paragraph(EditTarget)
    case hitTest(revision: UInt64, page: UInt32, x: Double, y: Double)
    case caret(revision: UInt64, EditPosition)
    case selectionRects(revision: UInt64, EditSelection)
    case export(SaveFormat)

    private enum Key: String, CodingKey { case op, request, target, revision, page, x, y, position, selection, format }
    private struct Apply: Encodable { var version = 1; var revision: UInt64; var command: EditCommand }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .state:
            try c.encode("state", forKey: .op)
        case let .apply(revision, command):
            try c.encode("apply", forKey: .op)
            try c.encode(Apply(revision: revision, command: command), forKey: .request)
        case let .paragraph(target):
            try c.encode("paragraph", forKey: .op)
            try c.encode(target, forKey: .target)
        case let .hitTest(revision, page, x, y):
            try c.encode("hitTest", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(page, forKey: .page)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case let .caret(revision, position):
            try c.encode("caret", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(position, forKey: .position)
        case let .selectionRects(revision, selection):
            try c.encode("selectionRects", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(selection, forKey: .selection)
        case let .export(format):
            try c.encode("export", forKey: .op)
            try c.encode(format, forKey: .format)
        }
    }
}
