# Header/Footer Text Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users edit existing visible header and footer text in place without changing unrelated HWP/HWPX content or layout.

**Architecture:** Extend the shared `EditTarget` pipeline with a semantic header/footer target and route the existing selection, navigation, formatting, undo, rendering, and save flows through rhwp's native header/footer APIs. The current selection itself is the edit-mode state: a double-click enters a header/footer, subsequent clicks and drags stay there, and a body click exits.

**Tech Stack:** Rust (`hwp-engine-abi`, rhwp 0.8.6), Swift 6, AppKit/SwiftUI, Swift Testing, JSON over the existing C ABI.

**Spec:** `docs/superpowers/specs/2026-10-06-header-footer-text-editing-design.md`

## Global Constraints

- Support macOS 14 or later and add no product dependency.
- Protocol version is exactly `3` in Rust and Swift after the target schema changes.
- `HeaderFooterTarget.applyTo` values are exactly `0 = both`, `1 = even`, `2 = odd`.
- `cell`, `note`, and `headerFooter` are mutually exclusive.
- A single click enters a header/footer only when the current selection is already in one; otherwise entry requires a double-click on visible header/footer text.
- Do not auto-create a header or footer from blank page margin clicks.
- Do not add named-style application, field insertion, or header/footer object editing in this plan.
- Existing field/control markers are read-only: edits around them are allowed, but replacement, deletion, split, or formatting may not consume them.
- Keep each edit atomic, use the existing snapshot rollback and undo pipeline, and never log document text.
- Do not mark the roadmap item complete before the listed manual HWP/HWPX and Korean IME checks pass.

## Review Focus

- An inherited header/footer whose source section differs from the clicked page section edits the source definition only; Task 2 pins this with an inherited-target hit test.
- Odd/even/both definitions resolve to the visible page's active definition and never overwrite a sibling definition; Tasks 2 and 6 test all three values.
- A saved page hint can become stale after reflow; Task 2 tests caret fallback to a page where the same definition is active.
- Blank margin clicks and ordinary single clicks outside an active header/footer edit fall through to the body without an error; Tasks 2 and 5 test both paths.
- Page-number/file-name field markers remain intact while Unicode text on either side is edited; Tasks 1, 3, and 6 test protected markers, Korean scalars, combining marks, and emoji.

---

### Task 1: Header/Footer Target and Safe Container Access

**Files:**
- Create: `Engine/crates/hwp-engine-abi/src/editing/header_footer.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/mod.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/protocol.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/commands.rs`
- Modify: Rust `EditTarget` literals reported by `rg -l 'EditTarget \{' Engine/crates/hwp-engine-abi/src`
- Test: `Engine/crates/hwp-engine-abi/src/editing/tests.rs`

**Interfaces:**
- Consumes: rhwp `Control::{Header, Footer}` and `HeaderFooterApply`.
- Produces: `HeaderFooterTarget { footer: bool, apply_to: u8, page: u32 }`; `header_footer::paragraphs(doc, target) -> Result<&[Paragraph], EditError>`; `header_footer::args(target) -> Result<(usize, bool, u8, usize), EditError>`; `header_footer::range_is_editable(paragraph, from, to) -> bool`.

- [ ] **Step 1: Write failing target/container tests**

  Add `header_footer_target_resolves_each_apply_kind_and_rejects_mixed_containers` and `header_footer_ranges_preserve_field_markers`. Assert that both/even/odd controls resolve by `section + footer + applyTo`, mixed `cell/note/headerFooter` targets return `UnsupportedTarget`, insertion beside `\u{0015}` is allowed, and a range containing `\u{0015}`, `\u{0016}`, or `\u{0017}` is rejected.

- [ ] **Step 2: Run the focused tests and confirm failure**

  Run: `cargo test --manifest-path Engine/Cargo.toml header_footer_target_ -- --nocapture`

  Expected: FAIL because `HeaderFooterTarget` and the helper module do not exist.

