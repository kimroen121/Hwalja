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
    case formatText(EditSelection, CharStyle)
    case formatParagraphs(EditSelection, ParaStyle)
    /// A new page (or column) from `position` in the body.
    case pageBreak(EditPosition, column: Bool)
    case insertTable(EditPosition, rows: Int, columns: Int)
    /// Adds or removes a row or column of the table holding the cell `target`.
    case editTable(EditTarget, TableChange)
    case setPage(section: UInt32, PageSetup)
    /// 머리말 or 꼬리말 for every page of a section: empty, or holding the page number.
    case headerFooter(section: UInt32, footer: Bool, pageNumber: Placement?)
    case undo
    case redo

    private enum Key: String, CodingKey {
        case kind, selection, text, position, style, column, rows, columns, cell, change, section, page, footer, pageNumber
    }
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
        case let .formatText(selection, style):
            try c.encode("formatText", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(style, forKey: .style)
        case let .formatParagraphs(selection, style):
            try c.encode("formatParagraphs", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(style, forKey: .style)
        case let .pageBreak(position, column):
            try c.encode("break", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(column, forKey: .column)
        case let .insertTable(position, rows, columns):
            try c.encode("insertTable", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(rows, forKey: .rows)
            try c.encode(columns, forKey: .columns)
        case let .editTable(cell, change):
            try c.encode("editTable", forKey: .kind)
            try c.encode(cell, forKey: .cell)
            try c.encode(change, forKey: .change)
        case let .setPage(section, page):
            try c.encode("setPage", forKey: .kind)
            try c.encode(section, forKey: .section)
            try c.encode(page, forKey: .page)
        case let .headerFooter(section, footer, pageNumber):
            try c.encode("headerFooter", forKey: .kind)
            try c.encode(section, forKey: .section)
            try c.encode(footer, forKey: .footer)
            try c.encode(pageNumber, forKey: .pageNumber)
        case .undo: try c.encode("undo", forKey: .kind)
        case .redo: try c.encode("redo", forKey: .kind)
        }
    }
}

enum Placement: String, Encodable, Sendable {
    case left, center, right
}

enum TableChange: String, Encodable, Sendable {
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight, deleteRow, deleteColumn
}

/// A section's paper in HWPUNIT (1/7200 inch); `width` and `height` describe it upright.
struct PageSetup: Codable, Hashable, Sendable {
    var width: UInt32
    var height: UInt32
    var marginLeft: UInt32
    var marginRight: UInt32
    var marginTop: UInt32
    var marginBottom: UInt32
    var marginHeader: UInt32
    var marginFooter: UInt32
    var marginGutter: UInt32
    var landscape: Bool
}

struct EditReply: Decodable, Sendable {
    var revision: UInt64
    var selection: EditSelection?
    /// Caret rectangle of the selection focus, laid out with this revision.
    var caret: PageRect?
    var pageCount: UInt32
    /// Pages re-rendered by this revision; the accompanying PDF holds exactly these, in order.
    var changedPages: [UInt32]
    var canUndo: Bool
    var canRedo: Bool
    var dirty: Bool
    var locked: Bool
}

/// Character format: as a query result every field is set; as a change, nil fields stay.
struct CharStyle: Codable, Hashable, Sendable {
    var font: String?
    /// Points.
    var size: Double?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    /// `#rrggbb`.
    var color: String?
    /// Line shapes (0 solid, 1 dash, 2 dot, …, 11 wave, 12 double wave).
    var underlineShape: Int?
    var strikeShape: Int?
    /// Shade behind the text (`#rrggbb`, white is none); also serves 형광펜.
    var shade: String?
    /// 장평 (50–200%) and 자간 (−50–50%).
    var ratio: Double?
    var spacing: Double?
    var superscript: Bool?
    var `subscript`: Bool?
    var outline: Bool?
    var shadow: Bool?
    var emboss: Bool?
    var engrave: Bool?

    /// The fields of `self` that differ from `old`.
    func changes(from old: CharStyle) -> CharStyle {
        var change = CharStyle()
        func keep<T: Equatable>(_ key: WritableKeyPath<CharStyle, T?>) {
            if self[keyPath: key] != old[keyPath: key] { change[keyPath: key] = self[keyPath: key] }
        }
        keep(\.font); keep(\.size); keep(\.bold); keep(\.italic); keep(\.underline); keep(\.strikethrough)
        keep(\.color); keep(\.underlineShape); keep(\.strikeShape); keep(\.shade); keep(\.ratio); keep(\.spacing)
        keep(\.superscript); keep(\.`subscript`); keep(\.outline); keep(\.shadow); keep(\.emboss); keep(\.engrave)
        return change
    }
    /// `self` with the fields `other` sets.
    func merging(_ other: CharStyle) -> CharStyle {
        var merged = self
        func take<T>(_ key: WritableKeyPath<CharStyle, T?>) {
            if let value = other[keyPath: key] { merged[keyPath: key] = value }
        }
        take(\.font); take(\.size); take(\.bold); take(\.italic); take(\.underline); take(\.strikethrough)
        take(\.color); take(\.underlineShape); take(\.strikeShape); take(\.shade); take(\.ratio); take(\.spacing)
        take(\.superscript); take(\.`subscript`); take(\.outline); take(\.shadow); take(\.emboss); take(\.engrave)
        return merged
    }
}

enum Alignment: String, Codable, CaseIterable, Sendable {
    case justify, left, center, right, distribute, split
}

enum LineSpacingKind: String, Codable, CaseIterable, Sendable {
    case percent, fixed, spaceOnly, minimum
}

/// Paragraph format; lengths are points. As a query result every field is set.
struct ParaStyle: Codable, Hashable, Sendable {
    var alignment: Alignment?
    /// Percent for `.percent`, otherwise points; sent together with `lineSpacingKind`.
    var lineSpacing: Double?
    var lineSpacingKind: LineSpacingKind?
    var marginLeft: Double?
    var marginRight: Double?
    /// First-line indent; negative hangs (내어쓰기).
    var indent: Double?
    var spacingBefore: Double?
    var spacingAfter: Double?
    var keepWithNext: Bool?
    var keepLines: Bool?
    var widowOrphan: Bool?
    var pageBreakBefore: Bool?

    /// The fields of `self` that differ from `old`; line spacing goes with its kind.
    func changes(from old: ParaStyle) -> ParaStyle {
        var change = ParaStyle()
        func keep<T: Equatable>(_ key: WritableKeyPath<ParaStyle, T?>) {
            if self[keyPath: key] != old[keyPath: key] { change[keyPath: key] = self[keyPath: key] }
        }
        keep(\.alignment); keep(\.marginLeft); keep(\.marginRight); keep(\.indent); keep(\.spacingBefore)
        keep(\.spacingAfter); keep(\.keepWithNext); keep(\.keepLines); keep(\.widowOrphan); keep(\.pageBreakBefore)
        if lineSpacing != old.lineSpacing || lineSpacingKind != old.lineSpacingKind {
            (change.lineSpacing, change.lineSpacingKind) = (lineSpacing, lineSpacingKind)
        }
        return change
    }
}

/// A caret motion, resolved against the engine's line layout.
enum Motion: String, Encodable, Sendable {
    case left, right
    /// To the start of the previous word / the end of the next word.
    case wordLeft, wordRight
    /// Edges of the word under the caret.
    case wordStart, wordEnd
    case lineStart, lineEnd, up, down, paragraphStart, paragraphEnd
    /// Edges of the body or of the cell holding the caret.
    case documentStart, documentEnd

    var isVertical: Bool { self == .up || self == .down }
}

struct Navigation: Decodable, Sendable {
    var position: EditPosition
    var caret: PageRect
    /// Column to keep for the next vertical motion.
    var goalX: Double
}

/// Format at the caret, with the font names the renderer tries in order.
struct Format: Decodable, Hashable, Sendable {
    var text: CharStyle
    var paragraph: ParaStyle
    var fonts: [String]
}

struct ParagraphInfo: Decodable, Sendable {
    var target: EditTarget
    /// Paragraphs in the same container (body or cell).
    var count: UInt32
    var text: String
    var editable: Bool
    var reason: String
}

/// 96 dpi, top-left origin within `page`.
struct PageRect: Decodable, Hashable, Sendable {
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
    /// The whole document as rendered.
    case pdf
}

/// The `op`-tagged request envelope understood by `hwp_edit_request`.
enum EngineRequest: Encodable, Sendable {
    case apply(revision: UInt64, EditCommand, amend: Bool)
    case paragraph(EditTarget)
    case hitTest(revision: UInt64, page: UInt32, x: Double, y: Double)
    case caret(revision: UInt64, EditPosition)
    case selectionRects(revision: UInt64, EditSelection)
    case format(revision: UInt64, EditPosition)
    case navigate(revision: UInt64, EditPosition, Motion, goalX: Double?)
    case find(query: String, caseSensitive: Bool)
    case pageSetup(section: UInt32)
    case export(SaveFormat)

    private enum Key: String, CodingKey {
        case op, request, target, revision, page, x, y, position, selection, format, motion, goalX, query, caseSensitive, section
    }
    private struct Apply: Encodable { var version = 1; var revision: UInt64; var command: EditCommand; var amend: Bool }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .apply(revision, command, amend):
            try c.encode("apply", forKey: .op)
            try c.encode(Apply(revision: revision, command: command, amend: amend), forKey: .request)
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
        case let .format(revision, position):
            try c.encode("format", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(position, forKey: .position)
        case let .navigate(revision, position, motion, goalX):
            try c.encode("navigate", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(position, forKey: .position)
            try c.encode(motion, forKey: .motion)
            try c.encodeIfPresent(goalX, forKey: .goalX)
        case let .find(query, caseSensitive):
            try c.encode("find", forKey: .op)
            try c.encode(query, forKey: .query)
            try c.encode(caseSensitive, forKey: .caseSensitive)
        case let .pageSetup(section):
            try c.encode("pageSetup", forKey: .op)
            try c.encode(section, forKey: .section)
        case let .export(format):
            try c.encode("export", forKey: .op)
            try c.encode(format, forKey: .format)
        }
    }
}
