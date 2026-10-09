# 기여하기

Hwalja에 관심을 가져 주셔서 감사합니다. 버그 신고, 기능 제안, 풀 리퀘스트 모두 환영하고 있습니다. 다만 보안 문제는 이슈 대신 [SECURITY.md](SECURITY.md)의 방법으로 신고해 주시기 바랍니다.

## 빌드

필요한 도구: Xcode 16 이상, Rust, `cbindgen`

 `sudo xcode-select -s /Applications/Xcode.app` 또는 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 설정하십시오.

```sh
make test       # Rust 엔진 + Swift 테스트
make fmt-check  # 엔진 rustfmt 검사
make run        # build/hwalja.app 생성(ad-hoc 서명) 후 실행
make dist       # 유니버설 빌드, Developer ID 서명, 공증, build/hwalja.zip
```

앱과 엔진의 프로토콜 버전이 다르면 Hwalja에서 렌더링 이전에 열기가 거부됩니다. `make engine` 뒤 `make run`을 실행하십시오.

Finder 훑어보기 확장은 앱을 한 번 실행하면 등록됩니다. ad-hoc 서명은 빌드할 때마다 바뀌므로, 다시 빌드한 뒤에는 `pluginkit -a build/hwalja.app/Contents/PlugIns/HwaljaPreview.appex`로 다시 등록하십시오.

`make dist` 준비:
`rustup target add x86_64-apple-darwin`,
`export SIGN_IDENTITY="Developer ID Application: …"`,
`xcrun notarytool store-credentials hwalja`.

## 구조

| 경로 | 내용 |
|---|---|
| `App/` | SwiftUI 문서 앱: `Document/`(`HwpDocument`: 열기·편집·저장), `Workspace/`(창, 편집 캔버스), `Editing/`(엔진 세션, 프로토콜, 좌표) |
| `Preview/` | Finder 훑어보기 확장. `Editing/`은 `App/Editing`을 가리키는 링크라 앱과 같은 엔진과 그리기 코드를 씁니다 |
| `Engine/` | rhwp를 감싸는 Rust C ABI (`hwp-engine-abi`). `editing/`은 편집 세션(명령, 기록, 보존 검사, 좌표, `ffi`) |
| `Vendor/` | 체크섬으로 검증하는 rhwp 소스 압축본과 패치 (`Vendor/README.md`) |
| `Tests/` | Swift 테스트와 생성된 공개 fixture |
| `docs/` | `ROADMAP.md`(목표와 남은 기능), `FEATURES.md`(기능별 상태), `BUG_HANDOFF.md`(남은 버그, 수동 점검), `brand/`(아이콘, 워드마크) |

## 기준

- 원본을 훼손하지 않는 macOS 네이티브 HWP/HWPX 편집기. 조판 및 화면 배치는 한/글 2024와 동일하게. 구체적인 모양과 조작은 Apple HIG를 따릅니다.
- 기능의 동작, 메뉴·도구 상자·대화 상자의 구성과 순서는 [한컴오피스 2024 한/글 도움말](https://help.hancom.com/hoffice130/ko-KR/Hwp/index.htm)의 글과 그림을 따릅니다. `scripts/hancom-help.py`로 받으면 `build/hancom-help/`에서 읽을 수 있습니다. 도움말과 다르게 만든 부분은 ROADMAP·FEATURES·BUG_HANDOFF 중 맞는 곳에 이유를 작성해 주십시오.
- 앱 안에 설명 문구를 넣지 않습니다. 지연과 깜빡임을 버그로 판단합니다.
### 용어

- 메뉴·도구 상자·단추·대화 상자 이름과 그 안의 문구는 2024 도움말(글과 그림)을 그대로 사용합니다. 도움말끼리 다르면 기능 자신의 쪽 > 메뉴 쪽 > 도구 상자 탭 쪽 순으로 우선합니다.
- 새 용어를 만들지 않습니다. 확인할 수 없는 이름은 아이콘이나 견본으로 대신하고, 그것도 안 되면 이름을 확인할 때까지 보류합니다.
- macOS가 정해 둔 명령(앱 메뉴, 프린트…, 윈도우 메뉴, 취소 단추, 표준 찾기 명령, 편집 메뉴의 실행 취소·오려두기·붙여넣기·삭제·전체 선택)은 macOS 이름을 사용합니다. 한/글 이름과 겹치면 macOS가 우선합니다. 한글 고유의 연속 단축키(Ctrl+N,S 등)는 사용하지 않습니다.

## 작업 순서

1. 할 일은 ROADMAP의 순서를 따릅니다.
2. 그 기능의 도움말 쪽과 그림, 그 기능이 들어 있는 메뉴·도구 상자 탭 쪽을 읽습니다. 코드를 바꾸기 전에 실제 흐름(엔진 → 프로토콜 → 앱)을 끝까지 읽고, 버그는 증상이 아니라 모든 호출자가 지나는 곳에서 고칩니다.
3. 기능마다 엔진 테스트와 앱 테스트를 하나씩 남깁니다. 화면은 스냅샷(`HWP_SNAPSHOT_DIR`)으로 직접 보고, 조판은 한컴에서 만든 PDF와 쪽마다 나란히 비교합니다.
4. 화면에서 손으로 확인하지 못한 것은 BUG_HANDOFF의 수동 점검에 적습니다. 끝난 항목은 ROADMAP·BUG_HANDOFF에서 지우고 FEATURES의 상태를 수정합니다.

## 코드

- 주변 코드와 같은 이름·주석 밀도·관용구를 씁니다. 필요 없는 추상화, 나중을 위한 뼈대, 한 번만 쓰는 설정을 만들지 않습니다.
- rhwp를 고칠 때는 `build/rhwp`에서 고친 뒤 `Vendor/rhwp-layout.patch`를 다시 만들고 `Vendor/README.md`에 한 줄을 더합니다. 생성된 `build/`는 커밋하지 않습니다.
- 안전성을 확인할 수 없는 대상은 읽기 전용으로 두고, 풀 때는 보존 검사(`preservation.rs`)를 먼저 작성합니다.

## 커밋과 풀 리퀘스트

- 커밋 메시지는 제목 한 줄만 씁니다: `feat:`·`fix:`·`docs:`·`chore:` + 영어 설명, 한글 기능 이름은 그대로. 예: `feat: 문서 끼워 넣기: HWP·HWPX files at the caret`.
- 풀 리퀘스트는 `main`을 대상으로, 하나의 기능이나 수정 단위로 보냅니다. `make test`와 `make fmt-check`가 통과해야 합니다.
- 개인 문서와 비공개 문서는 저장소, 로그, 테스트 자료, 이슈에 올리지 않습니다. 실제 문서로 하는 검사는 로컬에서만 합니다(`HWP_CORPUS`, `HWP_SNAPSHOT_DOC`). 공개 fixture는 `Tests/Fixtures/README.md`의 방법으로 생성합니다.

## 라이선스

기여한 코드는 [MIT 라이선스](LICENSE)로 배포됩니다.

앱 번들의 `ThirdPartyNotices.txt`는 `scripts/bundle-app.sh`가 `scripts/third-party-notices.py`로 생성됩니다. rhwp·SwiftMath 고지(`App/Resources/ThirdPartyNotices.txt`) 뒤에 엔진에 링크되는 Rust 크레이트마다 라이선스 전문을 붙이며, 고지가 필요한데 라이선스 파일이 없는 크레이트가 있으면 빌드가 멈춥니다. 새 의존성은 MIT·Apache-2.0·BSD·Zlib 계열이어야 합니다.
