import Foundation

// Mirrors Engine/crates/hwp-engine-abi/src/editing/protocol.rs (JSON, version 1).
// Offsets (`scalar`) count Unicode scalars, not UTF-16 units.

struct CellTarget: Codable, Hashable, Sendable {
    var control: UInt32
    var cell: UInt32
    var paragraph: UInt32
}

/// A paragraph of the 각주 or 미주 that is control `control` of the body paragraph.
struct NoteTarget: Codable, Hashable, Sendable {
    var control: UInt32
    var paragraph: UInt32
}

struct EditTarget: Codable, Hashable, Sendable {
    var section: UInt32
    var paragraph: UInt32
    var cell: CellTarget?
    var note: NoteTarget?
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
    /// 스타일 `style` (an index into the document's styles) for the selected paragraphs.
    case applyStyle(EditSelection, style: UInt32)
    case formatText(EditSelection, CharStyle)
    case formatParagraphs(EditSelection, ParaStyle)
    /// A new page (or column) from `position` in the body.
    case pageBreak(EditPosition, column: Bool)
    case insertTable(EditPosition, rows: Int, columns: Int)
    case insertPicture(EditPosition, data: Data, width: UInt32, height: UInt32,
                       naturalWidth: UInt32, naturalHeight: UInt32,
                       extension: String, description: String)
    case insertEquation(EditPosition, script: String, fontSize: UInt32, color: UInt32)
    /// A 각주 (or 미주) at `position`; the caret moves into it.
    case insertNote(EditPosition, endnote: Bool)
    /// A drawing object in front of the text, anchored at `position`; `x` and `y` place it
    /// from the paper's corner in HWPUNIT. A line runs corner to corner, `flip` turning it.
    case insertShape(EditPosition, shape: String, x: Int32, y: Int32, width: UInt32, height: UInt32, flip: Bool)
    /// Changes the properties set in `props` of a picture, equation or table.
    case setObject(ObjectRef, ObjectProps)
    /// Changes the properties set in `props` of the cell holding `target`.
    case setCell(EditTarget, CellProps)
    case deleteObject(ObjectRef)
    /// Moves a table border: column `line` becomes `size` wide (or, with `row`, row `line` that high).
    case resizeTable(ObjectRef, row: Bool, line: UInt16, size: UInt32)
    /// Adds or removes a row or column of the table holding the cell `target`.
    case editTable(EditTarget, TableChange)
    /// 셀 합치기, 셀 나누기, and 셀 높이를 같게 or 셀 너비를 같게, over the cells the
    /// selection covers (its cell, or the block between cells of one table).
    case mergeCells(EditSelection)
    case splitCells(EditSelection, rows: Int, columns: Int, equalHeight: Bool, mergeFirst: Bool)
    case equalizeCells(EditSelection, height: Bool)
    case setPage(section: UInt32, PageSetup)
    /// 머리말 or 꼬리말 for every page of a section: empty, or holding the page number.
    case headerFooter(section: UInt32, footer: Bool, pageNumber: Placement?)
    case undo
    case redo

