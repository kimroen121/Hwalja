# 기능 목록

한컴오피스 2024 한/글 도움말(<https://help.hancom.com/hoffice130/ko-KR/Hwp/>) 목차의 기능을 빠짐없이 옮긴 표다. 순서와 이름은 도움말 목차 그대로다. 계획은 `ROADMAP.md`, 일하는 방식은 `CONTRIBUTING.md`.

- 도움말 경로는 위 주소 뒤에 붙는다. `scripts/hancom-help.py`를 돌리면 `build/hancom-help/`에 목차(`toc.md`), 쪽마다 글(`pages/`), 그림(`img/`)이 생긴다. 아래 표에는 목차의 두 단계까지만 적었다. 그 아래 단계(대화 상자의 탭, 세부 기능)는 그 기능을 만들 때 도움말에서 하나씩 확인한다.
- 상태
  - ● 됨: 도움말 동작대로 쓸 수 있다.
  - ◐ 일부: 메모에 된 것과 안 된 것을 적었다.
  - ○ rhwp에 있음: 엔진(rhwp)에 함수가 있어 앱에 연결하면 된다.
  - △ 엔진 작업: rhwp에 없거나 고쳐야 한다. 앱만으로 되는 일이면 메모에 적었다.
  - — 범위 밖: Windows 전용, 한컴 서비스, macOS 기능으로 대신하는 것. 메모에 이유를 적었다.
- 상태는 2026-10-08에 코드, 지난 화면 점검 기록, 2024 대화 상자 탭 구성과 대조해 매겼고, 2026-10-09에 rhwp 0.8.7의 공개 함수와 다시 대조했다. ○의 메모에 쓸 rhwp 함수를 적었다. rhwp에 있는 기능은 앱에서 따로 만들지 않고 그 함수를 쓴다.
- 기능을 끝내면 상태를 바꾸고, 메모에서 끝난 내용을 지운다.


## 한컴오피스 2024 한/글 소개

도움말: `hwp/hwp(intro).htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 새로운 기능 | — | `hwp/new_features.htm` | 소개 문서 |
| 사용 안내 | ◐ | `hwpbase/action(hwp).htm` | 화면 구성·메뉴·도구 상자·빠른 메뉴는 2단계 |

## 파일

도움말: `menu/file.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 새 문서 | ◐ | `file/new/new.htm` | 새 문서 ●. 새 탭은 macOS 창 탭. 한/워드·한/셀·한/쇼 문서는 범위 밖 |
| 문서마당 | △ | `file/madang/madang(madang).htm` | 서식 파일 묶음이 필요. 앱 번들 서식은 사용권 확인 후 |
| 문서 시작 도우미 | — | `file/start_screen.htm` | macOS 열기 패널과 최근 사용 항목으로 대신 |
| 불러오기 | ◐ | `file/open/open.htm` | HWP·HWPX ●, 암호 문서 ●. 한/글 97(HWP 3.0, 확장자 .hwp)·HWPML(.hml) 열기 ●(rhwp가 읽음; 실제 한/글 97·HWPML 견본으로는 아직 확인 못 함). HWPML로 연 문서를 저장하면 HWP·HWPX로 저장한다. 텍스트·DBF 불러오기 △ |
| PDF를 오피스 문서로 변환하기 | — | `file/open/open(pdf).htm` | 한컴 변환 서비스 |
| 그림을 오피스 문서로 변환하기 | — | `file/open/open(picture)_ocr.htm` | 한컴 OCR |
| XML 문서 | — | `file/xml_document.htm` |  |
| 저장하기 | ● | `file/save/save.htm` | 원자적 저장, 저장 전 재파싱 검증. 파일은 저장하기로만 바뀐다(한/글처럼 자동 저장은 복구용 임시 파일). 그림으로 저장하기(파일 › 그림으로 저장하기: 폴더·파일 이름·BMP/GIF/PNG/JPG·해상도 72~300DPI, 쪽마다 001·002…) ●, WMF·색 지정 △ |
| 다른 이름으로 저장하기 | ◐ | `file/save_as/save_as.htm` | HWP·HWPX ●. 파일 › 다른 파일 형식으로 저장하기: 텍스트 문서(*.txt, 문자 코드 유니코드(UTF-8)·유니코드·유니코드(Big-Endian)·한국(KS))·서식 있는 인터넷 문서(*.html, 쪽 배치 그대로) ●. HWPML(HWPML로 연 문서만) ●. 저장 설정·한/글 97·DOCX·ODT·RTF △, 블록 저장(파일 › 블록 저장…, HWPX·HWP로 스타일·편집 용지·문서 암호를 지킴) ●, 구역이 여럿인 문서의 블록 저장 △ |
| PDF로 저장하기 | ● | `file/to_pdf.htm` |  |
| 모바일 최적화 문서로 저장하기 | — | `file/to_mobile.htm` |  |
| 문서 정보 | ◐ | `file/document_properties/document_properties.htm` | 일반 ●·문서 통계 ●·글꼴 정보(언어별 사용된/대체된 글꼴, 글꼴 바꾸기) ●·그림 정보(그림 목록, 그림 삽입·모두 삽입, 삽입 그림 저장하기, 모든 삽입 그림 저장하기, 그림 목록 저장, 그림 바꾸기·경로 바꾸기·그림 확장자 바꾸기·그림 경로 복사) ●. 샌드박스라 그림 삽입은 파일을, 모두 삽입은 폴더를 골라 줘야 함, 문서 요약 △(rhwp에 요약 쓰기 없음), 저작권 △ |
| DAISY 문서 | — | `file/daisy_document.htm` |  |
| CCL 넣기 | △ | `file/ccl.htm` | CCL 마크 그림 자료가 필요 |
| 공공누리 넣기 | △ | `file/kogl.htm` | 공공누리 마크 그림 자료가 필요 |
| 점자로 바꾸기 | — | `file/conversion_to_braille.htm` |  |
| 보내기 | △ | `file/send_to_mail/send_to_mail.htm` | macOS 공유 메뉴로 대신. 웹 서버로 올리기는 범위 밖 |
| 편집 용지 | ◐ | `format/setting_paper/setting_paper.htm` | 기본(용지 종류·방향·여백·제본) ●. 줄 격자·글자 격자 △ |
| 미리 보기 | △ | `file/preview/preview.htm` | 미리 보기 탭(상황 탭). 조판은 같은 표시 목록을 씀 |
| 인쇄 | ◐ | `file/print/print.htm` | macOS 프린트(⌘P) ●. 인쇄: 확장(인쇄용 머리말/꼬리말)·워터마크 △ |
| 최근 작업 문서 | ● | `file/recently_used_documents.htm` | macOS 최근 사용 항목 |
| 문서 닫기 | ● | `file/close.htm` |  |
| 끝 | ● | `file/exit.htm` | macOS 종료 |

## 편집

도움말: `menu/edit.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 되돌리기 | ● | `edit/undo.htm` |  |
| 다시 실행 | ● | `edit/redo.htm` |  |
| 오려 두기 | ● | `edit/cut.htm` |  |
| 복사하기 | ● | `edit/copy.htm` |  |
| 붙이기 | ◐ | `edit/paste.htm` | 같은 문서·다른 앱의 HTML·RTF ●. 셀 붙이기 ◐(표 → 표) |
| 골라 붙이기 | △ | `edit/paste(select).htm` | 붙일 형식 고르기. 클립보드 형식(HWP 내부, HTML, RTF, 텍스트)으로 만들 수 있음 |
| 모양 복사 | ◐ | `format/quick_format/quick_format.htm` | 글자·문단 모양 ●. 스타일 복사·셀 모양 복사·개체 모양 복사 △ |
| 지우기 | ● | `edit/erase.htm` |  |
| 조판 부호 지우기 | ● | `edit/erase_code.htm` |  |
| 모두 선택 | ● | `edit/select_all.htm` |  |
| 찾기 | ◐ | `edit/find/find_find.htm` | 찾기·찾아 바꾸기·다시 찾기 ●, 찾은 개수 ●, 선택 사항의 대소문자 구별·온전한 낱말 ●. 여러 단어 찾기·띄어쓰기 무시·아무개 문자·한글로 한자 찾기·자소 단위 찾기·조건식 사용·조사 자동 교정 △. 찾아가기(⌥⌘G)의 쪽(+n·−n 포함)·책갈피 ●, 구역·줄·스타일·조판 부호 △ |
| 글자 바꾸기 | △ | `edit/change_characters/change_characters.htm` | 대문자/소문자·전각/반각·일어·간체/번체는 앱에서 바꿔 넣으면 됨. 한자로 바꾸기는 macOS 입력기 |
| 정렬 | △ | `tools/sort/sort.htm` | 문단 정렬. 엔진에 문단 순서 바꾸기 명령 필요 |
| 고치기 | ◐ | `edit/modification.htm` | 선택한 개체의 속성, 커서 위치의 누름틀·하이퍼링크 ● |
| OLE 연결 | — | `edit/objectlink.htm` | Windows OLE |
| OLE 개체 속성 | — | `edit/objecedit.htm` | Windows OLE |
| 블록 | ● | `edit/block.htm` | F3 블록은 macOS 관례로 Shift 선택 |
| 칸 단위 블록 | △ | `edit/column_block.htm` |  |
| 삽입/수정 | △ | `edit/insert.htm` | 수정(덮어쓰기) 상태 |

## 보기

도움말: `menu/view.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 확대/축소 | ◐ | `view/zooming/zoom.htm` | 배율·쪽 맞춤·폭 맞춤·여러 쪽 ●. 화면 확대 대화 상자 △ |
| 쪽 윤곽 | ● | `view/page_outline.htm` |  |
| 표시/숨기기 | ◐ | `view/showandhide.htm` | 조판 부호·문단 부호·투명 선 ●. 교정 부호 △, 그림 숨기기 △ |
| 메모 | △ | `view/memo.htm` | rhwp에 메모 없음 |
| 한자 발음 | △ | `view/chinese_pronounce.htm` |  |
| 격자 | ◐ | `view/grid/grid.htm` | 격자 보기 ●. 격자 설정 △ |
| 안내선 | △ | `view/object_move_guideline/guideline(objectmoveguideline).htm` | 앱 쪽 작업 |
| 문서 보기 색 | △ | `view/document_view_color.htm` | 앱 쪽 작업(표시만 바꿈). 사용자 색 △ |
| 도구 상자 | ◐ | `view/toolbar/toolbar.htm#bc-1` | 2단계에서 2024 구성으로 바꿈. 사용자 설정은 범위 밖 |
| 작업 창 | ◐ | `view/workwindow/workwindow.htm` | macOS처럼 왼쪽 사이드바(⌃⌘S)에 쪽 모양 보기·개요 보기(수준별 트리, 실시간 반영, 누르면 그 문단으로 이동)·책갈피, 오른쪽 작업 창에 스타일(목록과 적용, 추가·편집·지우기·위로·아래로 아이콘과 빠른 메뉴) ●. 클립보드 △, 나머지 범위 밖 |
| 문서 창 | ◐ | `view/document_window.htm` | 가로 눈금자 ● (탭 표시 △), 상황 선 ◐, 세로 눈금자 △, 문서 탭은 macOS 창 탭 |
| 편집 화면 나누기 | △ | `window/division/division.htm` | 앱 쪽 작업 |
| 창 배열 | — | `window/arrange/arrange_windows.htm` | macOS 윈도우 메뉴 |
| 창 목록 | — | `window/windows_list.htm` | macOS 윈도우 메뉴 |
| 열린 창 목록 | — | `window/open_list.htm` | macOS 윈도우 메뉴 |

## 입력

도움말: `menu/insert.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 도형 | ◐ | `draw/drawing(polygon).htm` | 직선·직사각형·타원·호·글상자 ●. 다각형·곡선·자유선·개체 연결선 △. 새 그리기 속성 △ |
| 그림 | ◐ | `insert/figure/figure(figure).htm` | 그림 넣기 ●. 그림 탭의 바꾸기/저장(그림 바꾸기, 삽입 그림 저장하기) ●, 바꾼 그림의 옛 데이터는 파일에 남는다. 그리기마당 △(자료 필요), 스크린 샷 △, 연결 그림 새로 고침 △, 그림에서 글자 가져오기 — |
| 표 | ◐ | `table/table(table).htm` | 표 만들기 ●. 표 그리기·표 지우개·문자열을 표로·표를 문자열로 △ |
| 차트 | ◐ | `table/chart/chart(createchart).htm` | 차트 고르기·차트 디자인 탭·차트 데이터 편집(두 번 눌러 셀 편집, 줄/칸 추가·지우기, 두 번 누르기·빠른 메뉴 「데이터 편집」) ●. 차트 만들기 △(rhwp가 새로 만들지 못함), 차트 모양 바꾸기 △(rhwp에 차트 종류를 바꾸는 함수가 없음), HWPX의 차트는 HWP로 저장하면 사라짐(rhwp) |
| 글상자 | ◐ | `insert/textbox/textbox.htm#bc-1` | 넣기 ●. 글상자 연결·세로쓰기 △ |
| 멀티미디어 | △ | `insert/multimedia.htm` | 동영상·소리 개체 |
| 수식 | ● | `insert/equation/equation.htm` | 수식 편집기. 각주 안 수식은 속성만(rhwp 쪽 배치 한계) |
| 개체 | ◐ | `insert/object.htm` | 필드 입력 › 누름틀(안내문·메모·필드 이름·양식 모드에서 편집 가능, 빨간 안내문, 입력하면 안으로) ●, 편집 › 고치기로 누름틀 고치기 ●, 사용자 정보·작성한 날짜·문서 요약·파일 이름 탭 △(rhwp가 본문에 이 필드를 넣지 못함), 양식 개체 값(선택 상자·라디오 단추 묶음은 눌러서, 콤보 상자는 항목 메뉴, 입력 상자는 글자 입력) ●, 양식 개체 넣기·양식 편집 상태·명령 단추 스크립트 △(rhwp가 양식 개체를 만들지 못함), 글맵시 △, OLE 개체 —, 그리기 개체 △ |
| 캡션 넣기 | ● | `insert/caption.htm` |  |
| 문단 띠 | △ | `insert/line.htm` |  |
| 입력 도우미 | △ | `tools/insert_doumi.htm` | 상용구·글자 겹치기·외래어 표기·로마자 |
| 채우기 | △ | `table/autofill/table(autofill)_main.htm` | 표 자동 채우기 |
| 주석 | ◐ | `insert/annotations/annotations.htm` | 각주·미주 넣기 ●. 각주/미주 모양 ● (번호 모양·장식 문자·구분선·여백·번호 매기기; 번호 모양 「기호」, 번호 매기기 「쪽마다 새로 시작」, 각주 내용 번호 속성, 각주 세로 위치, 단 각주 위치, 미주 위치는 △), 각주↔미주 △, 주석 저장하기 △, 숨은 설명 △. 주석 탭(상황 탭): 각주/미주 모양·주석 지우기·이전/다음 주석으로·닫기 ●, 각주·미주·단 각주 위치와 번호 모양·보통/작게·구분선 길이/스타일 바로 고르기는 각주/미주 모양 대화 상자로만 |
| 날짜/시간/파일 이름 | △ | `insert/date/date.htm` | 문자열 넣기는 앱 쪽 작업, 코드는 필드 필요 |
| 덧말 넣기 | △ | `insert/addsummary.htm` |  |
| 문서 끼워 넣기 | ◐ | `insert/insert_file.htm` | 입력 › 문서 끼워 넣기: HWP·HWPX 파일 여러 개를 커서 위치에 차례로(본문), 파일 이름으로 책갈피 넣기 ●. 끼운 문서의 서식·스타일은 rhwp가 옮겨 심고 같은 것은 다시 씀. 스타일의 글자 모양 유지·문단 모양 유지·스타일 유지(사본 이름)·쪽 모양 유지 △(rhwp가 고르지 못함), [여러 문서 끼워 넣기]의 순서 바꾸기 △ |
| 문자표 | ◐ | `insert/character_set.htm` | 문자표 ●(유니코드). 사용자 문자표·한/글 문자표·완성형 문자표 △ |
| 한자 입력 | — | `insert/chinese_input.htm` | macOS 입력기 |
| 메모 | △ | `insert/memo/memo.htm` | rhwp는 메모 필드를 읽고 저장하지만 넣기·그리기가 없음 |
| 상호 참조 | △ | `insert/cross_reference/cross_reference.htm` |  |
| 책갈피 | ● | `insert/bookmark/bookmark.htm` | 넣기·이동·이름 바꾸기·지우기 |
| 하이퍼링크 | ◐ | `insert/hyperlink/hyperlink.htm` | 웹 주소로 연결(표시할 문자열, 블록 없이 넣으면 그 자리에 문자열), 하이퍼링크 고치기(편집 › 고치기, 빠른 메뉴), 하이퍼링크 지우기(빠른 메뉴, 원래 글자 모양으로), 누르면 이동(⌘K), 웹 주소 자동 연결(띄어쓰기·Enter 뒤의 http·https·www. 주소, 되돌리기 한 번에 링크만 풀림) ●. 본문·표 셀·글상자. 전자 우편·한/글 문서·파일로 연결, 설명할 문자열, 개체에 연결, 하이퍼링크 이전/다음, 전자 우편 주소 자동 연결 △(rhwp가 웹 주소 명령만 쓰고, 다른 연결의 명령 형식은 한/글이 만든 견본으로 확인해야 함) |

## 서식

도움말: `menu/format.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 글자 모양 | ◐ | `format/font/fonts.htm` | 2024 탭은 기본·확장·테두리/배경. 앱은 기본·확장이고 테두리/배경을 확장 안에 둔다. 5단계에서 탭을 나누고 항목(강조점 등)을 대조 |
| 문단 모양 | ◐ | `format/paragraph/paragraph.htm` | 2024 탭은 기본·확장·탭 설정·테두리/배경. 앱은 기본·테두리/배경. 확장(문단 보호·외톨이줄 보호·다음 문단과 함께 등)과 탭 설정이 없다. 최소 공백 △ |
| 문단 첫 글자 장식 | △ | `format/drop_cap/drop_cap.htm` |  |
| 문단 번호 모양 | ◐ | `format/numberbullet/numberbullet(main).htm` | 문단 번호·글머리표 ●, 새 번호 목록 시작은 저장 안 됨(BUG_HANDOFF P1). 그림 글머리표 △. 표 칸·주석 안 시작 번호 방식 △(rhwp `set_numbering_restart_native`가 본문 문단만 받음) |
| 문단 번호 적용/해제 | ● | `format/numberbullet/number(attributes_cancel).htm` |  |
| 글머리표 적용/해제 | ● | `format/numberbullet/bullet(attributes_cancel).htm` |  |
| 개요 번호 모양 | △ | `format/outline/outline_numbering(paragraph_number).htm` |  |
| 개요 적용/해제 | △ | `format/outline/outline_numbering(attributes_cancel).htm` |  |
| 한 수준 증가/감소 | ● | `format/outline/outline_numbering(depth).htm` |  |
| 스타일 | ◐ | `format/style/style.htm` | 서식 도구 상자의 스타일 고르기 ●. 스타일 대화 상자(F6): 스타일 목록, 추가하기·편집하기(이름, 영문 이름, 종류, 다음 문단에 적용할 스타일, 문단 모양·글자 모양)·지우기(바꿀 스타일 선택)·커서 위치의 스타일로 바꾸기·한 줄 위로/아래로 이동하기, 문단 모양 정보·글자 모양 정보·현재 커서 위치 스타일 ●. 문단 모양 미리 보기, 글머리표/문단 번호 단추·정보, 글자 스타일 해제, 스타일 가져오기·내보내기는 △ |
| 스타일마당 | △ | `format/style_templates/style_templates.htm` | 서식 파일 자료 필요 |
| 개체 속성 | ◐ | `insert/objectattribute/objectattribute.htm` | 개체 보호하기(기본 탭, 도형·그림 탭의 개체 보호 › 개체 보호하기·모든 보호 개체 해제하기; 보호한 개체는 고를 수 없음) ●. 2024 탭은 기본·여백/캡션·선·채우기·글상자·그림자·그림·수식·글맵시. 앱은 기본·여백/캡션, 그림의 선·그림 탭, 도형의 선(사각형 모서리 곡률 포함)·채우기·글상자(안쪽 여백·세로 정렬)·그림자(종류·색·이동·투명도) 탭 ●. 그림자 중 작게·크게·뒤·앞은 옮긴 모양으로만 그림, 글상자 탭의 글자 방향(가로·영문 눕힘·영문 세움; HWP로 저장하면 영문 세움이 영문 눕힘이 됨)과 선 탭의 호 테두리(호·부채꼴·활 모양) ●. 글상자의 한 줄로 입력·필드 △(rhwp가 그리거나 저장하지 못함). 너비·높이 기준과 본문 위치 △(rhwp 속성 JSON이 받지 않음) |

## 쪽

도움말: `menu/Page.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 편집 용지 | ◐ | `format/setting_paper/setting_paper.htm#bc-1` | 기본(용지 종류·방향·여백·제본) ●. 줄 격자·글자 격자 △ |
| 글자 방향 | △ | `format/vertical.htm` | 세로쓰기 |
| 쪽 테두리/배경 | ● | `format/pageborder/page_border.htm` | 테두리(선 종류 바로 적용, 위치, 머리말·꼬리말 포함, 적용 쪽)와 배경의 색 채우기·채울 영역. 홀수/짝수 쪽, 그러데이션·그림 채우기, 적용 범위 「새 구역으로」는 △ (rhwp가 홀짝 쪽 테두리를 그리지 않음) |
| 바탕쪽 | △ | `format/masterpages/master_pages.htm` | rhwp에 바탕쪽 편집 없음(그리기는 됨) |
| 머리말/꼬리말 | ◐ | `format/header/header.htm` | 만들기·편집·지우기·이전/다음·감추기 ●. 머리말/꼬리말 탭의 코드 넣기 › 상용구: 전체 쪽수·현재 쪽 번호·현재 쪽/전체 쪽수 ●(편집 중 번호 그리기 위치는 BUG_HANDOFF P2). 상용구의 나머지(날짜·지은이·제목·파일 이름 등)·날짜/시간·그림 △. 머리말/꼬리말 탭(상황 탭) 2단계 |
| 쪽 번호 매기기 | △ | `format/pagenumber.htm` | 앱에는 머리말·꼬리말 모양 목록의 쪽 번호만 있다. [쪽 번호 매기기] 대화 상자(번호 위치 10가지·번호 모양)는 없음. rhwp에 쪽 번호 위치(`PageNumberPos`) 모델과 그리기는 있고 넣기 명령이 없다(새 번호로 시작처럼 패치) |
| 새 번호로 시작 | ● | `format/new_number.htm` |  |
| 현재 쪽만 감추기 | ● | `format/hide.htm` |  |
| 줄 번호 | △ | `view/line_number.htm` |  |
| 쪽 나누기 | ● | `format/break/page_break.htm` |  |
| 단 나누기 | ● | `format/break/column_break.htm` |  |
| 단 | ◐ | `format/columns/columns.htm` | 하나·둘·셋 ●. 단 설정 대화 상자(단 종류 일반·배분·평행 단, 자주 쓰이는 모양 하나·둘·셋, 단 개수, 간격, 단 너비 동일하게; 단 너비 10mm 이상) ●. 왼쪽·오른쪽(단 너비 따로)·구분선 △, rhwp가 구역의 줄을 첫 단 정의 너비로 나눔 |
| 단 설정 나누기 | △ | `format/break/new_columns.htm` | 단 정의가 둘 이상인 구역의 조판부터 |
| 구역 설정 | ● | `format/section/section.htm` | 시작 쪽 번호(홀수·짝수는 번호만 건너뛰고 빈 쪽은 넣지 않음), 개체 시작 번호, 첫 쪽에만 감추기, 빈 줄 감추기, 단 사이 간격, 기본 탭 간격. 적용 범위 「새 구역으로」는 구역 나누기와 함께 △ |
| 구역 나누기 | △ | `format/break/section_break.htm` |  |
| 쪽 복사하기 | △ | `format/copy_page.htm` |  |
| 쪽 지우기 | △ | `format/remove_page_current.htm` |  |
| 원고지 | △ | `tools/wongogi/wongogi.htm` |  |
| 라벨 | △ | `tools/label/label.htm` | 라벨 서식 자료 필요 |

## 보안

도움말: `menu/security.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 문서 암호 설정 | ◐ | `file/password/password.htm` | 여는 암호 ●, 보안 › 문서 암호 설정(문서 암호·암호 확인, HWP 5~44자·HWPX 1~255자, 저장할 때 기록) ●. 보안 종류(보통/높음)와 HWPX 쓰기 암호 △(rhwp가 한 가지 암호만 씀) |
| 문서 암호 변경/해제 | ◐ | `file/password/password(change).htm` | 암호 변경·암호 해제(현재 암호 확인) ●. 쓰기 암호 대상 △ |
| 배포용 문서로 저장 | △ | `file/send_to_mail/publish(save).htm` |  |
| 배포용 문서 편집 | — | `file/send_to_mail/publish(edit).htm` | 자동 권한 판단이 보안 약화로 막아 보류(사용자 결정 필요) |
| 배포용 문서 암호 변경/해제 | △ | `file/send_to_mail/publish(cancel).htm` |  |
| 개인 정보 보호 | △ | `security/user_info_security/user_info_security.htm` | 보호(암호화) 저장 △. 찾기는 개인 정보 바꾸기와 같은 `scan_pii` |
| 문서 보안 설정 | △ | `security/document_security.htm` |  |

## 검토

도움말: `menu/review.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 교정 부호 | △ | `insert/proofreadmark/proofreadmark.htm` |  |
| 변경 내용 추적 | △ | `review/track_changes/track_changes.htm` |  |
| 변경 내용 표시 설정 | △ | `review/track_changes/track_changes(options).htm` |  |
| 문서 이력 관리 | △ | `file/version_information/version_information.htm` |  |
| 문서 비교 | △ | `review/compare_document/compare_document.htm` |  |
| 새 메모 | △ | `insert/memo/memo(insert).htm#bc-1` | 메모와 같음 |
| 메모 모양 | △ | `insert/memo/memo(format).htm#bc-1` |  |
| 모든 메모 표시 | △ | `view/memo/memo(expression).htm#bc-1` |  |

## 도구

도움말: `menu/tools.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 맞춤법 | ◐ | `tools/speller/spelling.htm` | macOS 편집 › 맞춤법 및 문법: 맞춤법 및 문법 보기(⌘:)·지금 문서 검사(⌘;)가 캐럿의 문단부터 그 영역 끝까지 ●. 입력하는 동안 맞춤법 검사는 아직 |
| 한컴 사전 | — | `tools/dictionary/dictionary(haandictionary).htm` | macOS 사전 찾아보기(강한 클릭·세 손가락 탭, 빠른 메뉴의 「찾아보기」)로 대신 ● |
| 한자 사전 | — | `tools/chinese_dictionary.htm` |  |
| 유의어/반의어 사전 | — | `tools/thesaurus/thesaurus.htm` |  |
| 번역 | — | `view/workwindow/workwindow(translation).htm#bc-1` | macOS 번역 서비스 |
| 빠른 교정 | — | `tools/qcorrect/qcorrect.htm` | macOS 텍스트 대치(키보드 설정)로 대신 ●. 서비스·글쓰기 도구·말하기·VoiceOver는 캐럿의 문단과 선택한 글자를 읽는다 |
| 한컴 애셋 | — | `tools/asset.htm` |  |
| 메일 머지 | △ | `tools/mail_merge/mail_merge.htm` | 메일 머지 필드({{1}}) 넣기 △(rhwp가 메일 머지 필드를 만들지 못함; 있는 함수 `set_field_value_by_name`·`fill_template_native`·`repeat_and_fill_table_rows_native`는 누름틀과 표 줄 채우기라 이 흐름에 맞지 않음), 자료 파일(한/글·DBF·한/셀·CSV) 읽기와 출력 방향 △ |
| 스크립트 매크로 | — | `tools/macro/macro.htm` |  |
| 차례/색인 | △ | `tools/index/index.htm` | 차례 만들기 △. 개요 문단 목록은 개요 보기와 같은 `get_outline_navigation_native`에서 얻을 수 있음 |
| 참고 문헌 | △ | `tools/bibliography/bibliography.htm` |  |
| 블록 계산 | △ | `tools/blocksum/blocksum.htm` | 본문 블록의 합계·평균. 표 블록 계산식은 됨 |
| 문서 찾기 | — | `file/finding_files/finding_files.htm` | Spotlight |
| 개인 정보 바꾸기 | ◐ | `security/user_info_protection/user_info_protection.htm` | 보안 메뉴·탭. 바로 바꾸기(블록을 ***로) ●, 찾아서 바꾸기(전화번호·주민등록번호·전자우편·신용카드 번호·기타; ***·~~~·XXX·사용자 정의 문자; 찾기/다음 찾기·바꾸기·모두 바꾸기) ●. 외국인등록번호·계좌 번호·IP 주소·생년월일·주소·사용자 정의 설정 △(rhwp `scan_pii`에 없음) |
| 프레젠테이션 | — | `tools/presention/presentation.htm` |  |
| 글자판 | — | `insert/keyboard/keyboard.htm` | macOS 입력기 |
| COM 추가 기능 설정 | — | `tools/add-in/add-in.htm` |  |
| 사용자 설정 | — | `view/toolbar/toolbar(edit).htm#bc-1` | 도구 상자 사용자 설정 |
| 환경 설정 | △ | `file/options/options.htm` | macOS 설정 창(⌘,). 파일 탭의 복구용 임시 파일 자동 저장(무조건 자동 저장 1~60분, 쉴 때 자동 저장 1~360초) ●. 나머지는 필요한 항목만 |
| 스킨 설정 | — | `tools/skin.htm` | macOS 다크 모드 |

## 표

도움말: `menu/table.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 표 | ◐ | `table/table(table).htm#bc-1` | 표 만들기 ●. 표 그리기·표 지우개·문자열을 표로·표를 문자열로 △ |
| 차트 만들기 | △ | `table/chart/chart(createchart).htm#bc-1` | 차트와 같음 |
| 표/셀 속성 | ● | `table/tableattribute/tableattribute.htm` | 기본·여백/캡션·테두리(셀 간격, 표의 네 방향)·배경(색과 무늬, 그러데이션, 그림)·표·셀 ● |
| 셀 테두리/배경 | ◐ | `table/cellborder/cellborder.htm` | 각 셀마다 적용(테두리 여섯 방향·배경 색과 무늬·＼／ 대각선과 중심선, 적용 범위 모든 셀/선택된 셀)·하나의 셀처럼 적용(테두리·배경·대각선) ●, 셀 블록의 L·C ●. 「표 테두리/배경」 단추 ●, 배경의 그러데이션(모양·시작/끝 색·기울임·중심·번짐)·그림(채우기 유형·그림 효과·밝기·대비·워터마크) ●. 색·그러데이션과 그림을 함께 채우기, 그러데이션 유형 목록, 대각선의 꺾은선 모양 △(rhwp 테두리/배경 JSON이 채우기 하나와 꺾은선 없는 대각선만 받음) |
| 표 나누기 | ● | `table/table(dividing).htm` | 표 메뉴, 표 레이아웃 탭. 첫 줄에서는 한/글의 알림 대신 경고음 |
| 표 붙이기 | ● | `table/table(attach).htm` | 표 메뉴, 표 레이아웃 탭. 붙일 표가 없으면 경고음 |
| 줄/칸 추가하기 | ◐ | `table/table(ins).htm` | 위쪽·아래쪽·왼쪽·오른쪽 ●. 대화 상자(줄/칸 수) △ |
| 줄/칸 지우기 | ● | `table/table(del).htm` |  |
| 셀 나누기 | ● | `table/table(divide).htm` |  |
| 셀 합치기 | ● | `table/table(merge).htm` |  |
| 셀 높이를 같게 | ● | `table/table(eqheight).htm` |  |
| 셀 너비를 같게 | ● | `table/table(eqwidth).htm` |  |
| 표 테두리/배경 | ◐ | `table/tableborder/tableborder.htm` | 셀 테두리/배경의 단추로 여는 테두리(셀 간격·네 방향)·배경(색과 무늬, 그러데이션, 그림) ● |
| 표마당 | △ | `table/tablemadang/tablemadang.htm` | 표 스타일 자료 필요 |
| 표 뒤집기 | ● | `table/table(transform).htm` | 대칭 3가지, 회전 3가지, 여백 뒤집기. 합친 셀 포함. 줄/칸이 바뀌면 표 너비를 지키고 칸을 고르게 나눈다(rhwp 방식). 크기 고정·개체 보호 표를 막는 것은 아직 없다 |
| 블록 계산식 | ◐ | `table/blockcal/blockcal.htm` | 값으로 넣음. 계산식 필드로 넣어 자동 다시 계산 △ |
| 쉬운 계산식 | △ | `table/easycal/easycal.htm` |  |
| 계산식 | ◐ | `table/calculation/calculation.htm` | 표 레이아웃·표 메뉴의 계산식(함수·쉬운 범위·형식·세 자리마다 쉼표) ●, 결과는 값으로 들어간다. 계산식 필드(다시 계산·고치기) △ |
| 1,000 단위 구분 쉼표 | △ | `table/table(threedigits).htm` | 자릿점 넣기·빼기 |
| 셀 블록 | ● | `table/table(cell).htm` |  |
| 표 크기 조절 | ◐ | `table/table(size).htm` | 테두리 끌기 ●. 바깥 테두리를 눌러 표를 개체로 고르고, 조절점으로 표 전체 크기를 비율대로 조절·끌어서 이동·Delete로 지우기 ●. 셀 안의 표 △ |
| 표의 편집 | ◐ | `table/table(edit).htm` | 중첩 표 셀 편집 △(읽기 전용) |
| 표에서 세로쓰기 | △ | `table/table(write_vertically).htm` | 세로쓰기 셀은 읽기 전용 |
| 셀 붙이기 | ◐ | `table/table(paste).htm#bc-1` |  |

## 그림 그리기

도움말: `draw/drawing.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 도형 탭 | ◐ | `toolbox/object_shapeobject.htm` | 개체 탭으로 2단계. 개체 묶기 ●(Shift+클릭으로 고름, G), 개체 선택 ●(도형·그림 탭의 아이콘으로 끌어 고르기, Alt+클릭으로 겹친 개체 돌아가며, Tab·Shift+Tab으로 쪽의 개체 차례로, F11로 커서 위치나 그 앞의 개체 차례로(macOS의 F11 「데스크탑 보기」를 끄면 됨; 하이퍼링크·누름틀 블록은 △), 설정 › 개체 › 일부분 선택만으로 개체 전체 선택), 풀기 ●(U), 순서 ●, 회전(왼쪽으로·오른쪽으로 90도 회전, 좌우·상하 대칭, 개체 속성 기본 탭의 회전각) ●, 개체 회전(끌어서 돌리기) △ |
| 개체 이동하기 | ● | `draw/move/drawing(move).htm` |  |
| 개체 크기 조절 | ● | `draw/drawing(size).htm` |  |
| 개체 기울이기 | △ | `draw/drawing(incline).htm` |  |
| 개체 복사하기/붙이기 | ● | `draw/drawing(copy).htm` |  |
| 개체를 그림 파일로 저장하기 | △ | `draw/drawing(save).htm` | 앱이 그 개체의 표시 목록을 그림으로 그리면 됨 |

## 추가 기능

도움말: `view/toolbox/menu_add-in.htm` · 범위 밖

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 한애드온즈 | — | `tools/external_add-in/addons.htm` | 한컴 서비스 |
| 옛한글 코드 변환기(COM 추가 기능) | — | `hwpbase/hncpuaconverter_addin.htm` |  |
| 단축키 도우미 | — | `tools/external_add-in/shortcut_key_assistant.htm` |  |
| 애셋 스튜디오(Beta) | — | `tools/external_add-in/asset_studio.htm` | 한컴 서비스 |

## 한컴독스

도움말: `cloud/thinkfree_drive.htm` · 범위 밖(한컴 서비스)

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 한컴독스에 자동 저장 | — | `cloud/auto_save(cloud).htm` | 한컴 서비스 |
| 한컴독스에 저장하기 | — | `cloud/save(thinkfree).htm` |  |
| 한컴독스에서 불러오기 | — | `cloud/open(thinkfree).htm` |  |
| 문서 공유하기 | — | `cloud/share_file.htm` | macOS 공유 |
| 환경 설정 내보내기/가져오기 | — | `cloud/options.htm` |  |

## 단축키

도움말: `view/toolbar/shortcut.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 단축키 일람 | ◐ | `view/toolbar/shortcut(table).htm` | ROADMAP 「창 구성」의 규칙으로 옮겼다. macOS 표준과 겹치는 것(정렬, 지우기 Ctrl+E, 줄 지우기 Ctrl+BackSpace, 다른 이름으로 저장하기)은 macOS 단축키를 쓴다. 연속 단축키와 Insert 키 단축키는 없다. 남은 것은 그 기능을 만들 때 넣는다(맨 앞으로 Shift+Page Up 등). |

## 사용권

도움말: `rights/rights.htm`

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 한/글 정보 | ● | `rights/rights(info).htm` | macOS 「Hwalja에 관하여」 |

## 오픈 소스 라이선스

도움말: `oss/oss_notice.htm` · 범위 밖

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|

## 고객 지원 안내

도움말: `support/support(guide).htm` · 범위 밖

| 기능 | 상태 | 도움말 | 메모 |
|---|---|---|---|
| 제품 등록 방법 | — | `support/support(method).htm` |  |
| 고객 지원 서비스 | — | `support/support(service).htm` |  |
| 사용성 데이터 수집 및 처리 방침 | — | `support/support(data_collection).htm` |  |
