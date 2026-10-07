//! C ABI for long-lived edit sessions.
//!
//! Every call returns an owned `HwpEditResult` (status + UTF-8 JSON + optional bytes) that the
//! caller frees with `hwp_edit_result_free`. Requests are JSON envelopes tagged by `op`, so new
//! operations extend `Request` instead of adding C functions. A session handle must be used
//! from one thread at a time.
use super::*;
use serde::Deserialize;
use std::ffi::{c_char, CString};

/// Large enough for the 1 MiB text limit plus JSON escaping.
const REQUEST_LIMIT: usize = 8 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", deny_unknown_fields)]
enum Request {
    Apply {
        request: Box<EditRequest>,
    },
    Paragraph {
        target: EditTarget,
    },
    HitTest {
        revision: u64,
        page: u32,
        x: f64,
        y: f64,
        #[serde(default, rename = "includeHeaderFooter")]
        include_header_footer: bool,
    },
    Caret {
        revision: u64,
        position: EditPosition,
    },
    SelectionRects {
        revision: u64,
        selection: EditSelection,
    },
    /// The format at `position`; with `from`, of the characters selected between them.
    Format {
        revision: u64,
        position: EditPosition,
        #[serde(default)]
        from: Option<EditPosition>,
    },
    #[serde(rename_all = "camelCase")]
    Navigate {
        revision: u64,
        position: EditPosition,
        motion: Motion,
        goal_x: Option<f64>,
    },
    /// The topmost picture or equation under a page point, or null.
    ObjectAt {
        revision: u64,
        page: u32,
        x: f64,
        y: f64,
    },
    /// The table borders on `page` that can be dragged.
    TableLines {
        revision: u64,
        page: u32,
    },
    /// Where an object is laid out, looking from `page` outward.
    Place {
        revision: u64,
        object: ObjectRef,
        page: u32,
    },
    ObjectProps {
        object: ObjectRef,
    },
    CellProps {
        cell: EditTarget,
    },
    /// A display list of the equation in `data`, its size in the JSON.
    #[serde(rename_all = "camelCase")]
    EquationPreview {
        script: String,
        font_size: u32,
        color: u32,
    },
    /// The document's styles, in order.
    Styles,
    /// Shows or hides 문단 부호 and 조판 부호.
    ShowMarks {
        paragraph: bool,
        control: bool,
        /// 투명 선.
        #[serde(default)]
        borders: bool,
    },
    /// Paper and margins of a section.
    PageSetup {
        section: u32,
    },
    /// 현재 쪽만 감추기 of a body paragraph.
    PageHide {
        target: EditTarget,
    },
    /// The 책갈피 of the body.
    Bookmarks,
    /// 문서 정보's 문서 통계.
    Statistics,
    /// Every match of `query`, as selections in document order.
    #[serde(rename_all = "camelCase")]
    Find {
        query: String,
        case_sensitive: bool,
    },
    /// 복사하기 with formats: the selection to the engine's clipboard, and as HTML.
    Copy {
        revision: u64,
        selection: EditSelection,
    },
    /// 복사하기 for a selected object.
    CopyObject {
        object: ObjectRef,
    },
    /// Verified HWP/HWPX bytes, or the whole-document PDF, in `data`.
    Export {
        format: SaveFormat,
    },
}

pub struct HwpEditResult {
    status: u32,
    json: CString,
    data: Vec<u8>,
}
impl HwpEditResult {
    fn ok(payload: impl serde::Serialize, data: Vec<u8>) -> *mut Self {
        let json = serde_json::to_string(&payload).expect("protocol types serialize");
        Box::into_raw(Box::new(Self {
            status: 0,
            json: CString::new(json).expect("JSON escapes NUL"),
            data,
        }))
    }
    fn error(error: EditError) -> *mut Self {
        let json = serde_json::json!({ "error": error }).to_string();
        Box::into_raw(Box::new(Self {
            status: 1,
            json: CString::new(json).unwrap(),
            data: Vec::new(),
        }))
    }
}

