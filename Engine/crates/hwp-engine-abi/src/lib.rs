use std::ffi::{c_char, CString};

/// Returns the C ABI contract version.
#[no_mangle]
pub extern "C" fn hwp_engine_abi_version() -> u32 {
    1
}

/// Releases a string returned by this engine. Null is a no-op.
///
/// # Safety
/// Non-null pointers must have been returned by this engine via CString::into_raw,
/// and must not have been freed previously. Foreign or interior pointers are invalid.
#[no_mangle]
pub unsafe extern "C" fn hwp_engine_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn abi_version_is_one() {
        assert_eq!(super::hwp_engine_abi_version(), 1);
    }

    #[test]
    fn string_free_accepts_null_and_engine_owned_string() {
        unsafe {
            super::hwp_engine_string_free(std::ptr::null_mut());
            super::hwp_engine_string_free(std::ffi::CString::new("owned").unwrap().into_raw());
        }
    }
}
