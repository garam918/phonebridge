# PhoneBridge

USB로 연결한 Android 휴대전화·태블릿의 파일을 Mac에서 탐색하고 옮기는 macOS 앱입니다.
A macOS app to browse and move files on an Android phone or tablet connected over USB.

이 저장소는 **배포 전용**입니다(설치 파일, 설치 안내, 라이선스 고지). 소스 코드는 포함되어 있지 않습니다.
This repository hosts **releases only** (installers, guides, license notices); it does not contain the source code.

## 요구 사항 / Requirements
- Apple Silicon Mac (M1 이상 / M1 or later)
- macOS 15 (Sequoia) 이상 / or later
- Finder 사이드바 연결은 macOS 26 이상 / Finder sidebar access needs macOS 26 or later
- 데이터 전송이 되는 USB 케이블, 기기에서 "파일 전송" 모드 / a data USB cable, "File transfer" mode on the device

## 설치 / Install

**DMG** — [최신 릴리스 / latest release](https://github.com/garam918/phonebridge/releases/latest)에서 `PhoneBridge-<버전>.dmg`를 내려받아 열고, PhoneBridge를 응용 프로그램 폴더로 끌어 놓습니다. / Download the DMG, open it and drag PhoneBridge to Applications.

**터미널 / Terminal (script)**
```sh
curl -fsSL https://github.com/garam918/phonebridge/releases/latest/download/install.sh | bash
```
설치 전에 체크섬, 개발자 서명(Developer ID, 팀 `KB2PLX99H6`), Apple 공증을 확인하고, 하나라도 맞지 않으면 설치하지 않습니다. / Installs only after verifying the checksum, the Developer ID signature (team `KB2PLX99H6`) and Apple notarization.
옵션 / options: `--user` (~/Applications), `--check`, `--uninstall [--zap]`

**Homebrew**
```sh
brew install --cask garam918/phonebridge/phonebridge
```

제거 / Uninstall: `brew uninstall --zap --cask phonebridge`, `install.sh --uninstall --zap`, 또는 앱을 휴지통으로 / or move the app to the Trash ([INSTALL.md](docs/INSTALL.md)).

## 주요 기능 / Features
- 기기 연결 상태 안내(파일 전송 모드, 잠금, 다른 프로그램 점유 등) / connection guidance
- 탐색, 정렬, 검색, 훑어보기(Quick Look), 썸네일 / browse, sort, search, Quick Look, thumbnails
- Mac ↔ Android 전송, 원본 보호 교체, 진행률·취소·재시도 / transfers with safe replace, progress, cancel, retry
- Android → Finder로 바로 끌어 놓기 / drag straight from Android to Finder
- Finder 사이드바에 기기 저장소 연결(macOS 26+, 기본 읽기 전용) / Finder volumes (macOS 26+, read-only by default)
- 한국어·영어, 앱 안에서 즉시 전환 / Korean and English, switchable in-app

## 호환성 / Compatibility
실제 기기로 검증한 것은 **Samsung Galaxy S25 Edge (SM-S937N)** 입니다. 다른 Android 기기는 표준 MTP를 쓰면 동작할 가능성이 높지만 검증되지 않았습니다. macOS 15·26에서의 실행은 아직 확인 중입니다.
Verified on real hardware: **Samsung Galaxy S25 Edge (SM-S937N)**. Other Android devices using standard MTP will likely work but are not verified yet. Running on macOS 15 and 26 is still being checked.

## 개인정보 / Privacy
PhoneBridge는 아무 데이터도 외부로 보내지 않습니다(네트워크 권한 없음). / PhoneBridge sends nothing anywhere (no network entitlement). → [PRIVACY.md](docs/PRIVACY.md)

## 사용 설명서 / Guides
[한국어](docs/USER_GUIDE.ko.md) · [English](docs/USER_GUIDE.en.md) · [설치·제거 / Install](docs/INSTALL.md)

## 오픈소스 / Open source
PhoneBridge에는 libmtp 1.1.23, libusb 1.0.30(LGPL-2.1-or-later)이 수정 없이 동적 라이브러리로 포함되어 있습니다. / Includes libmtp and libusb (LGPL-2.1-or-later), unmodified, as dynamic libraries. → [NOTICE.txt](NOTICE.txt), [LGPL-2.1.txt](LGPL-2.1.txt)

문제 신고 / Issues: 앱의 도움말 › 진단 정보 내보내기로 만든 파일을 첨부해 [Issues](https://github.com/garam918/phonebridge/issues)에 올려 주세요(파일·폴더 이름은 포함되지 않습니다). / Attach the file from Help › Export Diagnostics (no file or folder names).