fn state(session: &EditSession) -> *mut HwpEditResult {
    HwpEditResult::ok(session.reply(), session.rendering())
}
fn handle(session: &mut EditSession, request: Request) -> Result<*mut HwpEditResult, EditError> {
    Ok(match request {
        Request::Apply { request } => {
            session.apply(*request)?;
            state(session)
        }
        Request::Paragraph { target } => HwpEditResult::ok(session.paragraph(&target)?, Vec::new()),
        Request::Copy {
            revision,
            selection,
        } => HwpEditResult::ok(session.copy(revision, &selection)?, Vec::new()),
        Request::CopyObject { object } => {
            HwpEditResult::ok(session.copy_object(&object)?, Vec::new())
        }
        Request::HitTest {
            revision,
            page,
            x,
            y,
            include_header_footer,
        } => HwpEditResult::ok(
            session.hit_test(revision, page, x, y, include_header_footer)?,
            Vec::new(),
        ),
        Request::Caret { revision, position } => {
            HwpEditResult::ok(session.caret(revision, &position)?, Vec::new())
        }
        Request::SelectionRects {
            revision,
            selection,
        } => HwpEditResult::ok(session.selection_rects(revision, &selection)?, Vec::new()),
        Request::Navigate {
            revision,
            position,
            motion,
            goal_x,
        } => HwpEditResult::ok(
            session.navigate(revision, &position, motion, goal_x)?,
            Vec::new(),
        ),
        Request::Format {
            revision,
            position,
            from,
        } => HwpEditResult::ok(
            session.format(revision, &position, from.as_ref())?,
            Vec::new(),
        ),
        Request::ObjectAt {
            revision,
            page,
            x,
            y,
        } => HwpEditResult::ok(session.object_at(revision, page, x, y)?, Vec::new()),
        Request::TableLines { revision, page } => {
            HwpEditResult::ok(session.table_lines(revision, page)?, Vec::new())
        }
        Request::Place {
            revision,
            object,
            page,
        } => HwpEditResult::ok(session.place(revision, &object, page)?, Vec::new()),
        Request::ObjectProps { object } => {
            HwpEditResult::ok(session.object_props(&object)?, Vec::new())
        }
        Request::CellProps { cell } => HwpEditResult::ok(session.cell_props(&cell)?, Vec::new()),
        Request::EquationPreview {
            script,
            font_size,
            color,
        } => {
            let display = session.equation_preview(&script, font_size, color)?;
            let mut data = Vec::new();
            display.encode(&mut data);
            HwpEditResult::ok(
                serde_json::json!({ "width": display.width, "height": display.height }),
                data,
            )
        }
        Request::Styles => HwpEditResult::ok(session.styles(), Vec::new()),
        Request::ShowMarks {
            paragraph,
            control,
            borders,
        } => {
            session.show_marks(paragraph, control, borders)?;
            state(session)
        }
        Request::PageSetup { section } => {
            HwpEditResult::ok(session.page_setup(section)?, Vec::new())
        }
        Request::PageHide { target } => HwpEditResult::ok(session.page_hide(&target)?, Vec::new()),
        Request::Bookmarks => HwpEditResult::ok(session.bookmarks(), Vec::new()),
        Request::Statistics => HwpEditResult::ok(session.statistics(), Vec::new()),
        Request::Find {
            query,
            case_sensitive,
        } => HwpEditResult::ok(session.find(&query, case_sensitive)?, Vec::new()),
        Request::Export { format } => HwpEditResult::ok(session.reply(), session.export(format)?),
    })
}

/// Legacy unversioned opening cannot safely consume this engine's rendering protocol.
/// It always rejects before opening or returning rendering bytes.
///
/// # Safety
/// `data` must be null or readable for `length` bytes, and `session` must be writable.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_open(
    _data: *const u8,
    _length: usize,
    session: *mut *mut EditSession,
) -> *mut HwpEditResult {
    if session.is_null() {
        return HwpEditResult::error(EditError::InvalidInput);
    }
    unsafe { *session = std::ptr::null_mut() };
    HwpEditResult::error(EditError::IncompatibleEngine)
}

/// Opens a session after negotiating the rendering and request protocol version.
/// On success `*session` receives the handle and the result carries the initial state;
/// on failure `*session` is null and no rendering bytes are returned.
///
/// # Safety
/// `data` must be null or readable for `length` bytes, and `session` must be writable.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_open_v2(
    version: u32,
    data: *const u8,
    length: usize,
    session: *mut *mut EditSession,
) -> *mut HwpEditResult {
    if session.is_null() {
        return HwpEditResult::error(EditError::InvalidInput);
    }
    unsafe { *session = std::ptr::null_mut() };
    if version != PROTOCOL_VERSION {
        return HwpEditResult::error(EditError::IncompatibleEngine);
    }
    let opened = catch_unwind(|| {
        if data.is_null() {
            EditSession::blank()
        } else {
            EditSession::open(unsafe { std::slice::from_raw_parts(data, length) })
        }
    })
    .unwrap_or(Err(EditError::RenderFailed));
    match opened {
        Ok(opened) => {
            let result = state(&opened);
            unsafe { *session = Box::into_raw(Box::new(opened)) };
            result
        }
        Err(error) => HwpEditResult::error(error),
    }
}

