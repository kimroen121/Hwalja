# HwpStudio

HWP·HWPX 문서를 위한 macOS 네이티브 앱(macOS 14 이상). 현재는 읽기 전용 뷰어와 PDF 내보내기를 제공하며, 목표는 편집기입니다.

- 조판 엔진: [rhwp](https://github.com/edwardkim/rhwp) 0.8.6 (MIT). `Vendor/`에 고정 버전과 로컬 패치가 들어 있습니다.
- 화면과 PDF 내보내기는 같은 PDF 바이트를 씁니다. 원본 파일에는 절대 쓰지 않습니다.
- 한컴오피스와 글꼴·쪽 나눔이 다를 수 있습니다. 배치가 의심되면 경고를 띄우고, 내보내기 전에 확인을 받습니다.

## 빌드

필요한 도구: Xcode 16 이상, Rust(`rustup`), `cbindgen` (`brew install cbindgen`).
Command Line Tools만으로는 SwiftUI 매크로가 없어 빌드되지 않습니다. `sudo xcode-select -s /Applications/Xcode.app` 또는 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 설정하세요.

```sh
make test     # Rust 엔진 + Swift 테스트
make run      # build/HwpStudio.app 생성(ad-hoc 서명) 후 실행
make dist     # 유니버설 빌드, Developer ID 서명, 공증, build/HwpStudio.zip
```

`make dist` 준비:
`rustup target add x86_64-apple-darwin`,
`export SIGN_IDENTITY="Developer ID Application: …"`,
`xcrun notarytool store-credentials hwpstudio`.

Xcode에서 작업하려면 `Package.swift`를 엽니다. 먼저 `make engine`을 한 번 실행해야 합니다.

## 구조

| 경로 | 내용 |
|---|---|
| `App/` | SwiftUI·PDFKit 앱: `Document/`(열기·내보내기), `Workspace/`(화면), `Editing/`(엔진 편집 세션) |
| `Engine/` | rhwp를 감싸는 Rust C ABI (`hwp-engine-abi`). `editing/`은 편집 세션(명령, 기록, 보존 검사, 좌표, `ffi`) |
| `Vendor/` | 체크섬으로 검증하는 rhwp 소스 압축본과 레이아웃 패치 |
| `Tests/` | Swift 테스트와 생성된 공개 fixture |
| `docs/ROADMAP.md` | 다음 단계 |

## 제한

입력은 64 MiB, 출력은 1,000쪽까지입니다. 암호·DRM 문서는 거부합니다. 파싱은 앱 프로세스 안에서 이루어집니다(패닉은 잡지만 메모리 격리는 없음). 글꼴은 번들하지 않고 macOS에 설치된 글꼴을 씁니다.
