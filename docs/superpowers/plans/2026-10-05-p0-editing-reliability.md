# P0 Editing Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent queued edits from being omitted by save, make Korean IME selection replacement deterministic, and reject stale Swift/Rust engine combinations.

**Architecture:** Keep the existing MainActor document queue and Rust session queue, but add a thread-safe save barrier registered synchronously whenever document work is enqueued. Centralize IME composition finalization at every selection-changing editor command. Give the JSON/rendering boundary one shared protocol version on each side and reject mismatches before decoding page payloads.

**Tech Stack:** Swift 6, SwiftUI `ReferenceFileDocument`, AppKit `NSTextInputClient`, Swift Testing, Rust, serde, C ABI.

**Spec:** `docs/BUG_HANDOFF.md`

## Global Constraints

- macOS 14 remains the deployment minimum; do not migrate to the macOS 27 async `Document` API.
- HWP and HWPX save/reopen behavior must remain supported.
- Never synchronously wait for a MainActor task from the MainActor.
- Preserve one undo step for one Korean composition.
- Do not log document text or document bytes.

## Review Focus

- A save requested after text, formatting, or object placement must include work already accepted by `HwpDocument`.
- Save after a failed edit must terminate and report the export result rather than leaving a barrier blocked.
- `⌘A`, navigation, delete, paste, newline, and Tab during Korean composition must not reuse the stale marked range.
- An old Swift executable with a new engine, or a new executable with an old engine, must fail with an explicit compatibility diagnostic before interpreting rendering bytes.
- Normal Latin typing, Korean composition undo, and reopening both HWP and HWPX must keep their current behavior.

---

### Task 1: Save barrier for queued document work

**Files:**
- Create: `App/Document/DocumentWorkBarrier.swift`
- Modify: `App/Document/HwpDocument.swift`
- Test: `Tests/DocumentTests.swift`

**Interfaces:**
- Produces: `DocumentWorkBarrier.begin() -> Token`, `DocumentWorkBarrier.waitUntilIdle()`, and idempotent `Token.finish()`.
- `HwpDocument.enqueue` obtains a token before creating its Task and finishes it after work and presentation, including error paths.
- `HwpDocument.snapshot(contentType:)` waits for the barrier off the MainActor before calling `EditSession.export`.

- [ ] **Step 1: Write failing save tests**

Add `immediateSaveIncludesQueuedTyping` and `immediateSaveIncludesQueuedObjectEdit`. Submit an edit and immediately call `snapshot` from a detached task, then reopen and assert the text/object property is present. Add a barrier unit test proving an error/early exit releases its token.

- [ ] **Step 2: Run the focused tests and verify the reopened document lacks the queued change**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter immediateSave`

Expected: FAIL because export can run before the MainActor queue submits the edit to `EditSession`.

- [ ] **Step 3: Implement the thread-safe work barrier**

Use `NSCondition` or an equivalent lock-protected pending count. Register pending work synchronously in `enqueue`; finish with `defer` after `present()`. In snapshot, wait only from a non-MainActor/background caller, then export. If snapshot is invoked on the main thread while work is pending, fail clearly instead of deadlocking or exporting stale data.

- [ ] **Step 4: Run focused save tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter immediateSave`

Expected: PASS for text and object edits.

- [ ] **Step 5: Run all document tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DocumentTests`

Expected: New save tests pass; any pre-existing screen-dependent zoom failure is reported separately.

### Task 2: Korean IME composition and selection ordering

**Files:**
- Modify: `App/Workspace/DocumentCanvas.swift`
- Modify: `App/Document/HwpDocument.swift` only if the editor boundary cannot fully enforce the ordering
- Test: `Tests/DocumentTests.swift`

**Interfaces:**
- Produces: one editor helper that commits active composition before a command changes the selection or edits a range other than the marked range.
- `insertText` remains the only path that commits replacement text supplied by the input method itself.

- [ ] **Step 1: Write the failing `⌘A` replacement test**

Host `DocumentCanvas` in a window, build `안녕하세요` with the final syllable marked, invoke `selectAll`, immediately insert `반갑습니다`, settle, and assert the paragraph is exactly `반갑습니다` plus any fixture suffix outside the selected container. Assert one undo restores the original text.

- [ ] **Step 2: Run the focused test and verify stale marked text wins over the full selection**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter compositionSelectAll`