    private enum Key: String, CodingKey {
        case kind, selection, text, position, style, column, rows, columns, data, width, height,
             naturalWidth, naturalHeight, `extension`, description, cell, change, section, page,
             footer, pageNumber, endnote, script, fontSize, color, object, props, equalHeight, mergeFirst, shape, x, y, flip, table, row, line, size
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
        case let .insertPicture(position, data, width, height, naturalWidth, naturalHeight, ext, description):
            try c.encode("insertPicture", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(data, forKey: .data)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
            try c.encode(naturalWidth, forKey: .naturalWidth)
            try c.encode(naturalHeight, forKey: .naturalHeight)
            try c.encode(ext, forKey: .extension)
            try c.encode(description, forKey: .description)
        case let .insertEquation(position, script, fontSize, color):
            try c.encode("insertEquation", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(script, forKey: .script)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(color, forKey: .color)
        case let .insertNote(position, endnote):
            try c.encode("insertNote", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(endnote, forKey: .endnote)
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
        case let .applyStyle(selection, style):
            try c.encode("applyStyle", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(style, forKey: .style)
        case let .mergeCells(selection):
            try c.encode("mergeCells", forKey: .kind)
            try c.encode(selection, forKey: .selection)
        case let .splitCells(selection, rows, columns, equalHeight, mergeFirst):
            try c.encode("splitCells", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(rows, forKey: .rows)
            try c.encode(columns, forKey: .columns)
            try c.encode(equalHeight, forKey: .equalHeight)
            try c.encode(mergeFirst, forKey: .mergeFirst)
        case let .equalizeCells(selection, height):
            try c.encode("equalizeCells", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(height, forKey: .height)
        case let .insertShape(position, shape, x, y, width, height, flip):
            try c.encode("insertShape", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(shape, forKey: .shape)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
            try c.encode(flip, forKey: .flip)
        case let .setObject(object, props):
            try c.encode("setObject", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(props, forKey: .props)
        case let .setCell(cell, props):
            try c.encode("setCell", forKey: .kind)
            try c.encode(cell, forKey: .cell)
            try c.encode(props, forKey: .props)
        case let .deleteObject(object):
            try c.encode("deleteObject", forKey: .kind)
            try c.encode(object, forKey: .object)
        case let .resizeTable(table, row, line, size):
            try c.encode("resizeTable", forKey: .kind)
            try c.encode(table, forKey: .table)
            try c.encode(row, forKey: .row)
            try c.encode(line, forKey: .line)
            try c.encode(size, forKey: .size)
        case .undo: try c.encode("undo", forKey: .kind)
        case .redo: try c.encode("redo", forKey: .kind)
        }
    }
}

enum Placement: String, Encodable, Sendable {
    case left, center, right
}

enum ObjectKind: String, Codable, Sendable {
    case picture, equation, table
    /// A drawing object: 가로 글상자, 직사각형, 타원, 직선 or 호.
    case shape
}

/// Control `control` of a body paragraph.
struct ObjectRef: Codable, Hashable, Sendable {
    var kind: ObjectKind
    var section: UInt32
    var paragraph: UInt32
    var control: UInt32
}

/// A table border on a page that can be dragged: the right border of column `line` (or
/// the bottom of row `line`) at `at`, running `from`–`to`, the column (row) starting at `start`.
struct TableLine: Decodable, Hashable, Sendable {
    var table: ObjectRef
    var row: Bool
    var line: UInt16
    var at: Double
    var start: Double
    var from: Double
    var to: Double
}

/// An object as laid out on a page.
struct PlacedObject: Decodable, Hashable, Sendable {
    var object: ObjectRef
    var rect: PageRect
}

/// Object properties in the engine's names and units (lengths in HWPUNIT). As a query
/// result the fields the object has are set; as a change, nil fields stay.
struct ObjectProps: PartialFormat {
    var width: UInt32?
    var height: UInt32?
    var sizeProtect: Bool?
    var treatAsChar: Bool?
    /// Square (어울림), TopAndBottom (자리 차지), BehindText (글 뒤로), InFrontOfText (글 앞으로).
    var textWrap: String?
    /// Paper, Page, Column, Para; Left, Center, Right.
    var horzRelTo: String?
    var horzAlign: String?
    var horzOffset: Int32?
    /// Paper, Page, Para; Top, Center, Bottom.
    var vertRelTo: String?
    var vertAlign: String?
    var vertOffset: Int32?
    var restrictInPage: Bool?
    var allowOverlap: Bool?
    /// Pictures and tables: None, Top, Bottom, or LeftTop … RightBottom (캡션 넣기).
    var caption: String?
    var outerMarginLeft: Int32?
    var outerMarginRight: Int32?
    var outerMarginTop: Int32?
    var outerMarginBottom: Int32?
    /// Pictures: 그림 여백. Tables: every cell's inner margin.
    var paddingLeft: Int32?
    var paddingRight: Int32?
    var paddingTop: Int32?
    var paddingBottom: Int32?
    var cropLeft: Int32?
    var cropRight: Int32?
    var cropTop: Int32?
    var cropBottom: Int32?
    /// Read only.
    var originalWidth: UInt32?
    var originalHeight: UInt32?
    /// −100–100.
    var brightness: Int32?
    var contrast: Int32?
    /// RealPic, GrayScale, BlackWhite.
    var effect: String?
    var rotationAngle: Int32?
    var horzFlip: Bool?
    var vertFlip: Bool?
    /// Tables: 0 나누지 않음, 1 나눔, 2 셀 단위로 나눔.
    var pageBreak: UInt8?
    var repeatHeader: Bool?
    var cellSpacing: Int32?
    var script: String?
    /// HWPUNIT, 100 per point.
    var fontSize: UInt32?
    /// 0x00bbggrr.
    var color: UInt32?
    var baseline: Int32?
}

/// Cell properties (lengths in HWPUNIT); nil fields stay.
struct CellProps: PartialFormat {
    var width: UInt32?
    var height: UInt32?
    var applyInnerMargin: Bool?
    var paddingLeft: Int32?
    var paddingRight: Int32?
    var paddingTop: Int32?
    var paddingBottom: Int32?
    /// 0 top, 1 center, 2 bottom.
    var verticalAlign: UInt8?
    var isHeader: Bool?
    var cellProtect: Bool?
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
}

/// A format whose fields are all optional: as a change, unset fields stay as they are.
/// Fields are compared and merged by their JSON names, so new fields need no code here.
protocol PartialFormat: Codable, Hashable, Sendable {
    init()
}

extension EditSelection {
    /// Whether the ends are in two cells of one table: a block of cells.
    var isCellBlock: Bool {
        guard let a = anchor.target.cell, let b = focus.target.cell else { return false }
        return (anchor.target.section, anchor.target.paragraph, a.control) == (focus.target.section, focus.target.paragraph, b.control)
            && a.cell != b.cell
    }
}

extension PartialFormat {
    private var fields: [String: NSObject] {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: NSObject] ?? [:]
    }
    private init(fields: [String: NSObject]) {
        let data = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        self = (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
    /// The fields of `self` that differ from `old`.
    func changes(from old: Self) -> Self {
        let before = old.fields
        return Self(fields: fields.filter { before[$0.key] != $0.value })
    }
    /// `self` with the fields `other` sets.
    func merging(_ other: Self) -> Self {
        Self(fields: fields.merging(other.fields) { $1 })
    }
}

/// Character format: as a query result every field is set; as a change, nil fields stay.
struct CharStyle: PartialFormat {
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
    /// `#rrggbb` of the underline and strikethrough lines.
    var underlineColor: String?
    var strikeColor: String?
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

}

enum Alignment: String, Codable, CaseIterable, Sendable {
    case justify, left, center, right, distribute, split
}

enum LineSpacingKind: String, Codable, CaseIterable, Sendable {
    case percent, fixed, spaceOnly, minimum
}

/// Paragraph format; lengths are points. As a query result every field is set.
struct ParaStyle: PartialFormat {
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
    /// The head: None, Number (문단 번호), Bullet (글머리표) or Outline. As a change,
    /// Number takes `numbering` (a kind, see `FormatChoices.numberings`) and Bullet takes
    /// `bullet` (its character).
    var head: String?
    var numbering: Int?
    var bullet: String?
    /// The list level, 0–6.
    var level: Int?
    /// 줄 나눔 기준: 한글 단위 0 어절, 1 글자; 영문 단위 0 단어, 1 하이픈, 2 글자.
    var koreanBreakUnit: Int?
    var englishBreakUnit: Int?
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
    /// The paragraph's 스타일.
    var style: UInt32
    /// The caret is in a 글상자, addressed like a table cell.
    var textBox: Bool
    var fonts: [String]
}

struct ParagraphInfo: Decodable, Sendable {
    var target: EditTarget
    /// Paragraphs in the same container (body or cell).
    var count: UInt32
    var text: String
}

/// One of the document's styles.
struct StyleInfo: Decodable, Hashable, Sendable {
    var id: UInt32
    var name: String
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
    case objectAt(revision: UInt64, page: UInt32, x: Double, y: Double)
    case place(revision: UInt64, ObjectRef, page: UInt32)
    case tableLines(revision: UInt64, page: UInt32)
    case objectProps(ObjectRef)
    case cellProps(EditTarget)
    case equationPreview(script: String, fontSize: UInt32, color: UInt32)
    case showMarks(paragraph: Bool, control: Bool)
    case styles
    case export(SaveFormat)

    private enum Key: String, CodingKey {
        case op, request, target, revision, page, x, y, position, selection, format, motion, goalX, query, caseSensitive, section,
             object, cell, script, fontSize, color, paragraph, control
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
        case let .objectAt(revision, page, x, y):
            try c.encode("objectAt", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(page, forKey: .page)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case let .tableLines(revision, page):
            try c.encode("tableLines", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(page, forKey: .page)
        case let .place(revision, object, page):
            try c.encode("place", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(object, forKey: .object)
            try c.encode(page, forKey: .page)
        case let .objectProps(object):
            try c.encode("objectProps", forKey: .op)
            try c.encode(object, forKey: .object)
        case let .cellProps(cell):
            try c.encode("cellProps", forKey: .op)
            try c.encode(cell, forKey: .cell)
        case let .equationPreview(script, fontSize, color):
            try c.encode("equationPreview", forKey: .op)
            try c.encode(script, forKey: .script)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(color, forKey: .color)
        case .styles:
            try c.encode("styles", forKey: .op)
        case let .showMarks(paragraph, control):
            try c.encode("showMarks", forKey: .op)
            try c.encode(paragraph, forKey: .paragraph)
            try c.encode(control, forKey: .control)
        case let .export(format):
            try c.encode("export", forKey: .op)
            try c.encode(format, forKey: .format)
        }
    }
}
