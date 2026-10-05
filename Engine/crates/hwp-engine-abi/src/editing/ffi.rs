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
        request: EditRequest,
    },
    Paragraph {
        target: EditTarget,
    },
    HitTest {
        revision: u64,
        page: u32,
        x: f64,
        y: f64,
    },
    Caret {
        revision: u64,
        position: EditPosition,
    },
    SelectionRects {
        revision: u64,
        selection: EditSelection,
    },
    Format {
        revision: u64,
        position: EditPosition,
    },
    #[serde(rename_all = "camelCase")]
    Navigate {
        revision: u64,
        position: EditPosition,
        motion: Motion,
        goal_x: Option<f64>,
    },
    /// Every match of `query`, as selections in document order.
    #[serde(rename_all = "camelCase")]
    Find {
        query: String,
        case_sensitive: bool,
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
            session.apply(request)?;
            state(session)
        }
        Request::Paragraph { target } => HwpEditResult::ok(session.paragraph(&target)?, Vec::new()),
        Request::HitTest {
            revision,
            page,
            x,
            y,
        } => HwpEditResult::ok(session.hit_test(revision, page, x, y)?, Vec::new()),
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
        Request::Format { revision, position } => {
            HwpEditResult::ok(session.format(revision, &position)?, Vec::new())
        }
        Request::Find {
            query,
            case_sensitive,
        } => HwpEditResult::ok(session.find(&query, case_sensitive)?, Vec::new()),
        Request::Export { format } => HwpEditResult::ok(session.reply(), session.export(format)?),
    })
}

/// Opens a session over a copy of `data`, or a blank document when `data` is null.
/// On success `*session` receives the handle and the result carries the initial state;
/// on failure `*session` is null.
///
/// # Safety
/// `data` must be null or readable for `length` bytes, and `session` must be writable.
#[no_mangle]
pub unsafe extern "C" fn hwp_edit_open(
    data: *const u8,
    length: usize,
    session: *mut *mut EditSession,
) -> *mut HwpEditResult {
    if session.is_null() {
        return HwpEditResult::error(EditError::InvalidInput);
    }
    unsafe { *session = std::ptr::null_mut() };
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

/// # Safety
/// `session` must come from `hwp_edit_open`; `json` must be readable for `length` bytes.
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
/// `session` must come from `hwp_edit_open` and not be used afterwards. Null is allowed.
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
