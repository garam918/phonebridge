# 오픈소스 라이선스 / Open-source licenses

PhoneBridge 앱 안에도 같은 고지가 들어 있습니다(도움말 › 오픈소스 라이선스, `PhoneBridge.app/Contents/Resources/NOTICE.txt`, `LGPL-2.1.txt`).

| 구성 요소 | 버전 | 라이선스 | 배포 형태 | 소스 (SHA-256) |
|---|---|---|---|---|
| libmtp | 1.1.23 | LGPL-2.1-or-later | 동적 라이브러리 `Contents/Frameworks/libmtp.9.dylib`, 수정 없음, `--disable-mtpz` | sourceforge.net/project/libmtp … `libmtp-1.1.23.tar.gz` (`74a2b6e8…0bdeed`) |
| libusb | 1.0.30 | LGPL-2.1-or-later | 동적 라이브러리 `Contents/Frameworks/libusb-1.0.0.dylib`, 수정 없음 | github.com/libusb … `libusb-1.0.30.tar.bz2` (`fea36f34…c6dbaf`) |

전체 URL·해시: `Vendor/native/SOURCES.txt`(빌드 시 생성), 앱의 `NOTICE.txt`.

## LGPL-2.1 준수 방식 (D46)
- **동적 연결**: 두 라이브러리는 앱 실행 파일에 섞이지 않고 별도 `.dylib` 파일로 들어 있어 사용자가 호환 버전으로 교체할 수 있다(LGPL 2.1 §6(b) "적절한 공유 라이브러리 방식"). 교체하면 앱 서명이 깨지므로 사용자가 직접 다시 서명해야 실행된다(`NOTICE.txt`에 안내). macOS 보안 정책은 그대로 둔다.
- **라이선스 전문·저작권 고지**: 앱(`LGPL-2.1.txt`, `NOTICE.txt`)과 DMG(`Licenses.md`)에 포함.
- **소스 제공**: 정확한 업스트림 소스 URL과 SHA-256을 고지하고, 요청 시 3년간 제공한다고 명시. 빌드 방법은 `scripts/build-native-deps.sh`(재현 가능).
- 이전 빌드(2026-10-23 이전)는 Homebrew의 정적 라이브러리(`.a`)를 연결했다. 정적 연결은 재연결 가능한 목적 파일 제공 의무가 생기고, Homebrew 병(bottle)이 macOS 27용으로 빌드되어 macOS 26 지원과도 맞지 않아 바꿨다.

## 확인 필요 (법무)
- 이 문서는 법률 자문이 아니다. 상용 배포 전 LGPL 준수 방식(특히 서명된 앱에서의 라이브러리 교체 안내)을 법무 검토 받기를 권한다.
- PhoneBridge 자체: **MIT 라이선스**(2026-10-25 결정, 저장소 루트 `LICENSE`, 앱 `NOTICE.txt`·`NSHumanReadableCopyright`). LGPL 라이브러리는 동적 연결이라 MIT와 함께 쓸 수 있다.

## Apple 프레임워크
SwiftUI, AppKit, FSKit, IOKit, OSLog, CryptoKit 등은 macOS의 일부로 재배포하지 않는다.
