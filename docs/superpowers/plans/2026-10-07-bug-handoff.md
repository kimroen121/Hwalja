# BUG_HANDOFF Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reproduce, fix, and verify every remaining problem and manual-check item in `docs/BUG_HANDOFF.md` without regressing HWP/HWPX fidelity.

**Architecture:** Fix defects at the lowest shared layer: rhwp layout for pagination and paragraph geometry, the display-list/Core Text boundary for screen glyphs, and edit-session geometry for selection. Each behavior gets a failing regression test before its production change, followed by the focused test, the complete suite, an app build, and a small commit.

**Tech Stack:** Swift 6, AppKit/Core Text/Core Graphics, Swift Testing, Rust, rhwp, Cargo, Make.

**Spec:** `docs/BUG_HANDOFF.md`

## Global Constraints

- Preserve the original HWP/HWPX and all unsupported records; unsafe documents remain read-only.
- HWP/HWPX screen layout and PDF export must stay mutually consistent.
- Follow `docs/GUIDELINES.md`: one engine test and one app test per user-visible feature where applicable.
- Change vendored rhwp in `build/rhwp`, regenerate `Vendor/rhwp-layout.patch`, and update `Vendor/README.md`; never commit `build/`.
- Use the exact Hancom/macOS terminology already established in the UI.
- Run `make test` before every completion claim and commit.

## Review Focus

- Mixed Korean/Latin/color-emoji runs must keep non-overlapping painted bounds and the same final advance at 100% and 390% zoom.
- Variable fonts must preserve requested weight/slant without silently changing family or line width.
- Section-definition controls in the first paragraph must not suppress its first-line indent.
- Pagination fixes must not clip tables, move objects outside the body, or alter documents that already carry line records.
- Cross-container selection must never create an invalid edit range or delete protected header/footer fields.

---

### Task 1: Color Emoji Display Geometry

**Files:**
- Modify: `Tests/DocumentTests.swift`
- Modify: `App/Editing/PageDisplay.swift`
- Modify if the encoded contract needs more geometry: `Engine/crates/hwp-engine-abi/src/editing/display.rs`
- Modify: `docs/BUG_HANDOFF.md`

**Interfaces:**
- Consumes: `PageDisplay.Op.Text`, `RenderedPage.draw(in:rect:)`.
- Produces: text-run drawing whose logical advance and painted color-glyph bounds do not overlap.

- [ ] Add a bitmap regression test rendering `📣😄📖` through the real document/display-list path and assert separated foreground components plus caret clearance.
- [ ] Run the focused Swift test and verify the overlap assertion fails for the current renderer.
- [ ] Record Core Text typographic advance and image bounds for each shaped run; prove whether global `textLength` scaling is the failing boundary.
- [ ] Make the smallest display geometry change that preserves the SVG text chunk's final advance while preventing adjacent color-glyph overlap.
- [ ] Run the focused test, `make test`, and an app snapshot at 390%.
- [ ] Remove the resolved BUG_HANDOFF row and commit `fix: keep consecutive color emoji apart`.

### Task 2: Variable Font Axes

**Files:**
- Modify: `Engine/crates/hwp-engine-abi/src/editing/display.rs`
- Modify: `App/Editing/PageDisplay.swift`
- Modify: `Engine/crates/hwp-engine-abi/src/layout_tests.rs`
- Modify: `Tests/DocumentTests.swift`
- Modify if PDF font selection requires it: `Vendor/rhwp-layout.patch`, `Vendor/README.md`
- Modify: `docs/BUG_HANDOFF.md`

**Interfaces:**
- Consumes: SVG `font-weight`/`font-style` and font file face index.
- Produces: display-list face variation data and matching Core Text/PDF font instances.

- [ ] Add Rust and Swift tests proving Pretendard Variable bold/italic retains its family and requested traits without changing the normal-face advance contract.
- [ ] Run both focused tests and verify they fail for the missing-axis path.
- [ ] Extend the display-list contract with only the required variation coordinates and instantiate the matching `CTFontDescriptor`.
- [ ] Apply the same axis choice in rhwp PDF export if the pixel comparison shows a mismatch.
- [ ] Run focused tests, `make test`, and screen/PDF pixel comparison.
- [ ] Remove the resolved BUG_HANDOFF row and commit `fix: preserve variable font axes`.

### Task 3: rhwp Paragraph and Pagination Fidelity

**Files:**
- Modify: `Engine/crates/hwp-engine-abi/src/layout_tests.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/tests.rs`
- Modify: `build/rhwp/...` at the traced layout sources
- Regenerate: `Vendor/rhwp-layout.patch`
- Modify: `Vendor/README.md`
- Modify: `docs/BUG_HANDOFF.md`

