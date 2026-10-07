use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 3;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CellTarget {
    pub control: u32,
    pub cell: u32,
    pub paragraph: u32,
}
/// A paragraph inside the 각주 or 미주 that is control `control` of the body paragraph.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NoteTarget {
    pub control: u32,
    pub paragraph: u32,
}
/// A paragraph inside one semantic header/footer definition, displayed on `page`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HeaderFooterTarget {
    pub footer: bool,
    pub apply_to: u8,
    pub page: u32,
}
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditTarget {
    pub section: u32,
    pub paragraph: u32,
    pub cell: Option<CellTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<NoteTarget>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "headerFooter"
    )]
    pub header_footer: Option<HeaderFooterTarget>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditPosition {
    pub target: EditTarget,
    pub scalar: u32,
    /// At the end of a wrapped line rather than the start of the next, the same scalar.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub upstream: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditSelection {
    pub anchor: EditPosition,
    pub focus: EditPosition,
}
impl EditSelection {
    pub fn caret(position: EditPosition) -> Self {
        Self {
            anchor: position.clone(),
            focus: position,
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum EditCommand {
    Replace {
        selection: EditSelection,
        text: String,
    },
    /// 모두 바꾸기: each of `selections` (matches, in document order) that can change, as one edit.
    ReplaceAll {
        selections: Vec<EditSelection>,
        text: String,
    },
    /// Replaces the selection with copy `copy` (see `Copied`) while the engine holds it,
    /// or with `html`, keeping their formats.
    Paste {
        selection: EditSelection,
        #[serde(default)]
        copy: Option<u64>,
        #[serde(default)]
        html: Option<String>,
    },
    Split {
        position: EditPosition,
    },
    MergePrevious {
        position: EditPosition,
    },
    /// 스타일 `style` (an index into the document's styles) for every paragraph the
    /// selection touches.
    ApplyStyle {
        selection: EditSelection,
        style: u32,
    },
    /// Character format over the selected text (one container, any number of paragraphs).
    FormatText {
        selection: EditSelection,
        style: CharStyle,
    },
    /// Paragraph format for every paragraph the selection touches.
    FormatParagraphs {
        selection: EditSelection,
        style: ParaStyle,
    },
    /// Starts a new page (or column) at `position` in the body, splitting its paragraph.
    Break {
        position: EditPosition,
        column: bool,
    },
    /// A new table at `position` in the body; the caret moves into its first cell.
    InsertTable {
        position: EditPosition,
        rows: u16,
        columns: u16,
    },
    /// An embedded PNG or JPEG, placed in body text at `position`.
    InsertPicture {
        position: EditPosition,
        /// Base64 is used only at the JSON boundary; decoded input is limited to 5 MiB.
        data: String,
        width: u32,
        height: u32,
        #[serde(rename = "naturalWidth")]
        natural_width: u32,
        #[serde(rename = "naturalHeight")]
        natural_height: u32,
        extension: String,
        description: String,
    },
    /// A Hancom equation script placed in body text at `position`.
    InsertEquation {
        position: EditPosition,
        script: String,
        #[serde(rename = "fontSize")]
        font_size: u32,
        color: u32,
    },
    /// A drawing object (`textbox`, `rectangle`, `ellipse`, `line` or `arc`) in front of
    /// the text, anchored at `position` in the body. `x` and `y` place it from the
    /// paper's corner, in HWPUNIT; a line runs from corner to corner, `flip` turning it.
    InsertShape {
        position: EditPosition,
        shape: String,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        #[serde(default)]
        flip: bool,
    },
    /// Changes the properties `props` sets of a picture, equation or table.
    SetObject {
        object: ObjectRef,
        props: ObjectProps,
    },
    /// Changes the properties `props` sets of the cell holding `cell`.
    SetCell {
        cell: EditTarget,
        props: CellProps,
    },
    /// Moves an equation to another place in the text of the body.
    MoveObject {
        object: ObjectRef,
        to: EditPosition,
    },
    /// Removes an object of the body.
    DeleteObject {
        object: ObjectRef,
    },
    /// Moves a border of a table: column `line`'s right border (or, with `row`, row
    /// `line`'s bottom border) so the column is `size` wide (or the row `size` high).
    /// An inner column border keeps the table's width; a row border grows the table.
    ResizeTable {
        table: ObjectRef,
        row: bool,
        line: u16,
        size: u32,
    },
    /// 순서: a drawing object of the body among the section's drawing objects.
    Order {
        object: ObjectRef,
        order: Order,
    },
    /// Moves the start (or, with `end`, the end) of a 직선 of the body by `dx`, `dy`
    /// (HWPUNIT), the other end staying.
    MoveLineEnd {
        object: ObjectRef,
        end: bool,
        dx: i32,
        dy: i32,
    },
    /// 개체 풀기: a group of drawing objects of the body into its members.
    Ungroup {
        object: ObjectRef,
    },
    /// 도형 안에 글자 넣기 (or, without `attach`, 글상자 속성 없애기) for a drawing object of
    /// the body. Put in, the caret moves into the new text.
    SetTextBox {
        object: ObjectRef,
        attach: bool,
    },
    /// A 각주 (or 미주) at `position` in the body; the caret moves into its text.
    InsertNote {
        position: EditPosition,
        endnote: bool,
    },
    /// Adds or removes a row or column of the table holding `cell`.
    EditTable {
        cell: EditTarget,
        change: TableChange,
    },
    /// 셀 합치기: one cell from the block `selection` covers.
    MergeCells {
        selection: EditSelection,
    },
    /// 셀 나누기: each cell `selection` covers into `rows` × `columns`, or, with
    /// `merge_first`, the block merged into one cell first.
    SplitCells {
        selection: EditSelection,
        rows: u16,
        columns: u16,
        #[serde(rename = "equalHeight")]
        equal_height: bool,
        #[serde(rename = "mergeFirst")]
        merge_first: bool,
    },
    /// 셀 높이를 같게 (or 셀 너비를 같게) over the block `selection` covers.
    EqualizeCells {
        selection: EditSelection,
        height: bool,
    },
    /// 블록 합계, 블록 평균 or 블록 곱 over the block `selection` covers.
    CalculateBlock {
        selection: EditSelection,
        function: BlockFunction,
    },
    /// Paper and margins of one section.
    SetPage {
        section: u32,
        page: PageSetup,
    },
    /// 머리말/꼬리말 지우기: the definition `target` (a 머리말 or 꼬리말 paragraph) is in.
    DeleteHeaderFooter {
        target: EditTarget,
    },
    /// 단 하나, 둘 or 셋: `count` columns of the same width for a section with one column
    /// definition.
    SetColumns {
        section: u32,
        count: u16,
    },
    /// Replaces the header (or footer) shown on every page of a section with an empty
    /// one, or one holding the page number at `page_number`.
    HeaderFooter {
        section: u32,
        footer: bool,
        #[serde(rename = "pageNumber")]
        page_number: Option<Placement>,
    },
    Undo,
    Redo,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Placement {
    Left,
    Center,
    Right,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BlockFunction {
    Sum,
    Average,
    Product,
}
/// 맨 앞으로, 앞으로, 맨 뒤로, 뒤로.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Order {
    Front,
    Forward,
    Back,
    Backward,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ObjectKind {
    Picture,
    Equation,
    Table,
    /// A drawing object: 가로 글상자, 직사각형, 타원, 직선 or 호.
    Shape,
}
/// Control `control` of a body paragraph, or of the paragraph `cell` names in a table cell
/// of body paragraph `paragraph`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ObjectRef {
    pub kind: ObjectKind,
    pub section: u32,
    pub paragraph: u32,
    pub control: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cell: Option<CellTarget>,
    /// The 미주 paragraph holding the object: only an equation, for its properties (rhwp
    /// lays out where only those of 미주 are).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<NoteTarget>,
}
/// A stretch of a table border on a page that can be dragged: the right border of
/// column `line` (or the bottom of row `line`) at `at`, running `from`–`to` the other
/// way, the column (row) starting at `start`. Page pixels.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TableLine {
    pub table: ObjectRef,
    pub row: bool,
    pub line: u16,
    pub at: f64,
    pub start: f64,
    pub from: f64,
    pub to: f64,
}
/// An object as laid out on a page.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PlacedObject {
    pub object: ObjectRef,
    pub rect: PageRect,
    /// A group of drawing objects, for 개체 풀기.
    pub group: bool,
    /// A drawing object that can hold text, and whether it does (도형 안에 글자 넣기,
    /// 글상자 속성 없애기).
    #[serde(rename = "textBox")]
    pub text_box: Option<bool>,
    /// A 직선's start and end on the page (x, y, x, y in page pixels), for dragging them.
    pub ends: Option<[f64; 4]>,
}
/// Object properties in rhwp's names and units (lengths in HWPUNIT). As a query result
/// the fields the object has are set; as a change, unset fields stay.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObjectProps {
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub size_protect: Option<bool>,
    pub treat_as_char: Option<bool>,
    /// Square (어울림), TopAndBottom (자리 차지), BehindText, InFrontOfText.
    pub text_wrap: Option<String>,
    /// Paper, Page, Column, Para.
    pub horz_rel_to: Option<String>,
    /// Left, Center, Right.
    pub horz_align: Option<String>,
    pub horz_offset: Option<i32>,
    /// Paper, Page, Para.
    pub vert_rel_to: Option<String>,
    /// Top, Center, Bottom.
    pub vert_align: Option<String>,
    pub vert_offset: Option<i32>,
    pub restrict_in_page: Option<bool>,
    pub allow_overlap: Option<bool>,
    /// Pictures and tables: None, Top, Bottom, or Left/Right with Top, Center or Bottom
    /// (LeftTop … RightBottom), the positions of 캡션 넣기.
    pub caption: Option<String>,
    /// 캡션 크기 (of a caption beside the object) and 개체와의 간격.
    pub caption_width: Option<u32>,
    pub caption_spacing: Option<i32>,
    /// 여백 부분까지 너비 확대 (pictures and drawing objects).
    pub caption_include_margin: Option<bool>,
    pub outer_margin_left: Option<i32>,
    pub outer_margin_right: Option<i32>,
    pub outer_margin_top: Option<i32>,
    pub outer_margin_bottom: Option<i32>,
    /// Pictures: 그림 여백. Tables: the inner margin of every cell.
    pub padding_left: Option<i32>,
    pub padding_right: Option<i32>,
    pub padding_top: Option<i32>,
    pub padding_bottom: Option<i32>,
    pub crop_left: Option<i32>,
    pub crop_right: Option<i32>,
    pub crop_top: Option<i32>,
    pub crop_bottom: Option<i32>,
    pub original_width: Option<u32>,
    pub original_height: Option<u32>,
    /// −100–100.
    pub brightness: Option<i32>,
    pub contrast: Option<i32>,
    /// RealPic, GrayScale, BlackWhite.
    pub effect: Option<String>,
    pub rotation_angle: Option<i32>,
    pub horz_flip: Option<bool>,
    pub vert_flip: Option<bool>,
    /// Tables: 0 나누지 않음, 1 나눔, 2 셀 단위로 나눔.
    pub page_break: Option<u8>,
    pub repeat_header: Option<bool>,
    pub cell_spacing: Option<i32>,
    pub script: Option<String>,
    /// HWPUNIT (100 per point).
    pub font_size: Option<u32>,
    /// 0x00bbggrr.
    pub color: Option<u32>,
    pub baseline: Option<i32>,
}
/// Cell properties in rhwp's names (lengths in HWPUNIT); unset fields stay.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CellProps {
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub apply_inner_margin: Option<bool>,
    pub padding_left: Option<i32>,
    pub padding_right: Option<i32>,
    pub padding_top: Option<i32>,
    pub padding_bottom: Option<i32>,
    /// 0 top, 1 center, 2 bottom.
    pub vertical_align: Option<u8>,
    pub is_header: Option<bool>,
    pub cell_protect: Option<bool>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TableChange {
    InsertRowAbove,
    InsertRowBelow,
    InsertColumnLeft,
    InsertColumnRight,
    DeleteRow,
    DeleteColumn,
}
/// A section's paper in HWPUNIT (1/7200 inch). `width` and `height` describe the paper
/// upright; `landscape` turns it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageSetup {
    pub width: u32,
    pub height: u32,
    pub margin_left: u32,
    pub margin_right: u32,
    pub margin_top: u32,
    pub margin_bottom: u32,
    pub margin_header: u32,
    pub margin_footer: u32,
    pub margin_gutter: u32,
    pub landscape: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditRequest {
    pub version: u32,
    pub revision: u64,
    pub command: EditCommand,
    /// Folds this edit into the latest undo step instead of adding one (IME composition).
    #[serde(default)]
    pub amend: bool,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditReply {
    pub version: u32,
    pub revision: u64,
    pub selection: Option<EditSelection>,
    /// Caret rectangle of the selection focus, laid out with this revision.
    pub caret: Option<PageRect>,
    pub page_count: u32,
    /// Pages re-rendered by this revision; the accompanying PDF holds exactly these, in order.
    pub changed_pages: Vec<u32>,
    /// Body area (inside the margins, 머리말 and 꼬리말) of each changed page, in order.
    pub bodies: Vec<PageRect>,
    pub can_undo: bool,
    pub can_redo: bool,
    pub dirty: bool,
    pub locked: bool,
}
/// Character format: as a query result every field is set, except those that differ across
/// a selection's characters; as a change, unset fields stay.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CharStyle {
    /// As a change, the 언어 (0 한글, 1 영문, 2 한자, 3 일어, 4 외국어, 5 기호, 6 사용자)
    /// whose font, 상대 크기, 장평, 글자 위치 and 자간 change; unset, all of them (대표).
    pub language: Option<u8>,
    pub font: Option<String>,
    /// Points.
    pub size: Option<f64>,
    pub bold: Option<bool>,
    pub italic: Option<bool>,
    pub underline: Option<bool>,
    pub strikethrough: Option<bool>,
    /// `#rrggbb`.
    pub color: Option<String>,
    /// Line shape of the underline and strikethrough (0 solid, 1 long dash, 2 dot, …).
    pub underline_shape: Option<u8>,
    pub strike_shape: Option<u8>,
    /// `#rrggbb` of the underline and strikethrough lines.
    pub underline_color: Option<String>,
    pub strike_color: Option<String>,
    /// Shade behind the text, `#rrggbb`; white is none (also serves 형광펜).
    pub shade: Option<String>,
    /// Width in percent (장평), 50–200.
    pub ratio: Option<f64>,
    /// Letter spacing in percent of the size (자간), −50–50.
    pub spacing: Option<f64>,
    pub superscript: Option<bool>,
    pub subscript: Option<bool>,
    pub outline: Option<bool>,
    pub shadow: Option<bool>,
    pub emboss: Option<bool>,
    pub engrave: Option<bool>,
    /// The underline above the text instead of below (밑줄 위치 위).
    pub underline_top: Option<bool>,
    /// 상대 크기 in percent, 10–250.
    pub relative_size: Option<f64>,
    /// 글자 위치 in percent of the size, −100–100.
    pub offset: Option<f64>,
    /// 테두리: line kind (0 none, 1 solid, 2 dash, 3 dot, …), width (an index into
    /// 0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1, 1.5, 2, 3, 4, 5 mm) and
    /// `#rrggbb`. 배경: 면 색 (`#rrggbb`, or `none`), 무늬 색 and 무늬 모양 (0 none, 1–6).
    /// As a change, set all six together.
    pub border_line: Option<u8>,
    pub border_width: Option<u8>,
    pub border_color: Option<String>,
    pub fill_color: Option<String>,
    pub pattern_color: Option<String>,
    pub pattern: Option<u8>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Alignment {
    Justify,
    Left,
    Center,
    Right,
    Distribute,
    Split,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LineSpacingKind {
    /// Percent of the font height.
    Percent,
    /// Exact line height in points.
    Fixed,
    /// Points between lines.
    SpaceOnly,
    /// At least this height in points.
    Minimum,
}
/// Paragraph format; lengths are points. As a query result every field is set.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ParaStyle {
    pub alignment: Option<Alignment>,
    /// Percent for `Percent`, otherwise points; set together with `line_spacing_kind`.
    pub line_spacing: Option<f64>,
    pub line_spacing_kind: Option<LineSpacingKind>,
    pub margin_left: Option<f64>,
    pub margin_right: Option<f64>,
    /// First-line indent; negative hangs (내어쓰기).
    pub indent: Option<f64>,
    pub spacing_before: Option<f64>,
    pub spacing_after: Option<f64>,
    pub keep_with_next: Option<bool>,
    pub keep_lines: Option<bool>,
    pub widow_orphan: Option<bool>,
    pub page_break_before: Option<bool>,
    /// The paragraph head: None, Number (문단 번호), Bullet (글머리표) or Outline. As a
    /// change, Number takes `numbering` and Bullet takes `bullet`.
    pub head: Option<String>,
    /// A 문단 번호 kind, an index into `format::NUMBERINGS`.
    pub numbering: Option<u8>,
    /// The 글머리표 character.
    pub bullet: Option<String>,
    /// The list level, 0–6 (한 수준 증가/감소).
    pub level: Option<u8>,
    /// 줄 나눔 기준 for Korean: 0 어절, 1 글자.
    pub korean_break_unit: Option<u8>,
    /// 줄 나눔 기준 for Latin: 0 단어, 1 하이픈, 2 글자.
    pub english_break_unit: Option<u8>,
    /// 테두리: line kind (0 none, 1 solid, 2 dash, 3 dot, …), width (an index into
    /// 0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1, 1.5, 2, 3, 4, 5 mm) and
    /// `#rrggbb`. 배경: 면 색 (`#rrggbb`, or `none`), 무늬 색 and 무늬 모양 (0 none, 1–6).
    /// As a change, set all six together.
    pub border_line: Option<u8>,
    pub border_width: Option<u8>,
    pub border_color: Option<String>,
    pub fill_color: Option<String>,
    pub pattern_color: Option<String>,
    pub pattern: Option<u8>,
    /// 문단 테두리 연결: one border around consecutive paragraphs with the same one.
    pub border_connect: Option<bool>,
    /// 시작 번호 방식 of the first paragraph, in the body: 0 앞 번호 목록에 이어, 1 이전
    /// 번호 목록에 이어, 2 새 번호 목록 시작 at `start_number` (1수준 시작 번호).
    pub restart: Option<u8>,
    pub start_number: Option<u32>,
}
/// A caret motion, resolved against the engine's line layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Motion {
    Left,
    Right,
    /// To the start of the previous word.
    WordLeft,
    /// To the end of the next word.
    WordRight,
    /// Edges of the word segment under the caret (double-click).
    WordStart,
    WordEnd,
    LineStart,
    LineEnd,
    Up,
    Down,
    ParagraphStart,
    ParagraphEnd,
    /// Edges of the body or of the cell holding the caret.
    DocumentStart,
    DocumentEnd,
    /// From a 머리말 (or 꼬리말) to the start of the one on the next (or previous) page
    /// that has one.
    NextHeaderFooter,
    PreviousHeaderFooter,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Navigation {
    pub position: EditPosition,
    pub caret: PageRect,
    /// Column to keep for the next vertical motion.
    pub goal_x: f64,
}
/// Format at a caret, with the font names the renderer tries in order.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Format {
    pub text: CharStyle,
    /// The font, 상대 크기, 장평, 글자 위치 and 자간 of each 언어, in `language` order.
    pub languages: Vec<CharStyle>,
    pub paragraph: ParaStyle,
    /// The paragraph's 스타일.
    pub style: u32,
    /// The caret is in a 글상자 (addressed like a table cell).
    pub text_box: bool,
    pub fonts: Vec<String>,
}
#[derive(Debug, Clone, Serialize)]
pub struct ParagraphInfo {
    pub target: EditTarget,
    /// Paragraphs in the same container (body or cell).
    pub count: u32,
    pub text: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum EditError {
    InvalidInput,
    IncompatibleEngine,
    PasswordRequired,
    UnsupportedFormat,
    StaleRevision,
    UnsupportedTarget,
    InvalidBoundary,
    ResourceLimit,
    RenderFailed,
    PreservationFailed,
    SaveFailed,
    Locked,
}
impl From<rhwp::error::HwpError> for EditError {
    fn from(_: rhwp::error::HwpError) -> Self {
        Self::InvalidInput
    }
}
/// Page-space rectangle in 96 dpi units with a top-left origin.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PageRect {
    pub page: u32,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SaveFormat {
    Hwp,
    Hwpx,
    /// The whole document as rendered, for printing and sharing.
    Pdf,
}
