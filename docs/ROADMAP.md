# HwpStudio 로드맵

목표: HWP/HWPX 문서를 원본 훼손 없이 편집하는 macOS 네이티브 편집기.

- **1차 목표: rhwp가 지원하는 기능을 모두 앱에서 쓸 수 있게 한다.** rhwp(`build/rhwp`, `Vendor/rhwp-*.tar.gz` + 패치)에 있는 편집·조회·저장 기능이 기준이다. rhwp에 없는 기능(하이퍼링크 넣기, 메모, 변경 내용 추적 등)은 1차에서 다루지 않는다.
- 2차 목표: rhwp에 없는 웹 한글·로컬 한글 기능을 엔진에 더해 데스크톱 한글 수준으로 끌어올린다.
- 화면 기준: 조판 결과는 로컬 「Hancom Office HWP Viewer」와 최대한 같게 한다. UI는 Apple HIG를 따르고, 앱 안에 설명 문구를 넣지 않는다.
- 용어: 모든 메뉴·대화상자 이름은 웹 한글(저장해 둔 편집 화면 htm, main.js, 탭 스크린샷)에서 그대로 가져온다. 새 용어를 만들지 않는다. macOS 표준 명령 이름(프린트…, PDF로 내보내기… 등)은 쓴다. 웹 한글에서 이름을 찾지 못한 기능은 이름을 확인할 때까지 보류한다(아래 「이름 확인이 필요한 기능」).

## 지켜야 할 원칙

- 원본 파일에는 명시적인 「저장」 전까지 쓰지 않는다. 저장은 원자적으로 하고, 저장 전에 재파싱으로 검증한다.
- 화면과 내보내기는 같은 조판 결과를 쓴다.
- 안전성을 확인할 수 없는 대상(필드·제목 표시가 있는 문단, 세로쓰기 셀, 중첩 표·표 안 글상자, 줄 안 개체가 있는 머리말·꼬리말 문단)은 읽기 전용으로 둔다. 숨은 컨트롤을 평문으로 바꾸지 않는다. 읽기 전용을 풀 때는 그 대상의 보존 검사를 먼저 만든다.
- 조합 중인 글자는 문서에 바로 넣어 문서 글꼴로 보인다. 조합 하나, 붙이기, Enter 각각이 실행 취소 1단위다. 엔진이 앞 편집을 처리하는 동안 이어 친 글자는 한 편집(1단위)으로 묶인다. Undo/Redo는 내용·커서·조판을 함께 되돌린다.
- 빨라야 한다. 키 입력 한 번에 바뀐 쪽만 다시 그린다. 지연과 깜빡임은 버그로 다룬다.
- 실패한 명령은 롤백한다. 롤백마저 실패하면 세션을 잠그고 마지막 정상 결과를 유지한다.
- 개인 문서는 opt-in 로컬 검사에서만 쓴다. 본문을 로그나 저장소에 남기지 않는다.
- 단축키는 macOS 관례에 맞추고(Ctrl → ⌘, 글자 입력과 겹치는 ⌥ 단독 → ⌥⌘), 한글 고유의 연속 단축키(Ctrl+N+T 같은 것)는 쓰지 않는다.

## 구조

- 앱(`App/`): SwiftUI `DocumentGroup` 문서 앱. `HwpDocument`가 편집·이동을 제출 순서대로 하나씩 처리하고, 끝날 때마다 `Presentation`(바뀐 쪽, 커서, 선택 영역, 선택 개체)을 한 번에 내보낸다. SwiftUI는 키 입력마다 바뀌지 않는 `EditingContext`·`format`만 관찰한다.
- 캔버스(`DocumentCanvas.swift`): 쪽을 동기적으로 그리는 자체 뷰(`NSTextInputClient`). 클릭·끌기·키 입력·한글 조합, 개체 선택·크기 조절·옮기기, 표 테두리 끌기, 빠른 메뉴.
- 엔진(`Engine/`): `hwp_edit_*` C ABI 하나. 요청·응답은 JSON(`editing/protocol.rs` ↔ `App/Editing/EditProtocol.swift`), 쪽은 이진 표시 목록(`display.rs` ↔ `PageDisplay.swift`). 문서 열기도 편집 세션으로 한다.
- 렌더링: 편집마다 바뀐 쪽만 SVG로 그려 해시로 비교하고, 바뀐 쪽은 표시 목록으로 만들어 Core Graphics/Core Text로 바로 그린다. 표시 목록이 다루지 못하는 쪽(화살표 marker 등)만 PDF로 받는다. 4쪽 보고서에서 키 입력 한 번이 앱 왕복 24ms, 새 쪽 그리기 3ms다. 프린트·PDF 내보내기는 엔진이 전체 PDF를 새로 만든다.
- 창 구성은 웹 한글과 같은 순서다: macOS 메뉴 막대(파일·편집·보기·입력·서식·쪽·표), 도구 상자(작은 탭 기본·편집·보기·입력·서식·쪽·표가 큰 아이콘 줄을 바꾼다), 서식 도구 상자, 사이드바(쪽 미리 보기) + 쪽, 상태 표시줄(쪽, 확대/축소).
- 안전장치: 문자소 경계 검증, 실패 시 롤백, 저장 전 재파싱 검증. 명령마다 바뀌어야 할 곳만 바뀌는지 보는 보존 검사(`preservation.rs`)는 테스트 빌드에서만 돈다. 로컬 문서 47개에서 구조 명령 156회 거부 0(`structure_edits_on_corpus`, opt-in).

