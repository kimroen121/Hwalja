# HwpStudio Text Editing Stage One Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for native execution, or superpowers:subagent-driven-development only if the user selects that method. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 본문·최상위 표 셀의 직접 편집, 한글 입력, 실행 취소 및 수정 후 PDF를 구현한다.
**Architecture:** Rust의 장수명 세션이 문서·원자적 명령·히스토리를 소유한다. Swift의 직렬 작업 경로가 C ABI를 호출하고, AppKit 입력 계층은 PDFKit 위에 커서·선택·조합 문자열을 표시한다. PDF·좌표·경고를 같은 revision으로 교체한다.
**Tech Stack:** 기존 Swift 6, SwiftUI, AppKit, PDFKit, Rust, pinned rhwp. macOS 14 최소 버전을 유지한다.
**Spec:** `docs/superpowers/specs/2026-10-04-text-editing-stage-one-design.md` — 사용자 승인됨.

## Global Constraints

- 원본 HWP/HWPX 파일·바이트는 불변. HWP 저장·자동 복구는 이번 범위 밖이다.
- 기본은 읽기 전용. 실험 편집 진입 시 강제 종료에 따른 미저장 변경 손실을 고지한다.
- 일반 본문·최상위 표 셀의 컨트롤 없는 문단만 편집한다. 중첩 표·필드·그림·수식·주석·머리말·꼬리말은 차단한다.
- 같은 문단 선택과 같은 컨테이너 안의 분할·병합만 지원한다. 셀을 넘는 수정은 금지한다.
- 한글 조합 확정·붙여넣기·Enter 각각 한 번이 원자적 명령이다.
- undo+redo 합계 최대 20개 상태. 원본·현재 상태는 별도이며 임시 롤백은 명령 종료 시 해제한다.
- 기존 입력 64 MiB·결과 1,000쪽 제한을 유지한다.
- 조판 중 추가 확정 편집·내보내기를 막는다. 매 키마다 원본 재파싱·파일 저장을 하지 않는다.
- 기존 읽기·경고·원본 덮어쓰기 방지 검사와 화면/PDF 동일성을 유지한다.
- 한컴 완전 일치·안전 저장 완성이라고 표시하지 않는다.
- 개인 문서는 로컬 opt-in 검사만 수행하고 본문·파일을 로그나 저장소에 넣지 않는다.
- 작업 전 dirty tree를 기록하고 기존 수정은 버리거나 무관하게 커밋하지 않는다.

## Review Focus

- ZWJ 이모지·조합형 한글·UTF-16 중간 위치: 잘못된 범위 거부, 한 문자 단위 삭제 (Task 1, 5).
- 새 문서 열기 후 도착한 이전 비동기 응답: 새 문서를 덮어쓰지 않음 (Task 3).
- 분할로 인덱스가 이동한 다음 그림 문단: 컨트롤·이미지 데이터 보존 (Task 1).
- Undo/PDF 생성 실패: 이전 문서·PDF·커서 유지 또는 안전한 세션 잠금 (Task 2).
- 조합 중 창 닫기·파일 열기·앱 종료: 조합과 변경을 조용히 버리지 않음 (Task 6).

## 파일 구조

Rust: `Engine/crates/hwp-engine-abi/src/editing/`에
`mod.rs`(세션), `protocol.rs`(DTO), `commands.rs`(입력),
`preservation.rs`(보존 검사), `history.rs`(상태 수명),
`ffi.rs`(ABI), `tests.rs`(생성 문서 검사)를 추가한다.
기존 `src/lib.rs`, `Cargo.toml`, `Generated/HwpEngineABI.h`는 연결에 필요한 부분만 변경한다.

Swift: `App/Editing/`에 `EditProtocol.swift`, `EditSession.swift`,
`EditorController.swift`, `EditorCoordinates.swift`, `TextIndexMap.swift`,
`EditorInputView.swift`, `EditorCanvas.swift`, `UnsavedChangesGuard.swift`를 추가한다.
기존 `WorkspaceView.swift`, `SnapshotPDFView.swift`, `HwpStudioApp.swift`는 UI 연결에 사용한다.
검사는 `Tests/AppTests/EditingTests.swift`, `EditingInputTests.swift`에 둔다.
새 파일 추가 후 기존 XcodeGen 설정으로 프로젝트를 재생성한다.