- [ ] **Step 3: Add the protocol type and container helper**

  Add `header_footer: Option<HeaderFooterTarget>` with serde default/skip rules and camel-case `applyTo`, set `PROTOCOL_VERSION` to `3`, register `mod header_footer`, and make `commands::{paragraphs,index,at_index,same_container,get}` use the helper. Reject any target with more than one nested container kind. Treat `EditTarget.paragraph` as the internal header/footer paragraph index.

- [ ] **Step 4: Add field-marker-aware validation**

  In `validate_position` and `validate_span`, use `range_is_editable` for header/footer targets instead of rejecting the entire paragraph for control markers. Keep body/cell/note behavior unchanged; reject any edit range that consumes a protected marker.

- [ ] **Step 5: Update all Rust target constructors and protocol tests**

  Add `header_footer: None` to existing Rust literals, change explicit current-version assertions and raw JSON from `2` to `3`, and keep the previous-version rejection test at `2`.

- [ ] **Step 6: Run focused and full Rust tests**

  Run: `cargo test --manifest-path Engine/Cargo.toml header_footer_target_ -- --nocapture`

  Expected: PASS.

  Run: `cargo test --manifest-path Engine/Cargo.toml --locked --workspace`

  Expected: all active tests PASS.

- [ ] **Step 7: Commit**

  ```bash
  git add Engine/crates/hwp-engine-abi/src
  git commit -m "feat: model header and footer edit targets"
  ```

### Task 2: Hit Testing, Caret, Selection, and Navigation

**Files:**
- Modify: `Engine/crates/hwp-engine-abi/src/editing/ffi.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/geometry.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/navigation.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/header_footer.rs`
- Test: `Engine/crates/hwp-engine-abi/src/editing/tests.rs`

**Interfaces:**
- Consumes: Task 1's `HeaderFooterTarget` and helpers.
- Produces: `EditSession::hit_test(revision, page, x, y, include_header_footer) -> Result<EditPosition, EditError>` and private `hit_test_header_footer(page, x, y) -> Result<Option<EditPosition>, EditError>`; header/footer-aware `caret`, `selection_rects`, and `navigate`.

- [ ] **Step 1: Write failing geometry tests**

  Add `header_footer_hit_testing_requires_opt_in_and_resolves_visible_definition`, `header_footer_geometry_uses_clicked_page_and_falls_back_after_reflow`, and `header_footer_selection_rejects_different_definitions`. Build fixtures with both/even/odd and inherited definitions. Assert opt-out falls through, opt-in returns the exact source section/applyTo/page/internal paragraph, selection rectangles stay on the clicked page, and stale page hints still produce a caret on an active page.

- [ ] **Step 2: Run the geometry tests and confirm failure**

  Run: `cargo test --manifest-path Engine/Cargo.toml header_footer_ -- --nocapture`

  Expected: FAIL because hit testing has no opt-in and geometry routes to body APIs.

- [ ] **Step 3: Extend the request and hit-test path**

  Add `include_header_footer: bool` to `Request::HitTest` with `#[serde(default)]`. When true, call rhwp's header and footer hit tests before footnote/body hit tests, parse `sectionIndex`, `applyTo`, `paraIndex`, and `charOffset`, and attach the requested page. A `{ "hit": false }` result must continue to the existing path.

- [ ] **Step 4: Route caret and selection geometry**

  For header/footer targets call `get_cursor_rect_in_header_footer_native` and `get_selection_rects_in_header_footer_native`. Use the target page first; if it no longer presents that definition, resolve the cursor with the native negative-page fallback and use the returned page for selection rectangles.

- [ ] **Step 5: Route navigation inside one definition**

  Reuse scalar/word/paragraph navigation over Task 1's paragraph slice. Implement line and vertical motions with native caret geometry plus opt-in header/footer hit testing on the same definition; clamp at its first and last paragraph. Never navigate into body text or another applyTo definition.

