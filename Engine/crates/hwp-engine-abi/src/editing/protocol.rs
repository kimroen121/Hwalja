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
    Undo,
    Redo,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditRequest {
    pub version: u32,
    pub revision: u64,
    pub command: EditCommand,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditReply {
    pub version: u32,
    pub revision: u64,
    pub selection: Option<EditSelection>,
    pub page_count: u32,
    /// Pages re-rendered by this revision; the accompanying PDF holds exactly these, in order.
    pub changed_pages: Vec<u32>,
    pub suspect_pages: Vec<u32>,
    pub can_undo: bool,
    pub can_redo: bool,
    pub dirty: bool,
    pub locked: bool,
}
#[derive(Debug, Clone, Serialize)]
pub struct ParagraphInfo {
    pub target: EditTarget,
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