## 공유 인터페이스

Rust serde JSON과 Swift Codable의 필드 이름을 일치시킨다. UTF-8 JSON, version=1.
revision은 세션 내 0부터 시작해 성공한 편집·Undo·Redo마다 증가한다.
Undo는 내용을 복원하지만 revision 번호를 과거로 되돌리지 않는다.

- `EditTarget { section: u32, paragraph: u32, cell: Option<CellTarget> }`
- `CellTarget { control: u32, cell: u32, paragraph: u32 }` — 최상위 표 한 단계.
- `EditPosition { target: EditTarget, scalar: u32 }` — scalar는 Rust char 인덱스.
- `EditSelection { anchor: EditPosition, focus: EditPosition }` — 같은 target만 허용.
- `EditRequest { version: u32, revision: u64, command: EditCommand }`
- `EditCommand`: Replace(selection, text), Split(position), MergePrevious(position), Undo, Redo.
- `EditReply { version, revision, selection, pageCount, warnings, canUndo, canRedo, dirty, locked }`
- `ParagraphInfo { target, text, editable, reason }`
- `PageRect { page: u32, x: f64, y: f64, width: f64, height: f64 }` — 96dpi, 상단 원점.
- `GeometryReply { revision, selection, caret: PageRect, selectionRects: Vec<PageRect> }`
- `EditError`: InvalidInput, StaleRevision, UnsupportedTarget, InvalidBoundary, ResourceLimit, RenderFailed, Locked.

Rust:
`EditSession::open(bytes: &[u8]) -> Result<Self, EditError>`;
`apply(&mut self, request: EditRequest) -> Result<EditReply, EditError>`;
`paragraph(&self, target: &EditTarget) -> Result<ParagraphInfo, EditError>`;
`hit_test(&self, revision: u64, page: u32, x: f64, y: f64) -> Result<EditPosition, EditError>`;
`geometry(&self, revision: u64, selection: &EditSelection) -> Result<GeometryReply, EditError>`.
읽기·쓰기 모두 같은 직렬 경로로 접근한다. PDF는 성공 응답과 함께 소유 복사본으로 전달한다.

## Task 1: 원자적 텍스트 명령과 보존 계약

**Files:** Rust protocol/mod/commands/preservation/tests, 기존 Cargo.toml/lib.rs.
**Consumes:** 원본 bytes, upstream 본문·셀 입력 API.
**Produces:** 위 EditSession 및 Replace/Split/MergePrevious. Undo/Redo는 Task 2 전까지 거부한다.

- [ ] 생성 fixture helper `plain_document(format, with_table)`와 실패할 검사를 먼저 작성한다.
  `replace_preserves_other_content`: 본문·셀 수정 후 원본 bytes, 표 구조, 이미지, 미편집 문단이 이전과 같다.
  `rejects_unsupported_target`: 중첩 표·컨트롤 문단·셀을 넘는 범위는 오류이고 revision==0이다.
  `rejects_invalid_boundary`: "가👨‍👩‍👧‍👦é"의 문자 묶음 중간 범위를 거부한다.
  `split_merge_preserves_following_control`: 분할→병합 후 텍스트·서식·뒤의 그림 참조가 같다.
- [ ] `cargo test --manifest-path Engine/Cargo.toml --locked editing::tests`를 실행해 미구현으로 실패함을 확인한다.
- [ ] 공유 인터페이스를 구현한다. serde/serde_json/unicode-segmentation은 현재 lock의 사용 가능 버전을 확인해 직접 의존성으로 선언한다.
  문단 전체를 평문으로 갈아끼우지 않고 범위 편집을 사용한다. 모든 대상·문자 경계를 수정 전에 검증한다.
  Split은 기존 문단 스타일을 이어받고 Merge는 두 문단 모두 컨트롤이 없는지 검사한다.
  여러 줄 붙여넣기는 CRLF/CR을 LF로 정규화하고 여러 분할을 하나의 Replace 트랜잭션으로 처리한다.
- [ ] preservation은 허용된 변경 문단 외의 문단 순서·스타일·표 크기·병합·컨트롤·binary data를 비교한다.
  저장→재파싱을 보존 검사 대신 쓰지 않는다. 안전성을 확인할 수 없는 대상은 읽기 전용으로 둔다.