**Interfaces:**
- Consumes: paragraph shape, section/column controls, existing line records, table/object extents.
- Produces: body-confined page layout with correct first-line origin and Hancom-compatible pagination.

- [ ] Add a failing first-section-paragraph test that compares the first line x before and after 20 pt indent.
- [ ] Trace section-control filtering and fix the shared line-origin calculation; run focused and full Rust tests.
- [ ] Add fixture-driven page-count/last-line tests for the line-record-free report and assert Hancom-reference page boundaries.
- [ ] Measure line ascent, descent, leading, and paragraph spacing at each page boundary; change only the source of the proven 2–3 px excess.
- [ ] Add overflow tests for a paragraph, a splittable table, and a non-splittable row; assert every placed rect remains inside the body or continues on the next page.
- [ ] Fix the page-break decision at the responsible rhwp layout node and verify existing line-record documents are byte/layout stable.
- [ ] Add a space-width comparison test using HCR Batang and decide layout versus display-only correction from the Hancom PDF evidence; implement the proven path.
- [ ] Add the synthetic-HWP inline-picture page-count regression and fix only if it reproduces independently of the preceding pagination changes.
- [ ] Regenerate the vendor patch, run `make test`, compare affected pages against reference PDFs, update BUG_HANDOFF, and commit each independent fix.

### Task 4: Selection Across Containers

**Files:**
- Modify: `Engine/crates/hwp-engine-abi/src/editing/geometry.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/commands.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/tests.rs`
- Modify: `App/Workspace/DocumentCanvas.swift`
- Modify: `Tests/DocumentTests.swift`
- Modify: `docs/BUG_HANDOFF.md`

**Interfaces:**
- Consumes: drag anchor/focus hit targets and container ordering.
- Produces: a validated multi-container selection representation, or explicit boundary clamping where editing cannot be made lossless.

- [ ] Add failing engine and canvas tests dragging body→cell, cell→body, body→header/footer, and across two table cells.
- [ ] Prove which target pairs can be represented by the current edit protocol without ambiguous deletion order.
- [ ] Extend selection ordering/serialization only for representable pairs; keep protected or structurally unsafe pairs clamped.
- [ ] Verify copy, replacement, Backspace, undo, and protected fields for every newly supported pair.
- [ ] Run focused tests and `make test`, update BUG_HANDOFF with any intentionally unsupported structural boundary, and commit `fix: extend drag selection across containers`.

### Task 5: Tooling and Manual Check Closure

**Files:**
- Modify: `Makefile`
- Create if needed: `scripts/compare-pages.sh`
- Modify: `Tests/DocumentTests.swift`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/tests.rs`
- Modify: `docs/BUG_HANDOFF.md`

**Interfaces:**
- Produces: `make fmt-check` and a repeatable page-image comparison command.

- [ ] Add `make fmt-check` targeting tracked Rust sources only; run it first to demonstrate the old root command's generated-workspace failure and then verify the new target succeeds.
- [ ] Add a page comparison helper that renders engine/app output and reports changed pixels against a user-supplied Hancom PDF without storing private documents.
- [ ] Convert each deterministic manual check into an engine or AppKit test: inline-object drag/drop, equation-in-cell, caption typing, object deletion/style preservation, wrapped-line endpoints, line handles, rich copy/paste, header/footer editing and protected fields, numbering, language font, ruler, page outline, document info, and password flows.
- [ ] Build and launch the app; manually exercise only the interactions that cannot be driven reliably and record exact results in BUG_HANDOFF.
- [ ] Run `make fmt-check`, `git diff --check`, `make test`, and `make app`.
- [ ] Remove every proven-resolved item, retain only evidence-backed external interoperability checks, and commit `test: close BUG_HANDOFF manual checks`.

### Task 6: Final Audit and Share

**Files:**
- Inspect: `docs/BUG_HANDOFF.md`, `docs/ROADMAP.md`, all changed files.

**Interfaces:**
- Produces: a clean, tested branch ready on `origin/codex/foundation`.

- [ ] Re-read every BUG_HANDOFF row and checkbox and point each to a passing automated test, manual result, or an explicit unresolved external dependency.
- [ ] Run fresh `make fmt-check`, `git diff --check`, `make test`, and `make app`; inspect full exit codes and failure counts.
- [ ] Review `git diff origin/codex/foundation...HEAD` for private fixtures, generated files, or unrelated changes.
- [ ] Commit any final documentation-only audit update.
- [ ] Ask for action-time confirmation, then push `codex/foundation` through the configured GitHub client and verify the remote commit.
