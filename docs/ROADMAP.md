# HwpStudio 로드맵

목표: 학교·기관 HWP/HWPX 양식을 원본 훼손 없이 편집하는 macOS 네이티브 편집기.
기준점: 로컬 「Hancom Office HWP Viewer」의 화면·동작과 최대한 같게 만든다.

원래 설계(2026-10-04 「텍스트 편집 1단계」 spec/plan)의 원칙을 이어 가되, 순서를 조정했다.
이유는 두 가지다. 매 편집마다 문서 전체를 PDF로 재생성하는 방식은 키 입력 속도를 견디지 못한다.
그리고 rhwp에 이미 HWP/HWPX 저장 API가 있으므로 저장을 마지막까지 미룰 필요가 없다.

## 지켜야 할 원칙

- 원본 파일에는 명시적인 「저장」 전까지 쓰지 않는다. 저장은 원자적으로 하고 원본 백업을 남긴다.
- 화면과 내보내기는 같은 조판 결과를 쓴다.
- 안전성을 확인할 수 없는 대상(컨트롤·필드·제목 표시가 있는 문단, 세로쓰기 셀, 중첩 표, 머리말·꼬리말·각주)은 이유를 보여 주고 읽기 전용으로 둔다. 숨은 컨트롤을 평문으로 바꾸지 않는다.
- 한글 조합 확정·붙여넣기·Enter 각각이 실행 취소 1단위다. Undo/Redo는 내용·커서·조판을 함께 되돌린다.
- 실패한 명령은 롤백한다. 롤백마저 실패하면 세션을 잠그고 마지막 정상 결과를 유지한다.
- 개인 문서는 opt-in 로컬 검사에서만 쓴다. 본문을 로그나 저장소에 남기지 않는다.
- 한컴 완전 일치나 안전 저장을 검증 없이 주장하지 않는다.

## 현재 상태 (0.1.0)

- 읽기 전용 뷰어: 쪽 썸네일, 쪽 이동, 확대/축소, PDF 내보내기, 배치 의심 경고.
- 편집 엔진(UI 미연결): 본문·최상위 표 셀의 Replace/Split/MergePrevious와 Undo/Redo(20단계), 문자소(grapheme) 경계 검증, 보존 검사, 실패 시 롤백, hit-test·커서 좌표. 구역 정의가 들어 있는 첫 문단도 편집할 수 있다.
- `hwp_edit_*` C ABI와 Swift `EditSession`(`App/Editing/`): 실제 fixture로 Swift↔엔진 왕복을 확인했다.
- 배포: SwiftPM, `make dist`로 서명·공증, Finder 파일 연결.

## 단계

### 1. 뷰어 동등성 (한컴 뷰어 기준)
- [x] 인쇄(⌘P)
- [ ] 찾기(⌘F), 폭 맞춤/쪽 맞춤/두 쪽 보기, 최근 문서.
- [ ] 비교 도구: 같은 문서를 한컴 뷰어에서 PDF로 인쇄한 결과와 HwpStudio 출력을 쪽마다 픽셀 비교한다. `layout_probe` 예제를 확장한다.
- [ ] 글꼴 대응표: 함초롬·HY 계열 → 설치된 글꼴. 한컴 글꼴이 시스템에 있으면 그 글꼴을 쓴다(번들·재배포는 하지 않음).

### 2. 쪽 단위 렌더링 (편집의 전제 조건)
- [ ] 문서 전체 PDF 대신 `render_page_pdf_native`/`render_page_svg_native`로 쪽마다 렌더링하고, 바뀐 쪽만 교체한다.
- [ ] 내보내기는 지금처럼 문서 전체 PDF로 한다.
- [ ] 보존 검사(문서 전체 Debug 문자열 비교)는 디버그 빌드와 테스트에서만 실행한다. 릴리스 빌드에서는 구조 요약(표 크기·컨트롤 수·바이너리 해시)만 비교한다.

### 3. 텍스트 편집
- [x] 세션 C ABI: `hwp_edit_open / request / result_* / close`. 요청은 `op` 태그를 단 JSON 봉투로 보내므로, 기능을 추가할 때 C 함수가 늘지 않는다.
- [x] Undo/Redo: `save/restore/discard_snapshot_native`로 최대 20단계. 새 편집이 들어오면 redo를 비운다. dirty는 원본 상태 ID와 비교해 계산한다.
- [x] Swift `EditSession`: 직렬 큐 하나만 세션 핸들에 접근한다.
- [ ] `EditorController`(MainActor): 세션 UUID+revision으로 오래된 응답을 버린다.
- [ ] 선택 영역 사각형: rhwp `get_selection_rects_native`가 `pub(crate)`이므로 `rhwp-layout.patch`에서 공개한다.
- [ ] 좌표(엔진 쪽 hit-test·커서는 완료): PDF pt(하단 원점) ↔ 엔진 96dpi(상단 원점). 회전된 쪽은 편집을 막는다. 엔진의 `hit_test_native`와 `get_cursor_rect_*`를 쓰고, Swift에서 글자 폭을 따로 추정하지 않는다.
- [ ] 입력: `NSTextInputClient` 오버레이. 조합 중인 글자는 UI 상태로만 두고, 확정할 때 명령 하나로 보낸다. UTF-16 ↔ Unicode scalar 변환을 명시적으로 처리한다.
- [ ] 키: ←→ 문자소 단위, ↑↓ hit-test, Home/End, ⌘A(문단), Return=Split, 문단 맨 앞 Backspace=MergePrevious.

### 4. 저장
- [ ] `export_hwp_native`/`export_hwpx_native`로 저장한다. 원래 형식으로 저장할 때는 저장→재파싱→구조 비교를 통과해야 쓴다.
- [ ] 저장하지 않은 변경 보호: 창 닫기·다른 파일 열기·앱 종료를 한 guard가 처리한다. 조합 중인 글자도 포함한다.
- [ ] 자동 복구본(앱 컨테이너에 주기적으로 HWPX 저장).

### 5. 서식과 구조
- [ ] 글자·문단 서식(`apply_char_format_*`, `apply_para_format_*`), 표 행/열(`insert_table_row_native` 등), 그림 삽입.

## 완료를 판단하는 검사

1. 생성한 HWP/HWPX에서 본문과 셀을 편집한 뒤에도 표·그림·편집하지 않은 문단이 그대로다(Rust 테스트).
2. 조합형 한글, ZWJ 이모지, 결합 문자에서 문자 경계가 깨지지 않는다.
3. Undo→Redo 후 텍스트·커서·쪽 수가 같다.
4. 렌더 실패를 주입하면 revision과 문서가 이전 상태 그대로다.
5. 확대율 50/100/200%와 쪽 경계에서 클릭한 위치와 커서가 맞는다.
6. 실제 macOS 한글 입력기로 조합→확정→Undo를 수동 확인한다. 확인하지 않았으면 지원 완료로 보고하지 않는다.