- [ ] Task 검사와 Rust 전체 suite 0실패 확인 후 관련 파일만 커밋한다.

## Task 2: 트랜잭션·Undo/Redo·출력 일관성

**Files:** Rust history/mod/tests, 기존 layout_audit 호출.
**Consumes:** Task 1 세션, upstream save/restore/discard snapshot.
**Produces:** 모든 EditCommand, 성공 revision에 연결된 PDF·커서·경고.

- [ ] 실패할 검사:
  `undo_redo_restores_state`: edit→undo→redo의 내용·커서 복원, revision==0→1→2→3.
  `failed_render_rolls_back`: test-only 렌더 실패 주입 시 PDF·내용·revision·history 불변.
  `failed_restore_locks_session`: 복원 실패 시 locked=true, 추가 편집 거부, 마지막 PDF 조회 가능.
  `history_limit_and_redo_invalidation`: 25회 수정 후 history 합계<=20; undo 후 새 수정 시 canRedo=false.
- [ ] Task 1과 같은 Rust 명령으로 기대한 실패를 확인한다.
- [ ] snapshot→명령→보존 검사→재조판→배치 검사→PDF 순서로 처리하고 마지막에만 publish한다.
  성공·실패 양쪽에서 임시 스냅샷을 해제한다. Undo/Redo에도 롤백을 둔다.
  1,000쪽 초과는 롤백하고, 배치 경고는 경고 상태와 함께 반환한다.
  dirty는 원본 상태와의 대응 ID로 계산해 원본으로 Undo하면 false가 된다.
- [ ] 전체 검사 실행, 큰 생성 문서에서 20개 상태의 메모리 사용을 측정한다.
  PDF 메타데이터 차이와 실제 조판 차이는 구분해서 비교한다. 관련 파일만 커밋한다.

## Task 3: 소유권이 명확한 ABI와 Swift 직렬 세션

**Files:** Rust ffi/protocol/tests/lib.rs, Generated header, EditProtocol.swift, EditSession.swift,
EditorController.swift, EditingTests.swift.
**Consumes:** Task 2 세션.
**Produces:** @MainActor ObservableObject `EditorController`의 snapshot/reply/selection/busy/error,
`open(original: Data) async throws`, `send(_ command: EditCommand) async`,
`select(_ selection: EditSelection) async`, `close() async`.

- [ ] ABI 수명·null·잘못된 UTF-8·알 수 없는 version 검사를 작성한다.
  Swift `testStaleSessionReplyIsIgnored`, `testFailedOpenKeepsCurrentDocument`,
  `testSessionCloseDoesNotRaceRender`도 먼저 실패시킨다.
- [ ] C ABI를 구현한다:
  `hwp_edit_open(const uint8_t*, size_t) -> HwpEditOpenResult`;
  `hwp_edit_request(HwpEditSession*, const uint8_t*, size_t) -> HwpEditResult*`;
  result의 JSON/PDF pointer·length getters, `hwp_edit_result_free`, `hwp_edit_close`.
  query는 JSON envelope의 paragraph/hit_test/geometry로 분기한다.
  result는 session과 독립된 소유 복사본이다. status/message와 typed payload를 반환한다.
  요청 최대 1 MiB, null/length/version을 검사하고 기존 panic 경계 패턴을 따른다.
- [ ] Swift EditSession은 private serial DispatchQueue에서만 raw handle에 접근한다.
  @unchecked Sendable이 필요하면 confinement 근거를 주석과 race 검사로 고정한다.
  MainActor에는 소유 Data/Codable 값만 반환한다. 세션 UUID+revision이 지난 응답은 버린다.
- [ ] XcodeGen 재생성 후 C ABI smoke·Rust 전체·Xcode 전체 검사를 통과시키고 관련 파일만 커밋한다.

## Task 4: 문서 위치·커서·선택 좌표

**Files:** Rust mod/protocol/tests, EditorCoordinates.swift, TextIndexMap.swift,
EditorCanvas.swift, EditingTests.swift, SnapshotPDFView.swift.
**Consumes:** paragraph/hit_test/geometry, 기존 PDFWorkspaceState.
**Produces:** `EditorCoordinates.enginePoint(pdfPoint: CGPoint, pageHeight: CGFloat) -> CGPoint` 및 역변환,
`TextIndexMap.scalarRange(forUTF16: NSRange) throws -> Range<Int>`,
`utf16Range(forScalar: Range<Int>) throws -> NSRange`, 편집 overlay.

