//! HwpStudio engine: rhwp behind a C ABI. Swift talks to `editing::ffi` only.
pub mod editing;
pub mod layout_audit;
#[cfg(test)]
mod layout_tests;