- [ ] **Step 6: Add review-focus cases and run Rust tests**

  Assert an inherited source section is retained, odd/even definitions remain distinct, a blank margin returns a body target, and Unicode grapheme/word navigation stays on scalar boundaries.

  Run: `cargo test --manifest-path Engine/Cargo.toml header_footer_ -- --nocapture`

  Expected: all header/footer tests PASS.

- [ ] **Step 7: Commit**

  ```bash
  git add Engine/crates/hwp-engine-abi/src/editing
  git commit -m "feat: navigate header and footer text"
  ```

### Task 3: Atomic Text and Formatting Commands

**Files:**
- Modify: `Engine/crates/hwp-engine-abi/src/editing/commands.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/format.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/styles.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/preservation.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/header_footer.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/navigation.rs`
- Test: `Engine/crates/hwp-engine-abi/src/editing/tests.rs`

**Interfaces:**
- Consumes: Tasks 1-2 target, validation, and geometry.
- Produces: header/footer branches for `paragraph`, `Replace`, `Split`, `MergePrevious`, `FormatText`, `FormatParagraphs`, `format`, and `find`; explicit `UnsupportedTarget` for `ApplyStyle`.

- [ ] **Step 1: Write failing edit and rollback tests**

  Add `header_footer_replaces_splits_merges_formats_and_undoes_atomically`, `header_footer_replace_spans_paragraphs_in_one_revision`, and `header_footer_failed_edit_rolls_back_revision_and_document`. Assert Korean/emoji/combining text, caret targets, paragraph counts, char/paragraph format queries, one undo step, redo, and unchanged state after invalid/protected-marker edits.

- [ ] **Step 2: Run the focused edit tests and confirm failure**

  Run: `cargo test --manifest-path Engine/Cargo.toml header_footer_ -- --nocapture`

  Expected: FAIL because commands still route to body APIs.

- [ ] **Step 3: Route replacement, split, and merge**

  Use `replace_range_in_header_footer_native` once for every `Replace` selection rather than the body delete/insert loop. Use `split_paragraph_in_header_footer_native` and `merge_paragraph_in_header_footer_native` for the structural commands and return the resulting semantic target/caret.

- [ ] **Step 4: Route format queries and changes**

  Query with `get_char_properties_in_header_footer_native` and `get_para_properties_in_hf_native`; mutate with `apply_char_format_in_header_footer_native` and `apply_para_format_in_hf_native`. Keep the existing `CharStyle`/`ParaStyle` JSON mapping. Reject `ApplyStyle` before mutation.

- [ ] **Step 5: Extend preservation checks**

  Make `edited_paragraphs` reach the selected header/footer control. For text edits, remove and compare only the changed internal paragraph range; for formatting, clear only selected formatting fields. Keep sibling definitions, body paragraphs, tables, images, binary payloads, and other sections byte/structure-equivalent after normalization.

- [ ] **Step 6: Include header/footer matches in safe find/copy/cut behavior**

  Extend `EditSession::find` by scanning each unique header/footer definition's paragraphs and returning semantic targets with a page where that definition is active; do not return protected field markers as query text and do not duplicate inherited definitions for every page. Add `header_footer_find_returns_each_definition_once`, asserting matching visible text returns a semantic target once per definition and body search results remain unchanged.

- [ ] **Step 7: Run edit tests and the full Rust suite**

  Run: `cargo test --manifest-path Engine/Cargo.toml header_footer_ -- --nocapture`

  Expected: all header/footer tests PASS.

  Run: `cargo test --manifest-path Engine/Cargo.toml --locked --workspace`

  Expected: all active tests PASS and ignored corpus/bench tests remain ignored.

- [ ] **Step 8: Commit**

  ```bash
  git add Engine/crates/hwp-engine-abi/src/editing
  git commit -m "feat: edit header and footer text"
  ```

### Task 4: Swift Protocol and Document Bridge

**Files:**
- Modify: `App/Editing/EditProtocol.swift`
- Modify: `App/Editing/EditSession.swift`
- Modify: `App/Document/HwpDocument.swift`
- Modify: `App/Workspace/DocumentCanvas.swift` (`EditTarget` extensions only)
- Modify: `Tests/EditSessionTests.swift`
- Test: `Tests/DocumentTests.swift`