- [ ] 실패할 검사:
  `testCoordinateRoundTrip`: 왕복 오차<0.01pt, 확대율50/100/200%와 스크롤 후 같은 문서 위치.
  `testUnicodeBoundaryMap`: 한글·ZWJ·결합 문자 왕복 일치, 중간 경계는 throw.
  `testSelectionAcrossPageButNotCell`: 같은 문단의 여러 쪽 선택은 허용, 다른 셀은 거부.
- [ ] Rust·Xcode 해당 검사가 기대한 이유로 실패함을 확인한다.
- [ ] pt→96dpi는 x*4/3, y=(pageHeight-y)*4/3. 화면·스크롤·확대는 PDFView.convert로 처리해 중복 적용하지 않는다.
  rotation!=0이면 편집 거부. Swift에서 글자 폭을 다시 추정하지 않고 엔진 좌표를 사용한다.
  upstream hit-test 결과를 어댑터 안에서 정규화하고 최상위 본문·한 단계 셀만 허용한다.
- [ ] 편집 모드에서만 overlay가 클릭·drag를 받는다. 읽기 모드에서는 PDFKit에 넘긴다.
  SwiftUI body/updateNSView 안에서 Published 상태를 동기 변경하지 않는다.
  PDF 교체 후 같은 revision의 커서로 이동하고 확대율을 유지한다.
- [ ] 전체 검사와 실제 창의 두 확대율·두 페이지를 확인하고 관련 파일만 커밋한다.

## Task 5: 한글 입력과 편집 조작

**Files:** EditorInputView.swift, TextIndexMap.swift, EditorController.swift, EditingInputTests.swift.
**Consumes:** Task 3 controller, Task 4 선택·좌표.
**Produces:** `EditorInputView: NSView, NSTextInputClient`, 확정 시 EditCommand.

- [ ] 실패할 검사:
  `testMarkedTextCommitsOnce`: 조합 갱신은 명령0개, insertText 후1개.
  `testMarkedTextCancelRestoresSelection`: Escape 후 원문·선택 불변.
  `testBackspaceDeletesOneGrapheme`: ZWJ 이모지 전체를 한 번에 삭제.
  `testMultilinePasteIsOneUndo`: CRLF 붙여넣기를 Undo 한 번으로 복원.
  `testCompositionBeforeUndoAndExport`: 조합을 남겨 둔 채 예전 PDF를 내보내지 않음.
- [ ] Xcode 검사로 기대한 실패를 확인한다.
- [ ] setMarkedText/insertText/unmarkText/markedRange/selectedRange/attributedSubstring/
  firstRect/characterIndex/validAttributes/doCommand를 구현한다.
  marked state는 로컬이고 확정 시만 전송한다. 후보창은 엔진 커서를 화면 좌표로 변환해 배치한다.
  busy일 때 대기 상태를 알리고 기존 조합 데이터를 버리지 않는다.
- [ ] 좌우는 grapheme, 위아래는 현재x와 엔진 hit-test로 이동한다. Shift는 anchor를 유지한다.
  Home/End는 문단 끝, Command+A는 현재 문단, Return은 Split, 문단 첫 Backspace는 MergePrevious.
  삭제·선택 교체·평문 붙여넣기는 Replace이며 미지원 문단 간 선택은 거부한다.
- [ ] 자동 전체 검사 후 실제 macOS 한글 IME로 조합→확정→Undo→Redo,
  후보창·커서·포커스 이동을 확인한다. IME 미확인이면 지원 완료로 보고하지 않는다. 관련 파일만 커밋한다.

## Task 6: 실험 편집 모드·종료 보호·최종 전달

**Files:** WorkspaceView.swift, HwpStudioApp.swift, UnsavedChangesGuard.swift,
DocumentSnapshot.swift, EditingTests.swift, outputs/implementation-status.md.
**Consumes:** controller/canvas, 기존 snapshot.export 원본 보호.
**Produces:** 실험 편집 전환, Undo/Redo, 변경 표시, 최신 PDF 출력, 안전한 close/open/quit.