## 단계

rhwp 함수 이름은 `DocumentCore`(대부분 `*_native`) 기준이다. 「wasm」은 `wasm_api.rs`의 `HwpDocument`에만 있는 기능으로, `JsValue`를 돌려주는 경로는 네이티브에서 쓸 수 없으므로 내부 함수를 쓰거나 패치로 `DocumentCore`에 옮긴다.

### 1. 편집 범위 넓히기 (읽기 전용 줄이기)

키 입력이 닿는 곳을 늘린다. 각각 보존 검사를 먼저 만든다.

- [ ] 머리말·꼬리말 안 쪽 번호 넣기, 그림 속성: `insert_field_in_hf`, `get/set_header_footer_picture_properties`. 빈 머리말·꼬리말에는 아직 들어갈 수 없다.
- [ ] 각주·머리말 안 개체, 셀 안 도형, 중첩 표 셀 안 개체 선택, 중첩 표 셀 편집, 그리기 개체 캡션 글자: `get/set_cell_shape_properties_by_path`, `copy_selection_in_cell_by_path`. 칸 문단에 수식이 둘 이상이면 rhwp의 칸 수식 함수가 첫 수식만 찾는다. 도형의 칸 0은 글상자라 캡션을 가리킬 경로가 없다.
- [ ] 각주 안 수식 고치기: rhwp 쪽 배치가 미주 수식에만 위치(`noteRef`)를 준다. 주석 안 수식은 속성만 바꾸고 옮기기·지우기·복사는 아직 안 된다.
- [ ] 여러 문단 선택 지우기에서 사이 문단의 컨트롤 처리: `capture_delete_range`/`restore_delete_fragment`, `delete_range_native`.

### 2. 웹 한글 메뉴의 남은 항목 중 rhwp가 지원하는 것

이름은 웹 한글 메뉴에서 확인한 그대로다.

- 파일
  - [ ] 문서 정보…: `get_document_info`(읽기).
  - [ ] 암호가 걸린 문서 열기·저장: `from_bytes_with_password`, `export_hwpx_native_with_password`, `export_hwp_with_adapter_with_password`. 지금은 `PasswordRequired`로 열기를 거부한다.
  - [ ] 배포용 문서 열기 후 편집: `convert_to_editable`.
- 편집
  - [ ] 조판 부호 지우기: `delete_control_native`.
- 보기
  - [ ] 쪽 윤곽: 앱만으로 가능.
  - [ ] 문서 창 › 눈금자의 들여쓰기 표시와 여백·들여쓰기 끌기: 지금은 보이는 쪽을 0으로 하고 본문 여백만 표시한다.
- 입력
  - [ ] 책갈피…(넣기·고치기·지우기, 책갈피로 가기): `add_bookmark_native`, `rename_bookmark_native`, `delete_bookmark_native`, `get_bookmarks_native`.
  - [ ] 필드 입력…, 누름틀 고치기·누름틀 지우기·필드 삭제: wasm `insert_click_here_field_at`, `update_click_here_props`, `remove_field_at`, `get_field_info_at`, `set_field_value`.
  - [ ] 차트 데이터 고치기: `list_charts_native`, `get/set_chart_data_native`.
  - [ ] 문서 안 양식 개체(누름 단추·선택 상자 등) 값 바꾸기: `get_form_object_at_native`, `set_form_value_native`.
- 서식
  - [ ] 표 칸·주석 안 문단의 시작 번호 방식: `set_numbering_restart_native`는 본문 문단만 받는다.
  - [ ] 스타일…(F6) 대화상자: wasm `get_style_list`, `get_style_detail`, `update_style`, `update_style_shapes`, `create_style`, `delete_style`.
  - [ ] 개체 속성 › 선·테두리·배경 탭: `set_shape_properties_native`, `set_picture_properties_native`의 선·채우기 필드. 캡션의 「한 줄로 입력」은 rhwp에 없다.
  - [ ] 개체 속성 › 고정값·본문 위치.
- 쪽
  - [ ] 새 번호로 시작…: `insert_new_number_native`.
  - [ ] 현재 쪽만 감추기…(머리말·꼬리말 등): `get/set_page_hide_native`, `toggle_hide_header_footer_native`.
  - [ ] 단 › 왼쪽·오른쪽: 두 단의 너비 비율을 한글에서 확인해야 한다.
  - [ ] 다단 설정 나누기: rhwp는 구역의 줄을 모두 첫 단 정의의 너비로 나누므로, 단 정의가 둘 이상인 구역의 조판부터 고쳐야 한다. 지금은 단 정의가 하나인 구역에서만 「단」을 바꾼다.