/// `hwp_edit_open_v2` for a document locked with a password, `password_length` UTF-8 bytes.
/// A wrong password fails with `PasswordRequired`.
///
/// # Safety
/// `data` must be readable for `length` bytes, `password` for `password_length` bytes, and
/// `session` must be writable.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_open_password(
    version: u32,
    data: *const u8,
    length: usize,
    password: *const u8,
    password_length: usize,
    session: *mut *mut EditSession,
) -> *mut HwpEditResult {
    if session.is_null() || data.is_null() || password.is_null() {
        return HwpEditResult::error(EditError::InvalidInput);
    }
    unsafe { *session = std::ptr::null_mut() };
    if version != PROTOCOL_VERSION {
        return HwpEditResult::error(EditError::IncompatibleEngine);
    }
    let opened = catch_unwind(|| {
        EditSession::open_with(
            unsafe { std::slice::from_raw_parts(data, length) },
            Some(unsafe { std::slice::from_raw_parts(password, password_length) }),
        )
    })
    .unwrap_or(Err(EditError::RenderFailed));
    match opened {
        Ok(opened) => {
            let result = state(&opened);
            unsafe { *session = Box::into_raw(Box::new(opened)) };
            result
        }
        Err(error) => HwpEditResult::error(error),
    }
}

/// # Safety
/// `session` must come from `hwp_edit_open_v2`; `json` must be readable for `length` bytes.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_request(
    session: *mut EditSession,
    json: *const u8,
    length: usize,
) -> *mut HwpEditResult {
    if session.is_null() || json.is_null() {
        return HwpEditResult::error(EditError::InvalidInput);
    }
    if length > REQUEST_LIMIT {
        return HwpEditResult::error(EditError::ResourceLimit);
    }
    let session = unsafe { &mut *session };
    let Ok(request) =
        serde_json::from_slice::<Request>(unsafe { std::slice::from_raw_parts(json, length) })
    else {
        return HwpEditResult::error(EditError::InvalidInput);
    };
    match catch_unwind(AssertUnwindSafe(|| handle(session, request))) {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => HwpEditResult::error(error),
        Err(_) => {
            session.locked = true;
            HwpEditResult::error(EditError::Locked)
        }
    }
}

/// # Safety
/// `session` must come from `hwp_edit_open_v2` and not be used afterwards. Null is allowed.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_close(session: *mut EditSession) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) })
    }
}

/// 0 success, 1 error (JSON `{"error": "<EditError>"}`).
///
/// # Safety
/// `result` must be a live result.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_result_status(result: *const HwpEditResult) -> u32 {
    unsafe { result.as_ref() }.map_or(1, |r| r.status)
}
/// Borrowed NUL-terminated UTF-8 JSON, valid until `hwp_edit_result_free`.
///
/// # Safety
/// `result` must be a live result.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_result_json(result: *const HwpEditResult) -> *const c_char {
    unsafe { result.as_ref() }.map_or(std::ptr::null(), |r| r.json.as_ptr())
}
/// Borrowed bytes: the PDF of `changedPages` for `open`/`apply`, the document for `export`,
/// otherwise empty.
/// Valid until `hwp_edit_result_free`.
///
/// # Safety
/// `result` must be a live result.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_result_data(result: *const HwpEditResult) -> *const u8 {
    unsafe { result.as_ref() }.map_or(std::ptr::null(), |r| r.data.as_ptr())
}
/// # Safety
/// `result` must be a live result.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_result_length(result: *const HwpEditResult) -> usize {
    unsafe { result.as_ref() }.map_or(0, |r| r.data.len())
}
/// # Safety
/// Free once; null allowed.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_result_free(result: *mut HwpEditResult) {
    if !result.is_null() {
        drop(unsafe { Box::from_raw(result) })
    }
}