- [ ] `testDirtyOpenAndCloseCanCancel`, `testQuitChecksAllWindows`,
  `testExportUsesCommittedRevision`, `testExportNeverWritesOriginal`을 먼저 실패시킨다.
  조합 중 close/open/quit도 같은 보호 경로를 통과하는지 검사한다.
- [ ] 문구는 「실험 편집 · HWP 저장/자동 복구 미지원」,
  「강제 종료하면 수정 내용이 사라질 수 있습니다. 원본은 변경하지 않습니다.」를 사용한다.
  종료 시 「취소」「변경 버리기」를 제시한다. PDF를 편집 복구본이라고 부르지 않는다.
  하나의 guard가 파일 열기·창 닫기·앱 종료 전체를 처리한다.
  작업 중 종료를 미루고, 변경 버리기를 선택하면 세션을 한 번만 닫는다.
- [ ] 내보내기는 IME 확정→명령 완료→최신 revision 고정 후 기존 경고 확인과 atomic write를 사용한다.
  DocumentSnapshot의 original/sourceURL은 유지하고 pdf/pageCount/warnings만 갱신한다.
- [ ] 생성 문서 전체 검사, 기존 private report 검사, 제공 보고서의 안전한 문단 edit→undo를 로컬 확인한다.
  원본 hash, 표·그림 보존, 최신 PDF 전체 쪽, 읽기·미리보기·확대 동작을 검증한다.
- [ ] 전체 검사와 한 차례 제한된 코드 리뷰 후 기존 앱을 work의 새 고유 이름으로 백업하고 새 앱을 outputs에 배치한다.
  codesign 검사·빌드/배포 binary hash 일치를 확인한다. 구현·미지원 상태를 진행 문서에 나누어 기록하고 관련 파일만 커밋한다.

## 실행 환경과 검증 명령

실행 시작 시 worktree 스킬로 기존 작업 공간 재사용/격리를 결정하되 미커밋된 정상 동작 수정이 누락되지 않게 한다.
아래는 workspace root 기준이다. Rust·Cargo 전용 경로와 Xcode를 명령 단위로 지정한다.

```sh
bash HwpStudio/scripts/prepare-engine.sh
RUSTUP_HOME="$PWD/work/rustup" CARGO_HOME="$PWD/work/cargo" "$PWD/work/cargo/bin/cargo" test --offline --locked --manifest-path HwpStudio/Engine/Cargo.toml --workspace
PATH="$PWD/work/cargo/bin:$PATH" RUSTUP_HOME="$PWD/work/rustup" CARGO_HOME="$PWD/work/cargo" HWP_ENGINE_TARGETS=aarch64-apple-darwin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project HwpStudio/HwpStudio.xcodeproj -scheme HwpStudio -destination 'platform=macOS,arch=arm64' -derivedDataPath HwpStudio/FoundationDerivedData -quiet
```

의존성 추가 시에만 lock을 갱신하고 이후 --locked로 검사한다. 오프라인 의존성이 없으면 조용히 다른 설계로 바꾸지 않는다.
Task 안의 짧은 cargo 명령은 HwpStudio 디렉터리와 같은 환경 변수 설정을 전제한다.
새 Swift 파일은 기존 로컬 XcodeGen으로 프로젝트를 재생성한 뒤 검사한다.
xcresult의 failedTests=0 및 실행 개수를 확인하며 컴파일만으로 검사 통과를 주장하지 않는다.
기존 수정과 겹치는 파일을 커밋할 때는 포함되는 기존 차이를 기록하고 무관한 변경을 stage하지 않는다.

## 자체 검토와 실행 방식

설계 A~E를 Task 1~6에 배분했고 IME·상태20개·원본 보호·종료 guard·미지원 대상·revision·실문서 검사를 연결했다.
편집 기능 완료와 기존 한컴 배치 차이 해결은 별도로 보고한다.
추천은 이 세션에서 주 에이전트가 순서대로 구현하는 Native 방식이다.
6개 작업이 서로 의존하므로 별도 구현 에이전트를 반복 호출하는 것보다 문맥을 재사용해 크레딧을 아낄 수 있다.
계획 검토와 실행 방식 확인 전에는 제품 코드를 구현하지 않는다.