**Interfaces:**
- Consumes: Rust protocol version 3 and `includeHeaderFooter` hit-test field.
- Produces: Swift `HeaderFooterTarget`; `EditSession.hitTest(revision:page:x:y:includeHeaderFooter:)`; `HwpDocument.hitTest(page:x:y:includeHeaderFooter:)`; `EditTarget.isHeaderFooter` and header/footer-aware `index`/`offset(by:)`.

- [ ] **Step 1: Write failing Swift protocol tests**

  Add `headerFooterTargetRoundTripsThroughRequests` and update `protocolVersionMismatchIsRejectedBeforeRendering`. Assert encoded JSON uses `headerFooter`, `applyTo`, `page`, and `includeHeaderFooter`, defaults the include flag to false at Swift call sites, and expects version `3`.

- [ ] **Step 2: Run focused Swift tests and confirm failure**

  Run: `make engine`

  Expected: engine library builds successfully.

  Run: `swift test --filter EditSessionTests`

  Expected: FAIL because Swift still declares protocol version 2 and has no target type.

- [ ] **Step 3: Implement Swift protocol types and requests**

  Add `HeaderFooterTarget: Codable, Hashable, Sendable`, add `headerFooter: HeaderFooterTarget? = nil` to `EditTarget`, set the protocol version to `3`, and encode `includeHeaderFooter`. Keep existing memberwise call sites source-compatible through the nil default.

- [ ] **Step 4: Thread the hit-test option through session and document**

  Give both methods `includeHeaderFooter: Bool = false`. Update `EditTarget.index` and `offset(by:)` so a header/footer changes the outer `paragraph` and retains source section, applyTo, footer kind, and page. Make `HwpDocument.text(of:)` omit protected `U+0015`–`U+0017` markers from copied plain text while leaving them in the document.

- [ ] **Step 5: Add document-level target behavior tests**

  In `DocumentTests`, assert paragraph lookup, `selectAll`, copy, cut, input, Enter, and Backspace operate within a supplied header/footer target and do not cross into body text. Assert copy omits protected markers, cut uses one undoable `Replace`, and `applyStyle` failure leaves the selection and document usable.

- [ ] **Step 6: Run focused and full Swift tests**

  Run: `swift test --filter EditSessionTests`

  Expected: PASS.

  Run: `swift test --filter DocumentTests`

  Expected: PASS.

- [ ] **Step 7: Commit**

  ```bash
  git add App/Editing App/Document App/Workspace/DocumentCanvas.swift Tests
  git commit -m "feat: bridge header and footer edit targets"
  ```

### Task 5: Canvas Entry, Exit, Click, and Drag Behavior

**Files:**
- Modify: `App/Workspace/DocumentCanvas.swift`
- Test: `Tests/DocumentTests.swift`

**Interfaces:**
- Consumes: Task 4's `includeHeaderFooter` option and `EditTarget.isHeaderFooter`.
- Produces: in-place entry on double-click, continued header/footer hit testing while active, and automatic body exit on miss.

- [ ] **Step 1: Write failing AppKit interaction tests**

  Add `headerFooterEditingRequiresDoubleClickThenSupportsClickDragAndBodyExit`. Generate mouse events against engine-provided header/footer caret rectangles. Assert a single click from body does not enter; a double-click selects a word in the header/footer; a following single click and drag keep the same semantic definition; and a body click produces a body target.

- [ ] **Step 2: Run the interaction test and confirm failure**

  Run: `swift test --filter headerFooterEditingRequiresDoubleClickThenSupportsClickDragAndBodyExit`

  Expected: FAIL because canvas hit tests never opt in.

- [ ] **Step 3: Update click and drag hit tests**

  In `click`, set `includeHeaderFooter` when `clicks >= 2` or the current selection focus has a header/footer target. In `extendToDrag`, use the anchor's header/footer state. Keep object selection ahead of text only after a header/footer miss, and leave ordinary body/table/note behavior unchanged.

