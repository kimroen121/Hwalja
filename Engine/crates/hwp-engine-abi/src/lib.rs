//! hwalja engine: rhwp behind a C ABI. Swift talks to `editing::ffi` only.
pub mod editing;
#[cfg(test)]
mod layout_tests;