Expected: FAIL with the old prefix left in the paragraph.

- [ ] **Step 3: Centralize composition finalization before selection-changing commands**

Call the helper before `selectAll`, keyboard motions, page motions, deletion, paste, explicit menu delete, newline, and Tab. Preserve the existing mouse and responder-loss behavior. Queue composition finalization before the subsequent command so rapid input cannot overtake it.

- [ ] **Step 4: Add adjacent IME regression cases**

Add tests for composition followed immediately by arrow movement, delete, paste, newline, and Tab. Assert the marked range is cleared, text lands at the resulting selection, and undo does not split a single composition into several steps.

- [ ] **Step 5: Run IME and document tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter composition`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DocumentTests`

Expected: All IME tests pass; no existing typing/undo regression.

### Task 3: Swift/Rust engine protocol compatibility guard

**Files:**
- Modify: `App/Editing/EditProtocol.swift`
- Modify: `App/Editing/EditSession.swift`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/protocol.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/mod.rs`
- Modify: `Engine/crates/hwp-engine-abi/src/editing/tests.rs`
- Modify: `README.md`
- Test: `Tests/EditSessionTests.swift`

**Interfaces:**
- Produces: `EditProtocolVersion.current` in Swift and `PROTOCOL_VERSION` in Rust, both set to the same integer.
- Every `EditReply` and apply request carries that value; Swift validates the reply before reading the rendering payload.

- [ ] **Step 1: Add failing protocol mismatch tests**

In Rust, assert an apply request with `PROTOCOL_VERSION - 1` is rejected. In Swift, feed an output/reply with a different version into the decoding boundary and assert a compatibility error is thrown before rendering payload parsing.

- [ ] **Step 2: Verify both tests fail for the expected reason**

Run: `cargo test --manifest-path Engine/Cargo.toml --locked -p hwp-engine-abi protocol`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter protocolVersion`

Expected: FAIL because version literals are currently duplicated and reply decoding does not guard compatibility.

- [ ] **Step 3: Add and apply the shared-side constants**

Replace production version literals with each language's constant. Validate Swift `EditReply.version` immediately after JSON decoding and emit an OSLog compatibility message containing only expected/actual versions. Keep malformed input distinct from version mismatch where practical.

- [ ] **Step 4: Document clean pull/build workflow**

Update README to state that `make run` rebuilds the engine and app, and `make test` is the supported clean verification command after pulling engine protocol changes.

- [ ] **Step 5: Rebuild and run the complete suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`

Expected: Rust and Swift suites pass except for explicitly documented pre-existing failures; no ABI-induced cascade.

### Task 4: Correct the screen-dependent zoom assertion and final verification

**Files:**
- Modify: `Tests/DocumentTests.swift`
- Modify: `docs/BUG_HANDOFF.md`

**Interfaces:**
- Produces: a deterministic fit assertion based on finite positive zoom and page containment, not an assumption that fit zoom is below 100%.

- [ ] **Step 1: Change the test to assert actual fit behavior**

Replace `canvas.zoom < 1` with assertions that zoom is finite and positive and the fitted page frame is contained by the viewport within rounding tolerance.

- [ ] **Step 2: Run the focused canvas test**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter canvasDrawsPagesAndCaret`

Expected: PASS on the current display and independently of display scale.

- [ ] **Step 3: Run final verification**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`

Run: `git diff --check`

Expected: All non-opt-in tests pass and the diff has no whitespace errors.

- [ ] **Step 4: Update handoff status and commit**

Mark the three P0 issues and zoom test with verified results in `docs/BUG_HANDOFF.md`. Commit only source, tests, README, and docs; do not add `DerivedData`, `FoundationDerivedData`, `Generated`, or `HwpStudio.xcodeproj`.
