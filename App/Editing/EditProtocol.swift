import Foundation

// Mirrors Engine/crates/hwp-engine-abi/src/editing/protocol.rs.

enum EditProtocolVersion {
    static let current: UInt32 = 4
}
// Offsets (`scalar`) count Unicode scalars, not UTF-16 units.

/// A paragraph of a table cell, of a 글상자 (cell 0 of its shape), or of a caption (cell 0
/// of its picture, cell `caption` of its table).
struct CellTarget: Codable, Hashable, Sendable {
    var control: UInt32
    var cell: UInt32
    var paragraph: UInt32
    static let caption: UInt32 = 65_534
}

/// A paragraph of the 각주 or 미주 that is control `control` of the body paragraph.
struct NoteTarget: Codable, Hashable, Sendable {
    var control: UInt32
    var paragraph: UInt32
}

struct HeaderFooterTarget: Codable, Hashable, Sendable {
    var footer: Bool
    var applyTo: UInt8
    var page: UInt32
}

struct EditTarget: Codable, Hashable, Sendable {
    var section: UInt32
    var paragraph: UInt32
    var cell: CellTarget?
    var note: NoteTarget?
    var headerFooter: HeaderFooterTarget? = nil
}

struct EditPosition: Codable, Hashable, Sendable {
    var target: EditTarget
    var scalar: UInt32
    /// At the end of a wrapped line rather than the start of the next, the same scalar.
    var upstream = false

    private enum CodingKeys: String, CodingKey { case target, scalar, upstream }
    init(target: EditTarget, scalar: UInt32, upstream: Bool = false) {
        (self.target, self.scalar, self.upstream) = (target, scalar, upstream)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(EditTarget.self, forKey: .target)
        scalar = try c.decode(UInt32.self, forKey: .scalar)
        upstream = try c.decodeIfPresent(Bool.self, forKey: .upstream) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        try c.encode(scalar, forKey: .scalar)
        if upstream { try c.encode(upstream, forKey: .upstream) }
    }
}

struct EditSelection: Codable, Hashable, Sendable {
    var anchor: EditPosition
    var focus: EditPosition
    static func caret(_ position: EditPosition) -> Self { Self(anchor: position, focus: position) }
}