- 표
  - [ ] 셀 테두리/배경 › 각 셀마다 적용…, 하나의 셀처럼 적용…: `apply_cell_border_fill_ids_native`, `set_cell_zone_properties`.
  - [ ] 표 테두리 끌기의 나머지(바깥 왼쪽·위 테두리, 셀 안의 표): `resize_table_cells`, `move_table_offset`.
  - [ ] 블록 계산식 결과의 자동 다시 계산: 지금은 값으로 넣는다. 계산식 필드로 넣어야 한다.

### 3. 이름 확인이 필요한 기능

rhwp는 지원하지만 웹 한글에서 이름을 찾지 못했다. 사용자가 이름(로컬 한글 화면 등)을 확인해 주면 2단계와 같은 방식으로 넣는다.

| rhwp 함수 | 하는 일 |
|---|---|
| `group_shapes_native` | 여러 개체를 하나로 묶기(「개체 풀기」의 반대) |
| `split_table_native`, `merge_table_with_next_native` | 표를 두 개로 나누기, 다음 표와 붙이기 |
| `transpose_table_cells_in_place_native`, `copy/paste_table_cells_transposed_native` | 표의 줄과 칸 바꾸기 |
| `fit_table_to_page_native` | 표 너비를 본문 폭에 맞추기 |
| `assign_picture_image_native` | 그림 파일만 바꾸기(크기·위치 유지) |
| `get/set_page_border_fill_native` | 쪽 테두리·배경 |
| `get/set_section_def_native`, `set_section_def_all_native` | 구역 설정(쪽 번호 시작, 감추기 등) |
| `get/apply_endnote_shape_native`, `get_footnote_info_native` | 각주·미주 번호 모양·구분선 |
| `get_outline_navigation_native` | 개요(제목) 목록으로 문서 안 이동 |
| `export_hml_native`, `extract_page_text/markdown_native` | 다른 형식으로 내보내기 |

### 4. 화면 성능

- [ ] 남은 엔진 시간(약 20ms): 편집 쪽과 다음 쪽의 SVG(레이아웃 포함), 표시 목록의 XML 파싱. 다음 후보는 rhwp 렌더 트리(`get_page_layer_tree_native`)에서 표시 목록을 바로 만드는 것(SVG 문자열과 XML 파싱 생략).
- 측정: 엔진 `HWP_BENCH=<문서> cargo test --release bench_typing -- --ignored --nocapture`, 앱 `HWP_BENCH=<문서> swift test -c release --filter benchHostedTyping`, 화면 확인 `HWP_SNAPSHOT_DIR=<폴더> swift test --filter snapshots`.

### 5. 검증과 조판 동등성

수동 점검과 남은 문제는 `docs/BUG_HANDOFF.md`.

- [ ] 글자·문단 테두리와 배경이 쪽에 그려지는 모양을 한컴 뷰어와 비교한다(저장·다시 읽기는 테스트함).
- [ ] 비교 도구: 한컴 뷰어에서 PDF로 인쇄한 결과와 쪽마다 픽셀 비교한다.
- [ ] 글꼴 대응: 함초롬·HY 계열을 설치된 글꼴로 대응시킨다. 한컴 글꼴이 시스템에 있으면 그 글꼴을 쓴다(번들·재배포는 하지 않음).
- [ ] 자동 저장 정책: 저장 검증이 충분해질 때까지는 macOS 버전으로 이전 판을 보존한다.

### 6. 2차: rhwp에 없는 기능

엔진에 새로 만들어야 한다: 하이퍼링크…(넣기·고치기·지우기·열기), 메모, 문단 띠, 웹 동영상, 검토 › 변경 내용 추적, 1,000 단위 구분 쉼표(자릿점 넣기·빼기), 격자 설정, 편집 용지의 줄 격자, 문단 모양의 최소 공백, 빠른 교정·맞춤법(macOS 텍스트 서비스로).

## 완료를 판단하는 검사

1. 생성한 HWP/HWPX에서 본문과 셀을 편집한 뒤에도 표·그림·편집하지 않은 문단이 그대로다(Rust 테스트, 보존 검사).
2. 조합형 한글, ZWJ 이모지, 결합 문자에서 문자 경계가 깨지지 않는다.
3. Undo→Redo 후 텍스트·커서·쪽 수가 같다. 저장한 파일을 다시 열면 텍스트가 같다.
4. 렌더 실패를 주입하면 revision과 문서가 이전 상태 그대로다.
5. 확대율 50/100/200%와 쪽 경계에서 클릭한 위치와 커서가 맞는다.
6. 실제 macOS 한글 입력기로 조합→확정→Undo를 수동 확인한다. 확인하지 않았으면 지원 완료로 보고하지 않는다.
7. 새 기능마다: 엔진 테스트(명령·저장·다시 열기), 앱 테스트(메뉴·도구 상자에서 실행), 웹 한글 용어 대조.
