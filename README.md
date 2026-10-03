# HwpStudio read-only foundation

Native macOS 14+ SwiftUI/PDFKit workspace, with rhwp 0.8.6 pinned to
`f1f9c6ae58344ee9368996d3543f76b9345cf227`. The engine creates one immutable PDF
snapshot; preview and export consume exactly those bytes. This is not an HWP
editor and Hancom fidelity, font substitution and embedding remain unverified.
No original-format save operation is exposed.

Prerequisites: full Xcode, XcodeGen, Rust with Apple targets, cbindgen. Set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when needed. Run
`xcodegen generate`, then `xcodebuild test -scheme HwpStudio -destination
'platform=macOS' -only-testing:HwpStudioTests`. The build script defaults to a
universal engine; use `HWP_ENGINE_TARGETS=aarch64-apple-darwin` for a native arm64
iteration. `make test-rust` runs actual generated HWP/HWPX and failure tests.

The first build downloads locked dependencies. No bundled fallback fonts are
distributed; the engine uses macOS fonts. The app bundles rhwp's MIT notice.
Input is capped at 64 MiB and PDF rendering at 1,000 pages, but parsing remains
in-process: panic containment is not an OS memory limit or crash isolation.
Password and DRM documents are rejected with explicit errors.

Export rejects original-file destinations (including symlinks and hardlinks)
and writes PDF atomically. UI rendering/export errors leave no exportable stale
snapshot. Security-scoped source and export destinations are accessed only for
their operations.