enum EditCommand: Encodable, Sendable {
    case replace(EditSelection, text: String)
    /// 모두 바꾸기: each of `selections` (in document order) that can change, as one edit.
    case replaceAll([EditSelection], text: String)
    /// Replaces the selection with copy `copy` while the engine holds it, or with `html`.
    case paste(EditSelection, copy: UInt64?, html: String?)
    case split(EditPosition)
    case mergePrevious(EditPosition)
    /// 스타일 `style` (an index into the document's styles) for the selected paragraphs.
    case applyStyle(EditSelection, style: UInt32)
    /// 스타일 추가하기 from the shapes at a position, 스타일 편집하기, 스타일 지우기 (its
    /// paragraphs take `replacement`), 한 줄 위로/아래로 이동하기, and 커서 위치의 스타일로
    /// 바꾸기.
    case addStyle(EditPosition, StyleSpec)
    case editStyle(UInt32, StyleSpec)
    case deleteStyle(UInt32, replacement: UInt32)
    case moveStyle(UInt32, up: Bool)
    case restyleFromCaret(UInt32, EditPosition)
    /// 사용된 글꼴 바꾸기 / 대체된 글꼴 바꾸기: `from` becomes `to` in `language` (an index
    /// into 한글…사용자), or in every 언어 for 대표.
    case replaceFont(language: UInt8?, from: String, to: String)
    case formatText(EditSelection, CharStyle)
    case formatParagraphs(EditSelection, ParaStyle)
    /// A new page (or column) from `position` in the body.
    case pageBreak(EditPosition, column: Bool)
    /// `width` and `height` (HWPUNIT) shared evenly by the columns and rows; `asCharacter`, 글자처럼 취급.
    case insertTable(EditPosition, rows: Int, columns: Int, width: UInt32? = nil, height: UInt32? = nil, asCharacter: Bool = false)
    case insertPicture(EditPosition, data: Data, width: UInt32, height: UInt32,
                       naturalWidth: UInt32, naturalHeight: UInt32,
                       extension: String, description: String)
    case insertEquation(EditPosition, script: String, fontSize: UInt32, color: UInt32)
    /// A 각주 (or 미주) at `position`; the caret moves into it.
    case insertNote(EditPosition, endnote: Bool)
    /// 필드 입력 › 누름틀: 안내문, 메모 내용, 필드 이름 and 양식 모드에서 편집 가능.
    case insertClickHere(EditPosition, guide: String, memo: String, name: String, formEditable: Bool)
    /// A 양식 개체's value (선택 상자, 라디오 단추) or text (입력 상자, 콤보 상자).
    case setForm(FormRef, value: Int32?, text: String?)
    /// 차트 데이터 편집 of chart `chart`.
    case setChartData(chart: UInt32, ChartData)
    /// 고치기 of the 누름틀 at the position.
    case editClickHere(EditPosition, guide: String, memo: String, name: String, formEditable: Bool)
    /// 입력 › 하이퍼링크: links the selected text, which becomes `text` (표시할 문자열), to
    /// the web address `uri`; with no selection `text` goes in at the caret.
    case insertHyperlink(EditSelection, text: String, uri: String)
    /// 하이퍼링크 고치기 of the link at the position.
    case editHyperlink(EditPosition, text: String, uri: String)
    /// 하이퍼링크 지우기: the link at the position goes; its text takes back its look.
    case removeHyperlink(EditPosition)
    /// A drawing object in front of the text, anchored at `position`; `x` and `y` place it
    /// from the paper's corner in HWPUNIT. A line runs corner to corner, `flip` turning it.
    case insertShape(EditPosition, shape: String, x: Int32, y: Int32, width: UInt32, height: UInt32, flip: Bool)
    /// Changes the properties set in `props` of a picture, equation or table.
    case setObject(ObjectRef, ObjectProps)
    /// Changes the properties set in `props` of the cell holding `target`.
    case setCell(EditTarget, CellProps)
    case deleteObject(ObjectRef)
    /// 순서: a drawing object of the body among the section's drawing objects.
    case order(ObjectRef, Order)
    /// 블록 합계, 블록 평균 or 블록 곱 over the block `selection` covers.
    case calculateBlock(EditSelection, BlockFunction)
    /// Moves the start (or, with `end`, the end) of a 직선 by `dx`, `dy` (HWPUNIT).
    case moveLineEnd(ObjectRef, end: Bool, dx: Int32, dy: Int32)
    /// 개체 풀기.
    case ungroup(ObjectRef)
    /// 개체 묶기.
    case group([ObjectRef])
    /// 그림 바꾸기: another image in the picture, which keeps its size and place.
    case replacePicture(ObjectRef, data: Data, naturalWidth: UInt32, naturalHeight: UInt32, extension: String)
    /// 경로 바꾸기 and 그림 확장자 바꾸기 of a 연결 picture.
    case setPictureLink(ObjectRef, path: String)
    /// 도형 안에 글자 넣기, or without `attach` 글상자 속성 없애기.
    case setTextBox(ObjectRef, attach: Bool)
    /// Moves an equation to another place in the text.
    case moveObject(ObjectRef, to: EditPosition)
    /// Moves a table border: column `line` becomes `size` wide (or, with `row`, row `line` that high).
    case resizeTable(ObjectRef, row: Bool, line: UInt16, size: UInt32)
    /// Adds or removes a row or column of the table holding the cell `target`.
    case editTable(EditTarget, TableChange)
    /// 표 뒤집기; with `margins` the cells' 안 여백 turn too.
    case flipTable(EditTarget, TableTurn, margins: Bool)
    /// 셀 합치기, 셀 나누기, and 셀 높이를 같게 or 셀 너비를 같게, over the cells the
    /// selection covers (its cell, or the block between cells of one table).
    case mergeCells(EditSelection)
    case splitCells(EditSelection, rows: Int, columns: Int, equalHeight: Bool, mergeFirst: Bool)
    case equalizeCells(EditSelection, height: Bool)
    /// With `whole`, every section (적용 범위 문서 전체).
    case setPage(section: UInt32, PageSetup, whole: Bool = false)
    /// 쪽 테두리/배경; with `whole`, of every section.
    case setPageBorder(section: UInt32, PageBorder, whole: Bool)
    /// 셀 테두리/배경 of the cells the selection covers, or of every cell (`all`); each for
    /// itself, or as one cell (`one`).
    case setCellBorder(EditSelection, all: Bool, one: Bool, CellBorder)
    /// 각주 모양 (`footnote`) or 미주 모양; with `whole`, of every section.
    case setNoteShape(section: UInt32, footnote: Bool, NoteShape, whole: Bool)
    /// 구역 설정; with `whole`, of every section.
    case setSection(section: UInt32, SectionSetup, whole: Bool)
    /// 머리말 or 꼬리말 for every page of a section: empty, or holding the page number.
    case headerFooter(section: UInt32, footer: Bool, pageNumber: Placement?)
    /// 머리말/꼬리말 지우기: the definition `target` is in.
    case deleteHeaderFooter(EditTarget)
    /// 단 하나, 둘 or 셋 for a section with one column definition.
    case setColumns(section: UInt32, count: UInt16)
    /// 새 번호로 시작 at a body position; a paragraph that already starts the kind anew changes its number.
    case newNumber(EditPosition, numbering: NumberKind, number: UInt16)
    /// 현재 쪽만 감추기 for the body paragraph `target`; nothing hidden takes it out.
    case setPageHide(EditTarget, PageHide)
    case addBookmark(EditPosition, name: String)
    /// 책갈피 이름 바꾸기, or without `name` 지우기.
    case changeBookmark(EditTarget, control: UInt32, name: String?)
    /// 조판 부호 지우기 in the body, or in `selection`.
    case eraseCodes(EditSelection?, kinds: [CodeKind])
    case undo
    case redo