- [ ] **Step 4: Update page-motion hit testing**

  Pass the current header/footer state in `movePage`; clamp extension with the existing `reaches` container guard. Do not enable header/footer hits for object-drop or shape-placement hit tests.

- [ ] **Step 5: Add blank-margin and IME regression coverage**

  Assert a double-click in blank top/bottom margin falls through without creating content, and an active header/footer selection accepts marked Korean text, commit, and undo as one step using the existing composition test harness.

- [ ] **Step 6: Run canvas tests and the full Swift suite**

  Run: `swift test --filter DocumentTests`

  Expected: PASS.

  Run: `swift test`

  Expected: all active tests PASS.

- [ ] **Step 7: Commit**

  ```bash
  git add App/Workspace/DocumentCanvas.swift Tests/DocumentTests.swift
  git commit -m "feat: edit headers and footers in place"
  ```

### Task 6: HWP/HWPX Round Trips, Full Verification, and Roadmap

**Files:**
- Modify: `Engine/crates/hwp-engine-abi/src/editing/tests.rs`
- Modify: `Tests/EditSessionTests.swift`
- Modify after manual verification only: `docs/ROADMAP.md`
- Modify if a new limitation is found: `docs/BUG_HANDOFF.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: persistent, verified header/footer editing for both formats and an accurate project status.

- [ ] **Step 1: Write failing format round-trip tests**

  Add `header_footer_text_and_format_round_trip_hwp_and_hwpx`. For each format, create both/even/odd definitions with `가`, `e\u{301}`, emoji, and protected page/file markers; edit text and paragraph formatting; export; reopen; then assert target definitions, text, markers, formatting, page count, and unrelated table/image data.

- [ ] **Step 2: Run the round-trip test before final fixes**

  Run: `cargo test --manifest-path Engine/Cargo.toml header_footer_text_and_format_round_trip_hwp_and_hwpx -- --nocapture`

  Expected: FAIL if either serializer loses the new edit, marker, or formatting.

- [ ] **Step 3: Make only serializer/adapter fixes proven necessary by Step 2**

  Keep fixes in the existing rhwp patch workflow (`Vendor/rhwp-layout.patch` plus `Vendor/README.md`) if the failure is below `hwp-engine-abi`; do not broaden into object or field insertion support.

- [ ] **Step 4: Run complete automated verification**

  Run: `make test`

  Expected: Rust and Swift active tests all PASS, with only documented ignored tests.

- [ ] **Step 5: Build and perform the manual matrix**

  Run: `make run`

  Verify on real HWP and HWPX samples: header and footer double-click; Korean IME composition/candidate/commit/Undo; selection replacement; Enter/Backspace; char and paragraph formatting; repeated-page refresh; inherited and odd/even definitions; body-click exit; save and reopen in HwpStudio and Hancom Viewer. Record any unsupported construct in `docs/BUG_HANDOFF.md` without document text.

- [ ] **Step 6: Update roadmap only if the manual matrix passed**

  Change the header/footer text-editing checkbox in `docs/ROADMAP.md` to complete and add the verification date. If any required manual case fails, leave it unchecked and describe the exact remaining behavior in `docs/BUG_HANDOFF.md`.

- [ ] **Step 7: Review the complete branch and commit documentation/test additions**

  Run: `git diff --check`

  Expected: no whitespace errors.

  Run: `git status --short`

  Expected: only intended tracked files plus the repository's known generated untracked directories.

  ```bash
  git add Engine/crates/hwp-engine-abi/src/editing/tests.rs Tests/EditSessionTests.swift docs/ROADMAP.md docs/BUG_HANDOFF.md Vendor/rhwp-layout.patch Vendor/README.md
  git commit -m "test: verify header and footer editing"
  ```

- [ ] **Step 8: Push the verified branch**

  Push `codex/foundation` through the authenticated GitHub Desktop session, then verify `HEAD` equals `origin/codex/foundation`.
