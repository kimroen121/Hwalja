use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CellTarget {
    pub control: u32,
    pub cell: u32,
    pub paragraph: u32,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditTarget {
    pub section: u32,
    pub paragraph: u32,
    pub cell: Option<CellTarget>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditPosition {
    pub target: EditTarget,
    pub scalar: u32,
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
    Split {
        position: EditPosition,
    },
    MergePrevious {
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
    /// A new table at `position` in the body; the caret moves into its first cell.
    InsertTable {
        position: EditPosition,
        rows: u16,
        columns: u16,
    },
    /// Adds or removes a row or column of the table holding `cell`.
    EditTable {
        cell: EditTarget,
        change: TableChange,
    },
    /// Paper and margins of one section.
    SetPage {
        section: u32,
        page: PageSetup,
    },
    Undo,
    Redo,
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
    pub can_undo: bool,
    pub can_redo: bool,
    pub dirty: bool,
    pub locked: bool,
}
/// Character format: as a query result every field is set; as a change, unset fields stay.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CharStyle {
    pub font: Option<String>,
    /// Points.
    pub size: Option<f64>,
    pub bold: Option<bool>,
    pub italic: Option<bool>,
    pub underline: Option<bool>,
    pub strikethrough: Option<bool>,
    /// `#rrggbb`.
    pub color: Option<String>,
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
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ParaStyle {
    pub alignment: Option<Alignment>,
    /// Percent of the font height; unset when the paragraph uses another spacing kind.
    pub line_spacing: Option<f64>,
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
    pub paragraph: ParaStyle,
    pub fonts: Vec<String>,
}
#[derive(Debug, Clone, Serialize)]
pub struct ParagraphInfo {
    pub target: EditTarget,
    /// Paragraphs in the same container (body or cell).
    pub count: u32,
    pub text: String,
    pub editable: bool,
    pub reason: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum EditError {
    InvalidInput,
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