    private enum Key: String, CodingKey {
        case kind, selection, text, position, style, column, rows, columns, data, width, height,
             naturalWidth, naturalHeight, `extension`, description, cell, change, section, page,
             footer, pageNumber, endnote, script, fontSize, color, object, props, equalHeight, mergeFirst, shape, x, y, flip, table, row, line, size, to, order, attach, function, count, target, copy, html, selections, end, dx, dy,
             numbering, number, hide, name, control, kinds, whole, treatAsChar, objects, turn, margins, border, setup, footnote, spec, replacement, up, language, from, all, one, path, guide, memo, formEditable, form, value, chart, uri
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .replace(selection, text):
            try c.encode("replace", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(text, forKey: .text)
        case let .replaceAll(selections, text):
            try c.encode("replaceAll", forKey: .kind)
            try c.encode(selections, forKey: .selections)
            try c.encode(text, forKey: .text)
        case let .paste(selection, copy, html):
            try c.encode("paste", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encodeIfPresent(copy, forKey: .copy)
            try c.encodeIfPresent(html, forKey: .html)
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
        case let .insertTable(position, rows, columns, width, height, asCharacter):
            try c.encode("insertTable", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(rows, forKey: .rows)
            try c.encode(columns, forKey: .columns)
            try c.encodeIfPresent(width, forKey: .width)
            try c.encodeIfPresent(height, forKey: .height)
            try c.encode(asCharacter, forKey: .treatAsChar)
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
        case let .flipTable(cell, turn, margins):
            try c.encode("flipTable", forKey: .kind)
            try c.encode(cell, forKey: .cell)
            try c.encode(turn, forKey: .turn)
            try c.encode(margins, forKey: .margins)
        case let .setPage(section, page, whole):
            try c.encode("setPage", forKey: .kind)
            try c.encode(section, forKey: .section)
            try c.encode(page, forKey: .page)
            try c.encode(whole, forKey: .whole)
        case let .setPageBorder(section, border, whole):
            try c.encode("setPageBorder", forKey: .kind)
            try c.encode(section, forKey: .section)
            try c.encode(border, forKey: .border)
            try c.encode(whole, forKey: .whole)
        case let .setChartData(chart, data):
            try c.encode("setChartData", forKey: .kind)
            try c.encode(chart, forKey: .chart)
            try c.encode(data, forKey: .data)
        case let .setForm(form, value, text):
            try c.encode("setForm", forKey: .kind)
            try c.encode(form, forKey: .form)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encodeIfPresent(text, forKey: .text)
        case let .editClickHere(position, guide, memo, name, formEditable):
            try c.encode("editClickHere", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(guide, forKey: .guide)
            try c.encode(memo, forKey: .memo)
            try c.encode(name, forKey: .name)
            try c.encode(formEditable, forKey: .formEditable)
        case let .insertHyperlink(selection, text, uri):
            try c.encode("insertHyperlink", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(text, forKey: .text)
            try c.encode(uri, forKey: .uri)
        case let .editHyperlink(position, text, uri):
            try c.encode("editHyperlink", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(text, forKey: .text)
            try c.encode(uri, forKey: .uri)
        case let .removeHyperlink(position):
            try c.encode("removeHyperlink", forKey: .kind)
            try c.encode(position, forKey: .position)
        case let .insertClickHere(position, guide, memo, name, formEditable):
            try c.encode("insertClickHere", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(guide, forKey: .guide)
            try c.encode(memo, forKey: .memo)
            try c.encode(name, forKey: .name)
            try c.encode(formEditable, forKey: .formEditable)
        case let .setPictureLink(object, path):
            try c.encode("setPictureLink", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(path, forKey: .path)
        case let .setCellBorder(selection, all, one, border):
            try c.encode("setCellBorder", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(all, forKey: .all)
            try c.encode(one, forKey: .one)
            try c.encode(border, forKey: .border)
        case let .setNoteShape(section, footnote, shape, whole):
            try c.encode("setNoteShape", forKey: .kind)
            try c.encode(section, forKey: .section)
            try c.encode(footnote, forKey: .footnote)
            try c.encode(shape, forKey: .shape)
            try c.encode(whole, forKey: .whole)
        case let .setSection(section, setup, whole):
            try c.encode("setSection", forKey: .kind)
            try c.encode(section, forKey: .section)
            try c.encode(setup, forKey: .setup)
            try c.encode(whole, forKey: .whole)
        case let .headerFooter(section, footer, pageNumber):
            try c.encode("headerFooter", forKey: .kind)
            try c.encode(section, forKey: .section)
            try c.encode(footer, forKey: .footer)
            try c.encode(pageNumber, forKey: .pageNumber)
        case let .applyStyle(selection, style):
            try c.encode("applyStyle", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(style, forKey: .style)
        case let .addStyle(position, spec):
            try c.encode("addStyle", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(spec, forKey: .style)
        case let .editStyle(style, spec):
            try c.encode("editStyle", forKey: .kind)
            try c.encode(style, forKey: .style)
            try c.encode(spec, forKey: .spec)
        case let .deleteStyle(style, replacement):
            try c.encode("deleteStyle", forKey: .kind)
            try c.encode(style, forKey: .style)
            try c.encode(replacement, forKey: .replacement)
        case let .moveStyle(style, up):
            try c.encode("moveStyle", forKey: .kind)
            try c.encode(style, forKey: .style)
            try c.encode(up, forKey: .up)
        case let .replaceFont(language, from, to):
            try c.encode("replaceFont", forKey: .kind)
            try c.encodeIfPresent(language, forKey: .language)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case let .restyleFromCaret(style, position):
            try c.encode("restyleFromCaret", forKey: .kind)
            try c.encode(style, forKey: .style)
            try c.encode(position, forKey: .position)
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
        case let .moveObject(object, to):
            try c.encode("moveObject", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(to, forKey: .to)
        case let .deleteObject(object):
            try c.encode("deleteObject", forKey: .kind)
            try c.encode(object, forKey: .object)
        case let .deleteHeaderFooter(target):
            try c.encode("deleteHeaderFooter", forKey: .kind)
            try c.encode(target, forKey: .target)
        case let .setColumns(section, count):
            try c.encode("setColumns", forKey: .kind)
            try c.encode(section, forKey: .section)
            try c.encode(count, forKey: .count)
        case let .newNumber(position, numbering, number):
            try c.encode("newNumber", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(numbering, forKey: .numbering)
            try c.encode(number, forKey: .number)
        case let .setPageHide(target, hide):
            try c.encode("setPageHide", forKey: .kind)
            try c.encode(target, forKey: .target)
            try c.encode(hide, forKey: .hide)
        case let .addBookmark(position, name):
            try c.encode("addBookmark", forKey: .kind)
            try c.encode(position, forKey: .position)
            try c.encode(name, forKey: .name)
        case let .changeBookmark(target, control, name):
            try c.encode("changeBookmark", forKey: .kind)
            try c.encode(target, forKey: .target)
            try c.encode(control, forKey: .control)
            try c.encode(name, forKey: .name)
        case let .eraseCodes(selection, kinds):
            try c.encode("eraseCodes", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(kinds, forKey: .kinds)
        case let .calculateBlock(selection, function):
            try c.encode("calculateBlock", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(function, forKey: .function)
        case let .moveLineEnd(object, end, dx, dy):
            try c.encode("moveLineEnd", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(end, forKey: .end)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case let .ungroup(object):
            try c.encode("ungroup", forKey: .kind)
            try c.encode(object, forKey: .object)
        case let .group(objects):
            try c.encode("group", forKey: .kind)
            try c.encode(objects, forKey: .objects)
        case let .replacePicture(object, data, naturalWidth, naturalHeight, ext):
            try c.encode("replacePicture", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(data, forKey: .data)
            try c.encode(naturalWidth, forKey: .naturalWidth)
            try c.encode(naturalHeight, forKey: .naturalHeight)
            try c.encode(ext, forKey: .extension)
        case let .setTextBox(object, attach):
            try c.encode("setTextBox", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(attach, forKey: .attach)
        case let .order(object, order):
            try c.encode("order", forKey: .kind)
            try c.encode(object, forKey: .object)
            try c.encode(order, forKey: .order)
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

enum BlockFunction: String, Encodable, Sendable {
    case sum, average, product
}

/// 복사하기 with formats: the selection as HTML, and the copy's number in the engine.
struct Copied: Decodable, Sendable {
    var html: String
    var copy: UInt64
}

/// 맨 앞으로, 앞으로, 맨 뒤로, 뒤로.
enum Order: String, Encodable, Sendable {
    case front, forward, back, backward
}

enum ObjectKind: String, Codable, Sendable {
    case picture, equation, table
    /// A drawing object: 가로 글상자, 직사각형, 타원, 직선 or 호.
    case shape
}

/// Control `control` of a body paragraph, or of paragraph `cell` of one of its tables or 글상자.
struct ObjectRef: Codable, Hashable, Sendable {
    var kind: ObjectKind
    var section: UInt32
    var paragraph: UInt32
    var control: UInt32
    var cell: CellTarget? = nil
    /// The 미주 paragraph holding an equation.
    var note: NoteTarget? = nil
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
    /// A group of drawing objects, for 개체 풀기.
    var group: Bool
    /// A drawing object that can hold text, and whether it does.
    var textBox: Bool?
    /// A 직선's start and end on the page (x, y, x, y in page pixels).
    var ends: [Double]?
    /// A 차트: its number in the document.
    var chart: UInt32?
}
/// 차트 데이터: the 줄 names, and each 칸 (series) with its name and values.
struct ChartData: Codable, Hashable, Sendable {
    var labels: [String]
    var series: [ChartSeries]
}
struct ChartSeries: Codable, Hashable, Sendable {
    var name: String
    var values: [String]
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
    /// 캡션 크기 (of a caption beside the object) and 개체와의 간격, HWPUNIT; 여백 부분까지 너비 확대.
    var captionWidth: UInt32?
    var captionSpacing: Int32?
    var captionIncludeMargin: Bool?
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
    /// Tables: 표 테두리/배경, its four sides and 배경.
    var tableBorder: CellBorder?
    /// Drawing objects' 그림자: 종류 (0 none, 1 왼쪽 위, 2 오른쪽 위, 3 왼쪽 아래, 4 오른쪽 아래,
    /// 5 왼쪽 뒤, 6 오른쪽 뒤, 7 왼쪽 앞, 8 오른쪽 앞, 9 작게, 10 크게), color (0x00bbggrr),
    /// offsets (HWPUNIT, y down) and 투명도 (0 opaque – 255).
    var shadowType: UInt32?
    var shadowColor: UInt32?
    var shadowOffsetX: Int32?
    var shadowOffsetY: Int32?
    var shadowAlpha: UInt32?
    /// 글상자: 안쪽 여백 and 세로 정렬 (Top, Center, Bottom).
    var tbMarginLeft: Int32?
    var tbMarginRight: Int32?
    var tbMarginTop: Int32?
    var tbMarginBottom: Int32?
    var tbVerticalAlign: String?
    /// Rectangles: 사각형 모서리 곡률, 0–50 %.
    var roundRate: UInt32?
    var script: String?
    /// HWPUNIT, 100 per point.
    var fontSize: UInt32?
    /// 0x00bbggrr.
    var color: UInt32?
    var baseline: Int32?
    /// Drawing objects' 선: color (0x00bbggrr), width (HWPUNIT), 종류 (0 none, 1 solid … 11),
    /// 끝 모양 (0 round, 1 flat), and 화살표 shapes (0–6) and sizes (0–8).
    var borderColor: UInt32?
    var borderWidth: Int32?
    var lineType: UInt32?
    var lineEndShape: UInt32?
    var arrowStart: UInt32?
    var arrowEnd: UInt32?
    var arrowStartSize: UInt32?
    var arrowEndSize: UInt32?
    /// Drawing objects' 채우기: none or solid (also gradient or image as read), 면 색 and 무늬 색,
    /// 무늬 모양 (0 or −1 none, 1–6) and 투명도 (0 opaque – 255).
    var fillType: String?
    var fillBgColor: UInt32?
    var fillPatColor: UInt32?
    var fillPatType: Int32?
    var fillAlpha: UInt32?
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
    /// 표 나누기 and 표 붙이기.
    case split, attach
}

/// 표 뒤집기: 줄 기준 뒤집기, 칸 기준 뒤집기, 줄/칸 뒤집기, and 반시계 방향 90도, 180도,
/// 시계 방향 90도.
enum TableTurn: String, Encodable, Sendable, CaseIterable {
    case rows, columns, diagonal, left, half, right
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
    /// 제본: 0 한쪽, 1 맞쪽, 2 위로.
    var binding: UInt8
}

/// A section's 쪽 테두리/배경. `sides` and `spacing` run 왼쪽, 오른쪽, 위쪽, 아래쪽, spacings
/// in HWPUNIT.
struct PageBorder: Codable, Hashable, Sendable {
    var sides: [BorderSide]
    /// 위치: 종이 기준, else 쪽 기준.
    var paper: Bool
    var spacing: [UInt32]
    var headerInside: Bool
    var footerInside: Bool
    var borderPages: ApplyPages
    var fillPages: ApplyPages
    /// 배경 by color; nil when it is a 그러데이션 or 그림, which then stays.
    var fill: PageFill?
    var fillArea: FillArea
}
/// 각주 모양 or 미주 모양, in rhwp's names: 번호 모양 (`digit`, …, `fourSymbol`, `userChar`),
/// 기호 모양 and 앞/뒤 장식 문자 (one character or empty), 구분선 (길이 in HWPUNIT, or −1
/// 5 cm, −2 2 cm, −3 a third and −4 all of the column), 여백 in HWPUNIT, and 번호 매기기
/// (`continue`, `restartSection`, `restartPage`).
struct NoteShape: Codable, Hashable, Sendable {
    var numberFormat: String
    var userChar: String
    var prefixChar: String
    var suffixChar: String
    var separatorEnabled: Bool
    var separatorLength: Int32
    var separatorLineType: UInt8
    var separatorLineWidth: UInt8
    var separatorColor: String
    var separatorMarginTop: Int32
    var separatorMarginBottom: Int32
    var noteSpacing: Int32
    var numbering: String
}
/// 구역 설정: 시작 쪽 번호 (`pageNum`, 0 continuing; `pageNumType` 0 이어서, 1 홀수, 2 짝수),
/// 개체 시작 번호 (0 continuing), the 첫 쪽에만 감추기 flags, 빈 줄 감추기, and 단 사이 간격
/// and 기본 탭 간격 in HWPUNIT.
struct SectionSetup: Codable, Hashable, Sendable {
    var pageNum: UInt16
    var pageNumType: UInt8
    var pictureNum: UInt16
    var tableNum: UInt16
    var equationNum: UInt16
    var columnSpacing: Int32
    var defaultTabSpacing: UInt32
    var hideHeader: Bool
    var hideFooter: Bool
    var hideMasterPage: Bool
    var hideBorder: Bool
    var hideFill: Bool
    var hideEmptyLine: Bool
}
/// Line kind (0 none, 1 solid, …), width (an index into `Swatches.widths`) and `#rrggbb`.
struct BorderSide: Codable, Hashable, Sendable {
    var line: UInt8
    var width: UInt8
    var color: String
}
/// 셀 테두리/배경: 왼쪽, 오른쪽, 위쪽, 아래쪽, then the 가로 and 세로 lines inside a block;
/// 배경 (nil while a 그러데이션 or 그림 stays); 대각선. Nil stays as it is.
struct CellBorder: Codable, Hashable, Sendable {
    var sides: [BorderSide?] = Array(repeating: nil, count: 6)
    var fill: PageFill?
    var diagonal: Diagonal?
}
/// 대각선: its line, ＼ and ／, and 중심선 (0 none, 1 가로, 2 세로, 3 both).
struct Diagonal: Codable, Hashable, Sendable {
    var line: BorderSide
    var slash: Bool
    var backSlash: Bool
    var center: UInt8
}
/// 면 색 (`#rrggbb`, or `none`), 무늬 색 and 무늬 모양 (0 none, 1–6).
struct PageFill: Codable, Hashable, Sendable {
    var color: String
    var patternColor: String
    var pattern: UInt8
    /// 셀·표 배경 only: a 그러데이션 or 그림 in place of the color.
    var gradient: Gradient?
    var image: ImageBrush?
}
/// 그러데이션: 모양 (1 줄무늬, 2 원형, 3 원뿔형, 4 사각형), 시작 색 and 끝 색, 기울임, 가로/세로
/// 중심 (%), 번짐 정도 and 번짐 중심 (%).
struct Gradient: Codable, Hashable, Sendable {
    var kind: UInt8 = 1
    var colors = ["#ffffff", "#000000"]
    var angle: Int16 = 0
    var centerX: Int16 = 50
    var centerY: Int16 = 50
    var blur: UInt8 = 0
    var stepCenter: UInt8 = 50
}
/// 그림 배경: a new image (`data` with its `extension`) or the document's (`binId`); 채우기
/// 유형, 그림 효과 (0 원래 그림, 1 회색조, 2 흑백), 밝기 and 대비.
struct ImageBrush: Codable, Hashable, Sendable {
    var data: Data?
    var `extension`: String?
    var binId: UInt16 = 0
    var mode: UInt8 = 5
    var effect: UInt8 = 0
    var brightness: Int8 = 0
    var contrast: Int8 = 0
}
/// 적용 쪽: 모두, 첫 쪽 제외, 첫 쪽만.
enum ApplyPages: String, Codable, Sendable {
    case all, exceptFirst, firstOnly
}
/// 채울 영역: 종이, 쪽, 테두리.
enum FillArea: String, Codable, Sendable {
    case paper, page, border
}

struct EditReply: Decodable, Sendable {
    var version: UInt32 = EditProtocolVersion.current
    var revision: UInt64
    var selection: EditSelection?
    /// Caret rectangle of the selection focus, laid out with this revision.
    var caret: PageRect?
    var pageCount: UInt32
    /// Pages re-rendered by this revision; the accompanying PDF holds exactly these, in order.
    var changedPages: [UInt32]
    /// Body area of each changed page, in order.
    var bodies: [PageRect]?
    var canUndo: Bool
    var canRedo: Bool
    var dirty: Bool
    /// The document cannot be edited.
    var locked: Bool?
}

/// A format whose fields are all optional: as a change, unset fields stay as they are.
/// Fields are compared and merged by their JSON names, so new fields need no code here.
protocol PartialFormat: Codable, Hashable, Sendable {
    init()
}

extension EditSelection {
    /// Whether `position` is in the same body, table (any of its cells) or note as the anchor,
    /// the only places a selection can reach.
    func reaches(_ position: EditPosition) -> Bool {
        let (a, b) = (anchor.target, position.target)
        if a.section != b.section { return false }
        switch (a.cell, b.cell, a.note, b.note) {
        case (nil, nil, nil, nil): return true
        case let (x?, y?, nil, nil): return a.paragraph == b.paragraph && x.control == y.control
        case let (nil, nil, x?, y?): return a.paragraph == b.paragraph && x.control == y.control
        default: return false
        }
    }
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
    /// As a change, the 언어 (0 한글, 1 영문, 2 한자, 3 일어, 4 외국어, 5 기호, 6 사용자) whose
    /// font, 상대 크기, 장평, 글자 위치 and 자간 change; nil, all of them (대표).
    var language: Int?
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
    /// 밑줄 위치 위.
    var underlineTop: Bool?
    /// 상대 크기 (10–250%) and 글자 위치 (−100–100%).
    var relativeSize: Double?
    var offset: Double?
    /// 테두리: 종류 (0 none, 1 solid, …), 굵기 (an index into `BorderWidths`) and color;
    /// 배경: 면 색 (`#rrggbb` or `none`), 무늬 색 and 무늬 모양 (0 none, 1–6). Sent all together.
    var borderLine: Int?
    var borderWidth: Int?
    var borderColor: String?
    var fillColor: String?
    var patternColor: String?
    var pattern: Int?
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
    /// 테두리: 종류 (0 none, 1 solid, …), 굵기 (an index into `BorderWidths`) and color;
    /// 배경: 면 색 (`#rrggbb` or `none`), 무늬 색 and 무늬 모양 (0 none, 1–6). Sent all together.
    var borderLine: Int?
    var borderWidth: Int?
    var borderColor: String?
    var fillColor: String?
    var patternColor: String?
    var pattern: Int?
    /// 문단 테두리 연결.
    var borderConnect: Bool?
    /// 시작 번호 방식, in the body: 0 앞 번호 목록에 이어, 1 이전 번호 목록에 이어, 2 새 번호
    /// 목록 시작 at `startNumber` (1수준 시작 번호).
    var restart: Int?
    var startNumber: Int?
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
    /// From a 머리말 (or 꼬리말) to the one on the next (or previous) page that has one.
    case nextHeaderFooter, previousHeaderFooter

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
    /// The font, 상대 크기, 장평, 글자 위치 and 자간 of each 언어, in `CharStyle.language` order.
    var languages: [CharStyle]
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
struct StyleInfo: Decodable, Hashable, Identifiable, Sendable {
    var id: UInt32
    var name: String
    var englishName: String
    /// 문단 스타일, else 글자 스타일.
    var paragraphStyle: Bool
    /// 다음 문단에 적용할 스타일.
    var next: UInt32
}

/// A style's names, kind and next style, and the changes to lay over its shapes: `text`
/// holds the 대표 change and then each 언어 set apart.
struct StyleSpec: Encodable, Hashable, Sendable {
    var name: String
    var englishName: String
    var paragraphStyle: Bool
    var next: UInt32
    var text: [CharStyle] = []
    var paragraph = ParaStyle()
}

extension EditCommand {
    /// Whether the command may change the list of styles.
    var changesStyles: Bool {
        switch self {
        case .addStyle, .editStyle, .deleteStyle, .moveStyle, .restyleFromCaret, .undo, .redo: true
        default: false
        }
    }
}

/// 번호 종류 of 새 번호로 시작, in the dialog's order.
enum NumberKind: String, Codable, CaseIterable, Sendable {
    case page, picture, table, equation, footnote, endnote
    var title: String {
        switch self {
        case .page: "쪽 번호"
        case .picture: "그림 번호"
        case .table: "표 번호"
        case .equation: "수식 번호"
        case .footnote: "각주 번호"
        case .endnote: "미주 번호"
        }
    }
}

/// 감출 내용 of 현재 쪽만 감추기.
struct PageHide: Codable, Hashable, Sendable {
    var header = false
    var footer = false
    var pageNumber = false
    /// 쪽 테두리/배경.
    var borderFill = false
    /// 바탕쪽.
    var masterPage = false
}

/// A code 조판 부호 지우기 can take out.
enum CodeKind: Encodable, Hashable, Sendable {
    case footnote, endnote, pageHide, drawing, textBox, picture, table, equation, header, footer, pageNumberPosition
    case newNumber(NumberKind)

    /// 개체 선택, in the order 한글's help lists it.
    static let all: [CodeKind] = [
        .footnote, .pageHide, .drawing, .picture, .textBox, .footer, .header, .endnote,
        .newNumber(.footnote), .newNumber(.picture), .newNumber(.endnote), .newNumber(.equation), .newNumber(.page), .newNumber(.table),
        .equation, .pageNumberPosition, .table,
    ]
    var title: String {
        switch self {
        case .footnote: "각주"
        case .endnote: "미주"
        case .pageHide: "감추기"
        case .drawing: "그리기"
        case .textBox: "글상자"
        case .picture: "그림"
        case .table: "표"
        case .equation: "수식"
        case .header: "머리말"
        case .footer: "꼬리말"
        case .pageNumberPosition: "쪽 번호 위치"
        case let .newNumber(kind): "새 " + kind.title
        }
    }
    private enum Key: String, CodingKey { case newNumber }
    func encode(to encoder: Encoder) throws {
        if case let .newNumber(kind) = self {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(kind, forKey: .newNumber)
        } else {
            var c = encoder.singleValueContainer()
            try c.encode(String(describing: self))
        }
    }
}

/// A 책갈피 of the body.
struct Bookmark: Decodable, Hashable, Sendable {
    var name: String
    var position: EditPosition
    var control: UInt32
}

/// A font of 글꼴 정보; one this Mac lacks is a 대체된 글꼴.
struct UsedFont: Decodable, Hashable, Sendable {
    var name: String
    var installed: Bool
}

/// A picture of 그림 정보.
struct PictureInfo: Decodable, Hashable, Sendable, Identifiable {
    var id: ObjectRef { object }
    var name: String
    var linked: Bool
    var page: UInt32
    var path: String
    var object: ObjectRef
}

/// A 양식 개체: control `control` of the paragraph (in a table's cell when `cell`).
struct FormRef: Codable, Hashable, Sendable {
    var section: UInt32
    var paragraph: UInt32
    var control: UInt32
    var cell: CellTarget?
}
/// A 양식 개체 under the pointer.
struct FormInfo: Decodable, Hashable, Sendable {
    var form: FormRef
    /// PushButton, CheckBox, ComboBox, RadioButton or Edit.
    var kind: String
    var name: String
    var caption: String
    var value: Int32
    var text: String
    var enabled: Bool
    var items: [String]
    var rect: PageRect
}

/// A 누름틀 as 필드 입력 shows it.
struct ClickHere: Decodable, Hashable, Sendable {
    var guide: String
    var memo: String
    var name: String
    var formEditable: Bool
}

/// A 하이퍼링크: 표시할 문자열 and its web address.
struct Hyperlink: Decodable, Hashable, Sendable {
    var text: String
    var uri: String

    /// An http or https address with a host, as rhwp writes links.
    static func isWebAddress(_ uri: String) -> Bool {
        guard !uri.contains(where: \.isWhitespace), let url = URL(string: uri),
              ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false else { return false }
        return true
    }
    /// 웹 주소 자동 연결: the web address `text` ends with, before the spaces after it, as
    /// scalar offsets and the address to link; a trailing mark of punctuation stays out.
    static func typedAddress(_ text: String) -> (start: Int, end: Int, uri: String)? {
        let scalars = Array(text.unicodeScalars)
        var end = scalars.count
        while end > 0, CharacterSet.whitespacesAndNewlines.contains(scalars[end - 1]) { end -= 1 }
        var start = end
        while start > 0, !CharacterSet.whitespacesAndNewlines.contains(scalars[start - 1]) { start -= 1 }
        while end > start, ".,;:!?)]}\"'".unicodeScalars.contains(scalars[end - 1]) { end -= 1 }
        let word = String(String.UnicodeScalarView(scalars[start..<end]))
        let lower = word.lowercased()
        let uri = lower.hasPrefix("http://") || lower.hasPrefix("https://") ? word
            : lower.hasPrefix("www.") ? "http://" + word : nil
        guard let uri, isWebAddress(uri) else { return nil }
        return (start, end, uri)
    }
}

/// 개요 보기's 개요 문단: its 수준 (1–7), its number as drawn, and its text.
struct OutlineItem: Decodable, Hashable, Sendable {
    var level: UInt8
    var number: String
    var title: String
    var position: EditPosition
}

/// 문서 정보 › 문서 통계.
struct Statistics: Decodable, Hashable, Sendable {
    var characters, charactersWithoutSpaces, hanja, words, lines, paragraphs, pages, manuscript: UInt32
    var tables, pictures, textBoxes: UInt32
}

/// 상황 선 for the caret, 1-based as 한글 shows it.
struct CaretStatus: Decodable, Hashable, Sendable {
    var page, column, line, character, section, sections: UInt32
    /// The cell's address, as A1.
    var cell: String?
    /// 글자 수 of the document.
    var characters: UInt32
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
    case incompatibleEngine = "IncompatibleEngine"
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
    /// With the app's `selection`, which commands that leave the text alone keep.
    case apply(revision: UInt64, EditCommand, amend: Bool, selection: EditSelection? = nil)
    case paragraph(EditTarget)
    case hitTest(revision: UInt64, page: UInt32, x: Double, y: Double, includeHeaderFooter: Bool)
    case caret(revision: UInt64, EditPosition)
    case selectionRects(revision: UInt64, EditSelection)
    /// With `from`, of the characters selected between the two positions.
    case format(revision: UInt64, EditPosition, from: EditPosition?)
    case navigate(revision: UInt64, EditPosition, Motion, goalX: Double?)
    case find(query: String, caseSensitive: Bool)
    case pageSetup(section: UInt32)
    case pageBorder(section: UInt32)
    case styleFormat(UInt32)
    case sectionSetup(section: UInt32)
    case noteShape(section: UInt32, footnote: Bool)
    case pageHide(EditTarget)
    case bookmarks
    case outline
    case fonts
    case clickHereAt(EditPosition)
    case hyperlinkAt(EditPosition)
    case pictures
    case statistics
    case hasPassword
    /// 문서 암호 설정 (no `current`), 변경 and 해제 (no `new`).
    case setPassword(current: String?, new: String?)
    case status(revision: UInt64, EditPosition)
    case objectAt(revision: UInt64, page: UInt32, x: Double, y: Double)
    case place(revision: UInt64, ObjectRef, page: UInt32)
    case tableLines(revision: UInt64, page: UInt32)
    case objects(revision: UInt64, page: UInt32)
    case formAt(revision: UInt64, page: UInt32, x: Double, y: Double)
    case chartData(UInt32)
    case objectProps(ObjectRef)
    /// 삽입 그림 저장하기: the picture's image file.
    case pictureFile(ObjectRef)
    case cellProps(EditTarget)
    case cellBorder(EditTarget)
    case equationPreview(script: String, fontSize: UInt32, color: UInt32)
    /// An equation script as LaTeX, or with `fromLatex`, LaTeX as a script.
    case convertEquation(String, fromLatex: Bool)
    /// 문단 부호, 조판 부호 and 투명 선.
    case showMarks(paragraph: Bool, control: Bool, borders: Bool)
    case styles
    /// 복사하기 with formats: the selection to the engine's clipboard, and as HTML.
    case copy(revision: UInt64, EditSelection)
    /// 복사하기 for a selected object.
    case copyObject(ObjectRef)
    case export(SaveFormat)

    private enum Key: String, CodingKey {
        case op, request, target, revision, page, x, y, position, selection, format, motion, goalX, query, caseSensitive, section,
             includeHeaderFooter, borders,
             object, cell, script, fontSize, color, paragraph, control, from, text, fromLatex, footnote, style, current, new, chart
    }
    private struct Apply: Encodable {
        var version = EditProtocolVersion.current
        var revision: UInt64
        var command: EditCommand
        var amend: Bool
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .apply(revision, command, amend, selection):
            try c.encode("apply", forKey: .op)
            try c.encode(Apply(revision: revision, command: command, amend: amend), forKey: .request)
            try c.encodeIfPresent(selection, forKey: .selection)
        case let .paragraph(target):
            try c.encode("paragraph", forKey: .op)
            try c.encode(target, forKey: .target)
        case let .hitTest(revision, page, x, y, includeHeaderFooter):
            try c.encode("hitTest", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(page, forKey: .page)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(includeHeaderFooter, forKey: .includeHeaderFooter)
        case let .caret(revision, position):
            try c.encode("caret", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(position, forKey: .position)
        case let .selectionRects(revision, selection):
            try c.encode("selectionRects", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(selection, forKey: .selection)
        case let .format(revision, position, from):
            try c.encode("format", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(position, forKey: .position)
            try c.encodeIfPresent(from, forKey: .from)
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
        case let .styleFormat(style):
            try c.encode("styleFormat", forKey: .op)
            try c.encode(style, forKey: .style)
        case let .pageBorder(section):
            try c.encode("pageBorder", forKey: .op)
            try c.encode(section, forKey: .section)
        case let .sectionSetup(section):
            try c.encode("sectionSetup", forKey: .op)
            try c.encode(section, forKey: .section)
        case let .noteShape(section, footnote):
            try c.encode("noteShape", forKey: .op)
            try c.encode(section, forKey: .section)
            try c.encode(footnote, forKey: .footnote)
        case let .pageHide(target):
            try c.encode("pageHide", forKey: .op)
            try c.encode(target, forKey: .target)
        case .bookmarks:
            try c.encode("bookmarks", forKey: .op)
        case .outline:
            try c.encode("outline", forKey: .op)
        case .fonts:
            try c.encode("fonts", forKey: .op)
        case let .clickHereAt(position):
            try c.encode("clickHereAt", forKey: .op)
            try c.encode(position, forKey: .position)
        case let .hyperlinkAt(position):
            try c.encode("hyperlinkAt", forKey: .op)
            try c.encode(position, forKey: .position)
        case .pictures:
            try c.encode("pictures", forKey: .op)
        case .statistics:
            try c.encode("statistics", forKey: .op)
        case .hasPassword:
            try c.encode("hasPassword", forKey: .op)
        case let .setPassword(current, new):
            try c.encode("setPassword", forKey: .op)
            try c.encodeIfPresent(current, forKey: .current)
            try c.encodeIfPresent(new, forKey: .new)
        case let .status(revision, position):
            try c.encode("status", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(position, forKey: .position)
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
        case let .chartData(chart):
            try c.encode("chartData", forKey: .op)
            try c.encode(chart, forKey: .chart)
        case let .formAt(revision, page, x, y):
            try c.encode("formAt", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(page, forKey: .page)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case let .objects(revision, page):
            try c.encode("objects", forKey: .op)
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
        case let .pictureFile(object):
            try c.encode("pictureFile", forKey: .op)
            try c.encode(object, forKey: .object)
        case let .cellProps(cell):
            try c.encode("cellProps", forKey: .op)
            try c.encode(cell, forKey: .cell)
        case let .cellBorder(cell):
            try c.encode("cellBorder", forKey: .op)
            try c.encode(cell, forKey: .cell)
        case let .equationPreview(script, fontSize, color):
            try c.encode("equationPreview", forKey: .op)
            try c.encode(script, forKey: .script)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(color, forKey: .color)
        case let .convertEquation(text, fromLatex):
            try c.encode("convertEquation", forKey: .op)
            try c.encode(text, forKey: .text)
            try c.encode(fromLatex, forKey: .fromLatex)
        case .styles:
            try c.encode("styles", forKey: .op)
        case let .copyObject(object):
            try c.encode("copyObject", forKey: .op)
            try c.encode(object, forKey: .object)
        case let .copy(revision, selection):
            try c.encode("copy", forKey: .op)
            try c.encode(revision, forKey: .revision)
            try c.encode(selection, forKey: .selection)
        case let .showMarks(paragraph, control, borders):
            try c.encode("showMarks", forKey: .op)
            try c.encode(paragraph, forKey: .paragraph)
            try c.encode(control, forKey: .control)
            try c.encode(borders, forKey: .borders)
        case let .export(format):
            try c.encode("export", forKey: .op)
            try c.encode(format, forKey: .format)
        }
    }
}
