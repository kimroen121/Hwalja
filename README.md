# HwpStudio

HWP·HWPX 문서를 위한 macOS 네이티브 편집기(macOS 14 이상). 문서 기반 앱으로 동작하며, 글자·문단 서식, 표, 그림, 도형, 수식, 주석, 머리말·꼬리말을 편집해 HWP/HWPX로 저장하고 PDF로 내보냅니다. 메뉴와 이름은 한컴오피스 Web 한글을 따릅니다.

- 조판 엔진: [rhwp](https://github.com/edwardkim/rhwp) 0.8.6 (MIT). `Vendor/`에 고정 버전과 로컬 패치가 들어 있습니다.
- 화면과 PDF 내보내기는 엔진의 같은 조판 결과를 씁니다. 편집하면 바뀐 쪽만 다시 그립니다.
- 저장할 때마다 엔진이 결과를 다시 파싱해 텍스트와 컨트롤 구조가 같은지 검증합니다. 이전 판은 macOS 「버전 탐색」으로 되돌릴 수 있습니다.
- 한컴오피스와 글꼴·쪽 나눔이 다를 수 있습니다.

## 빌드

필요한 도구: Xcode 16 이상, Rust(`rustup`), `cbindgen` (`brew install cbindgen`).
Command Line Tools만으로는 SwiftUI 매크로가 없어 빌드되지 않습니다. `sudo xcode-select -s /Applications/Xcode.app` 또는 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 설정하세요.

```sh
make test     # Rust 엔진 + Swift 테스트
make run      # build/HwpStudio.app 생성(ad-hoc 서명) 후 실행
make dist     # 유니버설 빌드, Developer ID 서명, 공증, build/HwpStudio.zip
```

엔진 프로토콜이 바뀐 커밋을 pull한 뒤에는 예전에 만든 앱이나 `libhwp_engine_abi.a`를 그대로 실행하지 마세요. `make run`은 Rust 엔진과 Swift 앱을 함께 다시 만든 뒤 실행하며, `make test`는 엔진 생성부터 양쪽 전체 테스트까지 확인하는 기준 명령입니다. 앱과 엔진의 프로토콜 버전이 다르면 HwpStudio는 렌더링을 시작하기 전에 열기를 거부합니다(로그에 두 버전이 남습니다). 이때 `make engine` 뒤 `make run`을 실행하세요.

`make dist` 준비:
`rustup target add x86_64-apple-darwin`,
`export SIGN_IDENTITY="Developer ID Application: …"`,
`xcrun notarytool store-credentials hwpstudio`.

Xcode에서 작업하려면 `Package.swift`를 엽니다. 먼저 `make engine`을 한 번 실행해야 합니다.

## 구조

| 경로 | 내용 |
|---|---|
| `App/` | SwiftUI 문서 앱: `Document/`(`HwpDocument`: 열기·편집·저장), `Workspace/`(창, 편집 캔버스), `Editing/`(엔진 세션, 프로토콜, 좌표) |
| `Engine/` | rhwp를 감싸는 Rust C ABI (`hwp-engine-abi`). `editing/`은 편집 세션(명령, 기록, 보존 검사, 좌표, `ffi`) |
| `Vendor/` | 체크섬으로 검증하는 rhwp 소스 압축본과 레이아웃 패치 |
| `Tests/` | Swift 테스트와 생성된 공개 fixture |
| `docs/ROADMAP.md` | 목표(rhwp가 지원하는 기능 전부), 완료한 기능, 다음 단계 |

## 제한

입력은 64 MiB, 출력은 1,000쪽까지입니다. 암호·DRM 문서는 거부합니다. 파싱은 앱 프로세스 안에서 이루어집니다(패닉은 잡지만 메모리 격리는 없음). 글꼴은 번들하지 않고 macOS에 설치된 글꼴을 씁니다.
