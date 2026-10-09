# 개발

## 빌드

필요한 도구: Xcode 16 이상, Rust(`rustup`), `cbindgen` (`brew install cbindgen`).
Command Line Tools만으로는 SwiftUI 매크로가 없어 빌드되지 않습니다. `sudo xcode-select -s /Applications/Xcode.app` 또는 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 설정하세요.

```sh
make test     # Rust 엔진 + Swift 테스트
make run      # build/hwalja.app 생성(ad-hoc 서명) 후 실행
make dist     # 유니버설 빌드, Developer ID 서명, 공증, build/hwalja.zip
```

엔진 프로토콜이 바뀐 커밋을 pull한 뒤에는 예전에 만든 앱이나 `libhwp_engine_abi.a`를 그대로 실행하지 마세요. 앱과 엔진의 프로토콜 버전이 다르면 hwalja는 렌더링을 시작하기 전에 열기를 거부합니다(로그에 두 버전이 남습니다). 이때 `make engine` 뒤 `make run`을 실행하세요.

`make dist` 준비:
`rustup target add x86_64-apple-darwin`,
`export SIGN_IDENTITY="Developer ID Application: …"`,
`xcrun notarytool store-credentials hwalja`.

Xcode에서 작업하려면 `Package.swift`를 엽니다. 먼저 `make engine`을 한 번 실행해야 합니다.

## 구조

| 경로 | 내용 |
|---|---|
| `App/` | SwiftUI 문서 앱: `Document/`(`HwpDocument`: 열기·편집·저장), `Workspace/`(창, 편집 캔버스), `Editing/`(엔진 세션, 프로토콜, 좌표) |
| `Engine/` | rhwp를 감싸는 Rust C ABI (`hwp-engine-abi`). `editing/`은 편집 세션(명령, 기록, 보존 검사, 좌표, `ffi`) |
| `Vendor/` | 체크섬으로 검증하는 rhwp 소스 압축본과 패치 (`Vendor/README.md`) |
| `Tests/` | Swift 테스트와 생성된 공개 fixture |
| `docs/` | `ROADMAP.md`(목표와 남은 기능), `FEATURES.md`(기능별 상태), `BUG_HANDOFF.md`(남은 버그, 수동 점검), `GUIDELINES.md`(작업 지침) |

## 제한

입력은 64 MiB, 출력은 1,000쪽까지입니다. 파싱은 앱 프로세스 안에서 이루어집니다(패닉은 잡지만 메모리 격리는 없음). 글꼴은 번들하지 않고 macOS에 설치된 글꼴을 씁니다.

## 라이선스

앱 번들의 `ThirdPartyNotices.txt`는 `scripts/bundle-app.sh`가 `scripts/third-party-notices.py`로 만듭니다. rhwp·SwiftMath 고지(`App/Resources/ThirdPartyNotices.txt`) 뒤에 엔진에 링크되는 Rust 크레이트마다 라이선스 전문을 붙이며, 고지가 필요한데 라이선스 파일이 없는 크레이트가 있으면 빌드가 멈춥니다. 링크되는 크레이트는 모두 MIT·Apache-2.0·BSD·Zlib 계열입니다.
