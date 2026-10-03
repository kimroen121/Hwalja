use rhwp::DocumentCore;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

pub struct HwpSnapshot {
    pdf: Vec<u8>,
    pages: u32,
}
#[repr(C)]
pub struct HwpOpenResult {
    pub snapshot: *mut HwpSnapshot,
    /// 0 success, 1 invalid, 2 password required, 3 unsupported, 4 rendering, 5 limit, 6 panic.
    pub status: u32,
    pub message: *mut c_char,
}
#[no_mangle]
pub extern "C" fn hwp_engine_abi_version() -> u32 {
    1
}
fn failure(status: u32, message: String) -> HwpOpenResult {
    HwpOpenResult {
        snapshot: std::ptr::null_mut(),
        status,
        message: CString::new(message.replace('\0', " ")).unwrap().into_raw(),
    }
}
/// Requires a valid readable buffer. Panic containment is not process isolation.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_open(data: *const u8, length: usize) -> HwpOpenResult {
    if length > 64 * 1024 * 1024 {
        return failure(5, "Files larger than 64 MiB are unsupported.".into());
    }
    if data.is_null() || length == 0 {
        return failure(1, "Empty or missing document.".into());
    }
    match catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(data, length) };
        if let Err(error) = rhwp::parser::parse_document(bytes) {
            let status = match &error {
                rhwp::parser::ParseError::EncryptedDocument => 2,
                rhwp::parser::ParseError::UnsupportedFormat { .. } => 3,
                _ => 1,
            };
            return failure(status, error.to_string());
        }
        let core = match DocumentCore::from_bytes(bytes) {
            Ok(core) => core,
            Err(error) => return failure(1, error.to_string()),
        };
        let pages = core.page_count();
        if pages > 1000 {
            return failure(5, "Documents exceeding 1,000 pages are unsupported.".into());
        }
        match core.render_document_pdf_native() {
            Ok(pdf) => HwpOpenResult {
                snapshot: Box::into_raw(Box::new(HwpSnapshot { pdf, pages })),
                status: 0,
                message: std::ptr::null_mut(),
            },
            Err(error) => failure(4, error.to_string()),
        }
    })) {
        Ok(result) => result,
        Err(_) => failure(6, "The document engine stopped unexpectedly.".into()),
    }
}
/// Borrowed bytes stay valid until snapshot_free; do not mutate or free them.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_pdf_data(snapshot: *const HwpSnapshot) -> *const u8 {
    if snapshot.is_null() {
        std::ptr::null()
    } else {
        unsafe { (*snapshot).pdf.as_ptr() }
    }
}
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_pdf_length(snapshot: *const HwpSnapshot) -> usize {
    if snapshot.is_null() {
        0
    } else {
        unsafe { (*snapshot).pdf.len() }
    }
}
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_page_count(snapshot: *const HwpSnapshot) -> u32 {
    if snapshot.is_null() {
        0
    } else {
        unsafe { (*snapshot).pages }
    }
}
/// Free once; null allowed. Snapshot access must not overlap release.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_snapshot_free(snapshot: *mut HwpSnapshot) {
    if !snapshot.is_null() {
        drop(unsafe { Box::from_raw(snapshot) });
    }
}
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_empty_and_oversized_before_reading() {
        for (length, status) in [(0, 1), (64 * 1024 * 1024 + 1, 5)] {
            let result = unsafe { hwp_engine_open(std::ptr::null(), length) };
            assert_eq!(result.status, status);
            unsafe { hwp_engine_string_free(result.message) };
        }
    }
    #[test]
    fn generated_hwp_and_hwpx_produce_owned_pdf_snapshots() {
        let mut source = DocumentCore::new_empty();
        source.create_blank_document_native().unwrap();
        source
            .insert_text_native(0, 0, 0, "HwpStudio generated fixture — 한글 읽기 전용")
            .unwrap();
        for (extension, bytes) in [
            ("hwp", source.export_hwp_native().unwrap()),
            ("hwpx", source.export_hwpx_native().unwrap()),
        ] {
            let result = unsafe { hwp_engine_open(bytes.as_ptr(), bytes.len()) };
            if result.status != 0 {
                panic!(
                    "{}",
                    unsafe { std::ffi::CStr::from_ptr(result.message) }.to_string_lossy()
                );
            }
            unsafe {
                assert!(hwp_engine_page_count(result.snapshot) > 0);
                let pdf = std::slice::from_raw_parts(
                    hwp_engine_pdf_data(result.snapshot),
                    hwp_engine_pdf_length(result.snapshot),
                );
                assert!(pdf.starts_with(b"%PDF-"));
                hwp_engine_snapshot_free(result.snapshot);
            }
            if std::env::var_os("HWP_WRITE_FIXTURES").is_some() {
                let folder = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../../Tests/Fixtures");
                std::fs::create_dir_all(&folder).unwrap();
                std::fs::write(folder.join(format!("generated.{extension}")), bytes).unwrap();
            }
        }
    }
    #[test]
    fn classifies_corrupt_password_and_drm_documents() {
        let mut source = DocumentCore::new_empty();
        source.create_blank_document_native().unwrap();
        let encrypted = source
            .export_hwpx_native_with_password(b"fixture-password")
            .unwrap();
        for (bytes, expected) in [
            (encrypted.as_slice(), 2),
            (b"\x9b DRMONE protected".as_slice(), 3),
            (b"PK\x03\x04broken".as_slice(), 3),
            (b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1".as_slice(), 1),
        ] {
            let result = unsafe { hwp_engine_open(bytes.as_ptr(), bytes.len()) };
            assert_eq!(result.status, expected);
            assert!(result.snapshot.is_null());
            unsafe { hwp_engine_string_free(result.message) };
        }
    }
}
