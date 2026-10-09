use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 4;

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
    /// 스타일 추가하기: a style at the end of the list, from the shapes at `position`
    /// with `text` (one change per 언어 set apart) and `paragraph` laid over them.
    AddStyle {
        position: EditPosition,
        style: StyleSpec,
    },
    /// 스타일 편집하기: its names and next style, and `text` and `paragraph` laid over its
    /// shapes; the paragraphs with the style follow, except where set apart by hand.
    EditStyle {
        style: u32,
        spec: StyleSpec,
    },
    /// 스타일 지우기: the paragraphs with it take `replacement`.
    DeleteStyle {
        style: u32,
        replacement: u32,
    },
    /// 문서 정보's 사용된 글꼴 바꾸기 and 대체된 글꼴 바꾸기: every 글자 모양 with `from` in
    /// `language` (an index into 한글, 영문, 한자, 일어, 외국어, 기호, 사용자; none for every
    /// 언어) takes `to`.
    ReplaceFont {
        language: Option<u8>,
        from: String,
        to: String,
    },
    /// 한 줄 위로 이동하기 (`up`) or 한 줄 아래로 이동하기.
    MoveStyle {
        style: u32,
        up: bool,
    },
    /// 커서 위치의 스타일로 바꾸기: the style takes the shapes at `position`.
    RestyleFromCaret {
        style: u32,
        position: EditPosition,
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
    /// A new table at `position` in the body; the caret moves into its first cell. With
    /// `width` (or `height`), in HWPUNIT, its columns (rows) share it evenly (표 만들기 크기
    /// 지정); `treat_as_char`, 글자처럼 취급.
    InsertTable {
        position: EditPosition,
        rows: u16,
        columns: u16,
        #[serde(default)]
        width: Option<u32>,
        #[serde(default)]
        height: Option<u32>,
        #[serde(default, rename = "treatAsChar")]
        treat_as_char: bool,
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
    /// 셀 테두리/배경 of the cells `selection` covers, or (`all`) of every cell of its
    /// table: 각 셀마다 적용, or (`one`) 하나의 셀처럼 적용.
    SetCellBorder {
        selection: EditSelection,
        all: bool,
        one: bool,
        border: CellBorder,
    },
    /// Changes the properties `props` sets of the cell holding `cell`.
    SetCell {
        cell: EditTarget,
        props: CellProps,
    },
    /// 그림 정보's 경로 바꾸기 and 그림 확장자 바꾸기: the file a 연결 picture shows.
    SetPictureLink {
        object: ObjectRef,
        path: String,
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
    /// 그림 바꾸기: another image in the picture, which keeps its size and place.
    ReplacePicture {
        object: ObjectRef,
        /// Base64, as `InsertPicture`'s.
        data: String,
        #[serde(rename = "naturalWidth")]
        natural_width: u32,
        #[serde(rename = "naturalHeight")]
        natural_height: u32,
        extension: String,
    },
    /// 개체 풀기: a group of drawing objects of the body into its members.
    Ungroup {
        object: ObjectRef,
    },
    /// 개체 묶기: drawing objects and pictures of the body into one group.
    Group {
        objects: Vec<ObjectRef>,
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
    /// 차트 데이터 편집: chart `chart` (its number in the document) takes `data`, its 줄 and
    /// 칸 added or removed at the ends.
    SetChartData {
        chart: u32,
        data: ChartData,
    },
    /// A 양식 개체's value (선택 상자, 라디오 단추: 0 or 1) or text (입력 상자, 콤보 상자).
    SetForm {
        form: FormRef,
        #[serde(default)]
        value: Option<i32>,
        #[serde(default)]
        text: Option<String>,
    },
    /// 고치기 of the 누름틀 at `position`: its 안내문, 메모 내용, 필드 이름 and 양식 모드에서 편집
    /// 가능.
    EditClickHere {
        position: EditPosition,
        guide: String,
        memo: String,
        name: String,
        #[serde(default, rename = "formEditable")]
        form_editable: bool,
    },
    /// 필드 입력 › 누름틀: an empty field at `position` showing `guide` (입력할 내용의
    /// 안내문), with its 메모 내용 and 필드 이름; what is typed there goes in it.
    InsertClickHere {
        position: EditPosition,
        guide: String,
        memo: String,
        name: String,
        /// 양식 모드에서 편집 가능.
        #[serde(default, rename = "formEditable")]
        form_editable: bool,
    },
    /// 머리말/꼬리말 탭 › 코드 넣기: a page number code at `position` in a 머리말 or 꼬리말.
    InsertPageCode {
        position: EditPosition,
        code: PageCode,
    },
    /// 문서 끼워 넣기: the body of the HWP or HWPX file `data` (base64) at `position` in the
    /// body; with `bookmark` (파일 이름으로 책갈피 넣기) a 책갈피 of that name marks where it
    /// starts.
    InsertDocument {
        position: EditPosition,
        data: String,
        #[serde(default)]
        bookmark: Option<String>,
    },
    /// 입력 › 하이퍼링크: links the text `selection` holds to the web address `uri`, the
    /// text becoming `text` (표시할 문자열); with no selection `text` goes in at the caret.
    InsertHyperlink {
        selection: EditSelection,
        text: String,
        uri: String,
    },
    /// 하이퍼링크 고치기 of the link holding the caret at `position`.
    EditHyperlink {
        position: EditPosition,
        text: String,
        uri: String,
    },
    /// 하이퍼링크 지우기: the link holding `position` goes; its text takes back its look.
    RemoveHyperlink {
        position: EditPosition,
    },
    /// Adds or removes a row or column of the table holding `cell`.
    EditTable {
        cell: EditTarget,
        change: TableChange,
    },
    /// 표 뒤집기 of the table holding `cell`; with `margins` the cells' 안 여백 turn too.
    FlipTable {
        cell: EditTarget,
        turn: TableTurn,
        margins: bool,
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
    /// Paper and margins of one section, or with `whole` of every section (적용 범위
    /// 문서 전체).
    SetPage {
        section: u32,
        page: PageSetup,
        #[serde(default)]
        whole: bool,
    },
    /// 쪽 테두리/배경 of one section, or with `whole` of every section.
    SetPageBorder {
        section: u32,
        border: PageBorder,
        #[serde(default)]
        whole: bool,
    },
    /// 각주 모양 (`footnote`) or 미주 모양 of one section, or with `whole` of every section.
    SetNoteShape {
        section: u32,
        footnote: bool,
        shape: NoteShape,
        #[serde(default)]
        whole: bool,
    },
    /// 구역 설정 of one section, or with `whole` of every section.
    SetSection {
        section: u32,
        setup: SectionSetup,
        #[serde(default)]
        whole: bool,
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
    /// 새 번호로 시작: numbers of `numbering` from `number` on, from `position` (a body
    /// paragraph). Where the paragraph already starts that kind anew, its number changes.
    NewNumber {
        position: EditPosition,
        numbering: NumberKind,
        number: u16,
    },
    /// 현재 쪽만 감추기, set at the start of the body paragraph `target`; nothing hidden
    /// takes it out.
    SetPageHide {
        target: EditTarget,
        hide: PageHide,
    },
    /// 책갈피 넣기 at `position` in the body.
    AddBookmark {
        position: EditPosition,
        name: String,
    },
    /// 책갈피 이름 바꾸기 (or, without `name`, 지우기) for control `control` of the body
    /// paragraph `target`.
    ChangeBookmark {
        target: EditTarget,
        control: u32,
        name: Option<String>,
    },
    /// 조판 부호 지우기: every code of `kinds` in the body, or in `selection`.
    EraseCodes {
        selection: Option<EditSelection>,
        kinds: Vec<CodeKind>,
    },
    Undo,
    Redo,
}
/// 번호 종류 of 새 번호로 시작.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NumberKind {
    Page,
    Picture,
    Table,
    Equation,
    Footnote,
    Endnote,
}
/// 감출 내용 of 현재 쪽만 감추기.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PageHide {
    pub header: bool,
    pub footer: bool,
    pub page_number: bool,
    /// 쪽 테두리/배경.
    pub border_fill: bool,
    /// 바탕쪽.
    pub master_page: bool,
}
/// The codes 조판 부호 지우기 can take out, as its 개체 선택 names them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CodeKind {
    /// 각주.
    Footnote,
    /// 미주.
    Endnote,
    /// 감추기.
    PageHide,
    /// 그리기: a drawing object without text.
    Drawing,
    /// 글상자: a drawing object with text.
    TextBox,
    /// 그림.
    Picture,
    /// 표.
    Table,
    /// 수식.
    Equation,
    /// 머리말.
    Header,
    /// 꼬리말.
    Footer,
    /// 쪽 번호 위치.
    PageNumberPosition,
    /// 새 쪽 번호, 새 그림 번호, 새 표 번호, 새 수식 번호, 새 각주 번호, 새 미주 번호.
    NewNumber(NumberKind),
}
/// A 책갈피 of the body.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Bookmark {
    pub name: String,
    pub position: EditPosition,
    pub control: u32,
}
/// A font 글꼴 정보 lists, and whether this Mac has it; one it lacks is 대체된.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct UsedFont {
    pub name: String,
    pub installed: bool,
}
/// A picture of 그림 정보: 이름, whether 연결 (or 삽입), 쪽 (from 1) and a 연결 one's 경로.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PictureInfo {
    pub name: String,
    pub linked: bool,
    pub page: u32,
    pub path: String,
    pub object: ObjectRef,
}
/// A 양식 개체: control `control` of the paragraph (in a table's cell when `cell`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FormRef {
    pub section: u32,
    pub paragraph: u32,
    pub control: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cell: Option<CellTarget>,
}
/// A 양식 개체 under the pointer: its kind (PushButton, CheckBox, ComboBox, RadioButton,
/// Edit), name, caption, value, text, whether enabled, a 콤보 상자's items, and where it is.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FormInfo {
    pub form: FormRef,
    pub kind: String,
    pub name: String,
    pub caption: String,
    pub value: i32,
    pub text: String,
    pub enabled: bool,
    pub items: Vec<String>,
    pub rect: PageRect,
}
/// A 누름틀 as 필드 입력 shows it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClickHere {
    pub guide: String,
    pub memo: String,
    pub name: String,
    pub form_editable: bool,
}
/// The page number codes of 머리말/꼬리말 › 코드 넣기.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PageCode {
    /// 현재 쪽 번호.
    Page,
    /// 전체 쪽수.
    Total,
    /// 현재 쪽/전체 쪽수.
    PageOfTotal,
}
/// A 하이퍼링크 as its dialog shows it: 표시할 문자열 and the web address.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Hyperlink {
    pub text: String,
    pub uri: String,
}
/// A 개요 문단 of 개요 보기: its 수준 (1–7), its number as drawn, and its text.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct OutlineItem {
    pub level: u8,
    pub number: String,
    pub title: String,
    pub position: EditPosition,
}
/// 문서 정보 › 문서 통계: the document's 분량, table cells counted as paragraphs.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Statistics {
    /// 글자(공백 포함), 글자(공백 제외), 글자에 포함된 한자 수.
    pub characters: u32,
    pub characters_without_spaces: u32,
    pub hanja: u32,
    /// 낱말, 줄, 문단, 쪽.
    pub words: u32,
    pub lines: u32,
    pub paragraphs: u32,
    pub pages: u32,
    /// 원고지(200자 기준).
    pub manuscript: u32,
    /// 표, 그림, 글상자.
    pub tables: u32,
    pub pictures: u32,
    pub text_boxes: u32,
}
/// 상황 선: where the caret is, 1-based as 한글 shows it.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaretStatus {
    pub page: u32,
    /// 단 of the body, 1 elsewhere.
    pub column: u32,
    /// 줄 on the page's column for the body; in a cell, note or 머리말/꼬리말, in its text.
    pub line: u32,
    /// 칸: the position in the line, objects in the line counted.
    pub character: u32,
    pub section: u32,
    pub sections: u32,
    /// The cell's address, as A1.
    pub cell: Option<String>,
    /// 글자 수 of the document (공백 포함).
    pub characters: u32,
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
    /// A 차트: its number in the document, for 차트 데이터 편집.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chart: Option<u32>,
}
/// 차트 데이터: the 줄 names (labels), and each 칸 (series) with its name and values.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChartData {
    pub labels: Vec<String>,
    pub series: Vec<ChartSeries>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChartSeries {
    pub name: String,
    pub values: Vec<String>,
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
    /// Tables: 표 테두리/배경, its four sides and 배경.
    pub table_border: Option<CellBorder>,
    /// Drawing objects' 그림자: 종류 (0 none, 1 왼쪽 위, 2 오른쪽 위, 3 왼쪽 아래, 4 오른쪽
    /// 아래, 5 왼쪽 뒤, 6 오른쪽 뒤, 7 왼쪽 앞, 8 오른쪽 앞, 9 작게, 10 크게), color
    /// (0x00bbggrr), offsets (HWPUNIT, y down) and 투명도 (0 opaque – 255).
    pub shadow_type: Option<u32>,
    pub shadow_color: Option<u32>,
    pub shadow_offset_x: Option<i32>,
    pub shadow_offset_y: Option<i32>,
    pub shadow_alpha: Option<u32>,
    /// 글상자: 안쪽 여백 (HWPUNIT) and 세로 정렬 (Top, Center, Bottom).
    pub tb_margin_left: Option<i32>,
    pub tb_margin_right: Option<i32>,
    pub tb_margin_top: Option<i32>,
    pub tb_margin_bottom: Option<i32>,
    pub tb_vertical_align: Option<String>,
    /// Rectangles: 사각형 모서리 곡률, 0–50 %.
    pub round_rate: Option<u32>,
    pub script: Option<String>,
    /// HWPUNIT (100 per point).
    pub font_size: Option<u32>,
    /// 0x00bbggrr.
    pub color: Option<u32>,
    pub baseline: Option<i32>,
    /// Drawing objects' 선: color (0x00bbggrr), width (HWPUNIT), 종류 (0 none, 1 solid …
    /// 11), 끝 모양 (0 round, 1 flat), and 화살표 shapes (0–6) and sizes (0–8).
    pub border_color: Option<u32>,
    pub border_width: Option<i32>,
    pub line_type: Option<u32>,
    pub line_end_shape: Option<u32>,
    pub arrow_start: Option<u32>,
    pub arrow_end: Option<u32>,
    pub arrow_start_size: Option<u32>,
    pub arrow_end_size: Option<u32>,
    /// Drawing objects' 채우기: none or solid, 면 색 and 무늬 색 (0x00bbggrr), 무늬 모양
    /// (0 or −1 none, 1–6), and 투명도 (0 opaque – 255).
    pub fill_type: Option<String>,
    pub fill_bg_color: Option<u32>,
    pub fill_pat_color: Option<u32>,
    pub fill_pat_type: Option<i32>,
    pub fill_alpha: Option<u32>,
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
    /// 표 나누기: the caret's row starts a new table.
    Split,
    /// 표 붙이기: the next table, with only empty paragraphs between, joins this one.
    Attach,
}
/// 표 뒤집기: 줄 기준 뒤집기, 칸 기준 뒤집기, 줄/칸 뒤집기, and turns of 반시계 방향 90도,
/// 180도 and 시계 방향 90도.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TableTurn {
    Rows,
    Columns,
    Diagonal,
    Left,
    Half,
    Right,
}
impl TableTurn {
    /// Where the cell at `row`, `col` spanning `spans` goes in a `size` table, as the
    /// mirrors `Table::flip` makes.
    pub fn place(self, (row, col): (u16, u16), spans: (u16, u16), size: (u16, u16)) -> (u16, u16) {
        let mirrors: &[u8] = match self {
            Self::Rows => &[0],
            Self::Columns => &[1],
            Self::Diagonal => &[2],
            Self::Left => &[2, 0],
            Self::Half => &[0, 1],
            Self::Right => &[2, 1],
        };
        let (mut at, mut spans, mut size) = ((row, col), spans, size);
        for m in mirrors {
            match m {
                0 => at.0 = size.0 - at.0 - spans.0.max(1),
                1 => at.1 = size.1 - at.1 - spans.1.max(1),
                _ => (at, spans, size) = ((at.1, at.0), (spans.1, spans.0), (size.1, size.0)),
            }
        }
        at
    }
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
    /// 제본: 0 한쪽, 1 맞쪽, 2 위로.
    pub binding: u8,
}
/// A section's 쪽 테두리/배경. `sides` and `spacing` run 왼쪽, 오른쪽, 위쪽, 아래쪽;
/// spacings are in HWPUNIT.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageBorder {
    pub sides: [BorderSide; 4],
    /// 위치: 종이 기준, else 쪽 기준.
    pub paper: bool,
    pub spacing: [u32; 4],
    /// 머리말 포함 and 꼬리말 포함.
    pub header_inside: bool,
    pub footer_inside: bool,
    /// 적용 쪽 of the border and of the background.
    pub border_pages: ApplyPages,
    pub fill_pages: ApplyPages,
    /// 배경 by color; unset when it is a 그러데이션 or 그림, which then stays.
    pub fill: Option<PageFill>,
    pub fill_area: FillArea,
}
/// 구역 설정: 시작 쪽 번호 (`page_num`, 0 continuing; `page_num_type` 0 이어서, 1 홀수,
/// 2 짝수), 개체 시작 번호 (0 continuing), the 첫 쪽에만 감추기 flags, 빈 줄 감추기, and
/// 단 사이 간격 and 기본 탭 간격 in HWPUNIT.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SectionSetup {
    pub page_num: u16,
    pub page_num_type: u8,
    pub picture_num: u16,
    pub table_num: u16,
    pub equation_num: u16,
    pub column_spacing: i32,
    pub default_tab_spacing: u32,
    pub hide_header: bool,
    pub hide_footer: bool,
    pub hide_master_page: bool,
    pub hide_border: bool,
    pub hide_fill: bool,
    pub hide_empty_line: bool,
}
/// 각주 모양 or 미주 모양, in rhwp's names: 번호 모양 (`digit`, `circledDigit`, …,
/// `fourSymbol`, `userChar`), 기호 모양 and 앞/뒤 장식 문자 (one character or empty), 구분선
/// (길이 in HWPUNIT, or −1 5 cm, −2 2 cm, −3 a third and −4 all of the column; 종류, 굵기,
/// `#rrggbb`), 여백 in HWPUNIT, and 번호 매기기 (`continue`, `restartSection`, `restartPage`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteShape {
    pub number_format: String,
    pub user_char: String,
    pub prefix_char: String,
    pub suffix_char: String,
    pub separator_enabled: bool,
    pub separator_length: i32,
    pub separator_line_type: u8,
    pub separator_line_width: u8,
    pub separator_color: String,
    pub separator_margin_top: i32,
    pub separator_margin_bottom: i32,
    pub note_spacing: i32,
    pub numbering: String,
}
/// A border line: kind (0 none, 1 solid, 2 dash, …), width (an index as in
/// `CharStyle::border_width`) and `#rrggbb`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BorderSide {
    pub line: u8,
    pub width: u8,
    pub color: String,
}
/// 셀 테두리/배경: 왼쪽, 오른쪽, 위쪽 and 아래쪽 of the cells (of the block, for 각 셀마다
/// 적용), then the 가로 and 세로 lines inside it; 배경 by color (unset when it is a
/// 그러데이션 or 그림, which then stays); and 대각선. What is unset stays.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CellBorder {
    pub sides: [Option<BorderSide>; 6],
    pub fill: Option<PageFill>,
    pub diagonal: Option<Diagonal>,
}
/// 대각선: its line, ＼ (`back_slash`) and ／ (`slash`), and 중심선 (0 none, 1 가로, 2 세로,
/// 3 both); a 중심선 takes the place of the diagonals.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Diagonal {
    pub line: BorderSide,
    pub slash: bool,
    pub back_slash: bool,
    pub center: u8,
}
/// 면 색 (`#rrggbb`, or `none` for 색 채우기 없음), 무늬 색 and 무늬 모양 (0 none, 1–6).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageFill {
    pub color: String,
    pub pattern_color: String,
    pub pattern: u8,
    /// 셀·표 배경 only: a 그러데이션 or 그림 in place of the color.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gradient: Option<Gradient>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<ImageBrush>,
}
/// 그러데이션: 모양 (1 줄무늬, 2 원형, 3 원뿔형, 4 사각형), 시작 색 and 끝 색, 기울임 (degrees),
/// 가로/세로 중심 (%), 번짐 정도 (steps) and 번짐 중심 (%).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Gradient {
    pub kind: u8,
    pub colors: Vec<String>,
    pub angle: i16,
    pub center_x: i16,
    pub center_y: i16,
    pub blur: u8,
    pub step_center: u8,
}
/// 그림 배경: a new image (`data`, base64, with its `extension`) or the one the document
/// has (`bin_id`); 채우기 유형 (rhwp's `IMAGE_FILL_MODES` order), 그림 효과 (0 원래 그림, 1
/// 회색조, 2 흑백), 밝기 and 대비 (−100–100).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageBrush {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extension: Option<String>,
    pub bin_id: u16,
    pub mode: u8,
    pub effect: u8,
    pub brightness: i8,
    pub contrast: i8,
}
/// 적용 쪽: 모두, 첫 쪽 제외, 첫 쪽만.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ApplyPages {
    All,
    ExceptFirst,
    FirstOnly,
}
/// 채울 영역: 종이, 쪽, 테두리.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FillArea {
    Paper,
    Page,
    Border,
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
/// A style's names, kind and next style, and the changes to lay over its shapes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StyleSpec {
    pub name: String,
    pub english_name: String,
    /// 스타일 종류: 문단, else 글자.
    pub paragraph_style: bool,
    /// 다음 문단에 적용할 스타일.
    pub next: u32,
    #[serde(default)]
    pub text: Vec<CharStyle>,
    #[serde(default)]
    pub paragraph: ParaStyle,
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
