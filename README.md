# PhoneBridge

USB로 연결한 Android 휴대전화·태블릿의 파일을 Mac에서 탐색하고 옮기는 macOS 네이티브 앱입니다.
A native macOS app to browse and move files on an Android phone or tablet connected over USB.

- 전용 탐색기 창과 Finder 사이드바 연결(macOS 26+) / a dedicated browser window and Finder volumes (macOS 26+)
- Swift · SwiftUI · FSKit, libmtp · libusb
- 한국어·영어 / Korean and English
- 무료, 광고·결제·가입 없음 / free, with no ads, payments or sign-up
- [MIT 라이선스](LICENSE)

웹사이트 / Website: <https://garam918.github.io/phonebridge/>

## 요구 사항 / Requirements
- Apple Silicon Mac (M1 이상 / M1 or later)
- macOS 15 (Sequoia) 이상 / or later
- Finder 사이드바 연결은 macOS 26 이상 / Finder volumes need macOS 26 or later
- 데이터 전송이 되는 USB 케이블, 기기에서 "파일 전송" 모드 / a data USB cable, "File transfer" mode on the device

## 설치 / Install

**DMG** — [최신 릴리스 / latest release](https://github.com/garam918/phonebridge/releases/latest)에서 `PhoneBridge-<버전>.dmg`를 내려받아 열고, PhoneBridge를 응용 프로그램 폴더로 끌어 놓습니다. / Download the DMG, open it and drag PhoneBridge to Applications.

**터미널 / Terminal (script)**
```sh
curl -fsSL https://github.com/garam918/phonebridge/releases/latest/download/install.sh | bash
```
설치 전에 체크섬, 개발자 서명(Developer ID, 팀 `KB2PLX99H6`), Apple 공증을 확인하고, 하나라도 맞지 않으면 설치하지 않습니다. 기존 앱은 휴지통으로 옮깁니다.
Installs only after verifying the checksum, the Developer ID signature (team `KB2PLX99H6`) and Apple notarization; a previous copy goes to the Trash.
옵션 / options: `--user` (~/Applications), `--check`, `--dmg <file|URL>`, `--uninstall [--zap]`

**Homebrew**
```sh
brew trust --cask garam918/phonebridge/phonebridge   # Homebrew 7 이상: 외부 저장소의 Cask를 한 번 허용 / allow this tap's cask once
brew install --cask garam918/phonebridge/phonebridge
```

**업데이트 / Updating** — PhoneBridge는 외부에 접속하지 않으므로 새 버전을 스스로 알리지 않습니다. 도움말 › **업데이트 확인…**이 릴리스 페이지를 브라우저로 열어 주며(메뉴에 현재 버전이 표시됨), 새 버전이면 DMG를 받거나 설치 스크립트를 다시 실행하세요. Homebrew는 `brew upgrade`로 받습니다. 1.0.1부터는 배포마다 버전 번호가 올라갑니다(이전 1.0.0 수정 빌드들은 번호가 같아 한 번은 직접 받아야 합니다).
PhoneBridge never contacts a server, so it cannot announce new versions itself. Help › **Check for Updates…** opens the releases page in your browser (the menu shows your version); if there is a newer one, download the DMG or re-run the install script. Homebrew users: `brew upgrade`. From 1.0.1 every release has a new version number (the earlier 1.0.0 builds shared one, so that update is manual).
```sh
brew update && brew upgrade --cask phonebridge
```

**Finder 연결 켜기 / Turn on Finder volumes** (macOS 26+)
1. PhoneBridge 설정 › Finder › Finder 연결 / PhoneBridge Settings › Finder
2. 시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램 › 파일 시스템 확장 › **PhoneBridge Finder** / System Settings › General › Login Items & Extensions › File System Extensions

제거 / Uninstall: `brew uninstall --zap --cask phonebridge`, `install.sh --uninstall --zap`, 또는 앱을 휴지통으로 / or move the app to the Trash ([docs/INSTALL.md](docs/INSTALL.md)).

## 주요 기능 / Features
- 기기 연결 상태 안내(파일 전송 모드, 잠금, 다른 프로그램 점유 등) / connection guidance (file-transfer mode, locked screen, another app holding the device)
- 탐색, 정렬, 검색, 훑어보기(Quick Look), 썸네일 / browse, sort, search, Quick Look, thumbnails
- Mac ↔ Android 전송: 원본을 지키는 교체, 크기 검증, 진행률·취소·재시도 / transfers with safe replace, size verification, progress, cancel, retry
- 끌어 놓기: Android → Finder·바탕화면, Finder → 휴대전화 창·폴더, 두 창 사이 / drag and drop: Android to Finder or the desktop, Finder into the phone pane or a folder, and between the two panes
- Finder 사이드바에 기기 저장소 연결(기본 읽기 전용) / Finder volumes for each storage (read-only by default)
- 휴대전화를 연결하면 PhoneBridge 자동 열기(설정 › 일반, 기본 꺼짐, 로그인 항목 도우미 사용) / open PhoneBridge when a phone is connected (Settings › General, off by default; uses a login item helper)
- iPhone·iPad 사진·동영상 탐색·가져오기·삭제(macOS 이미지 캡처 사용, 실기기 미검증) / iPhone & iPad photos and videos: browse, import, delete (via macOS Image Capture; not yet verified on a device)
  - iPhone·iPad와 Android를 동시에 연결하면 Android 연결이 실패할 수 있습니다([K50](docs/KNOWN_ISSUES.md)). / Connecting an iPhone or iPad together with an Android phone may make the Android connection fail.
- 앱 안에서 즉시 바뀌는 한국어·영어 / Korean and English, switchable without restarting

## 호환성 / Compatibility
실제 기기로 전송까지 검증한 것은 **Samsung Galaxy S25 Edge (SM-S937N)**, Finder 연결로 탐색·읽기를 확인한 것은 **Galaxy Z Flip5 (SM-F731N)** 입니다. 표준 MTP를 쓰는 다른 Android 기기도 동작할 가능성이 높지만 검증되지 않았습니다.
Verified on hardware: transfers on **Galaxy S25 Edge (SM-S937N)**, Finder browsing and reads on **Galaxy Z Flip5 (SM-F731N)**. Other Android devices using standard MTP will likely work but are not verified yet.

## 개인정보 / Privacy
PhoneBridge는 무료이며 광고·결제·가입·사용 통계 수집이 없고, 아무 데이터도 외부로 보내지 않습니다(네트워크 권한 없음). 시스템 기록에는 파일 이름·Mac 경로·기기 일련번호를 남기지 않습니다. → [docs/PRIVACY.md](docs/PRIVACY.md)
PhoneBridge is free, with no ads, payments, sign-up or analytics, and sends nothing anywhere (no network entitlement). It also keeps file names, Mac paths and device serial numbers out of the system log.

## 사용 설명서 / Guides
[한국어](docs/USER_GUIDE.ko.md) · [English](docs/USER_GUIDE.en.md) · [설치·제거 / Install](docs/INSTALL.md)

## 소스에서 빌드 / Building from source

필요한 것 / Needs: Apple Silicon Mac, Xcode(macOS 26 SDK 이상 / or later), `pkgconf` (`brew install pkgconf`).

```sh
scripts/bootstrap.sh   # libusb·libmtp를 고정 소스(SHA-256 검증)에서 빌드 → Vendor/native
xcodebuild -project PhoneBridge.xcodeproj -scheme PhoneBridge -destination 'platform=macOS' build
xcodebuild -project PhoneBridge.xcodeproj -scheme PhoneBridge -destination 'platform=macOS' test
python3 scripts/check-localization.py && python3 scripts/check-log-privacy.py
```

- 기본 빌드는 ad-hoc 서명이라 App Group이 없어 **Finder 연결은 동작하지 않습니다**(앱 창은 모두 동작). Finder 연결에는 Apple Developer 팀 서명과 FSKit 권한이 필요합니다(`scripts/build-team-signed.sh`, [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)).
  Default builds are ad-hoc signed without an App Group, so **Finder volumes do not work** (the app window does). They need a team-signed build with the FSKit entitlement.
- 직접 만든 빌드를 배포할 때는 **다른 이름과 번들 ID**(`com.phonebridge.*` 대신)를 써 주세요. MIT 라이선스는 코드 사용을 허락하지만, 같은 이름의 앱이 여럿이면 사용자가 공식 빌드와 구분할 수 없습니다.
  If you distribute your own build, please use **a different name and bundle ID** so users can tell it apart from the official build.
- 개발 Mac에서 Finder 마운트가 `extensionKit` 오류로 실패하면 [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) K44를 보세요(다른 빌드 사본이 확장을 가로챔).

### 구조 / Layout
| 경로 / Path | 내용 / Contents |
|---|---|
| `PhoneBridge/` | 앱: SwiftUI 화면, 기기 브로커, 전송, MTP 세션, C 브리지(`Native/`) / the app |
| `PhoneBridgeFinder/` | FSKit 확장(Finder 볼륨, libmtp 없음) / FSKit extension |
| `PhoneBridgeUnmounter/` | 볼륨 해제 XPC 헬퍼 / unmount helper |
| `PhoneBridgeLauncher/` | 로그인 항목 도우미(휴대전화를 꽂으면 앱 열기, 기기와 통신하지 않음) / login item that opens the app when a phone is plugged in |
| `USBDetection/` | IOKit USB 감시·기기 분류(앱과 도우미 공용) / USB monitoring and device classification, shared by the app and the launcher |
| `Shared/` | 앱·Finder 확장·해제 헬퍼 공용(Finder IPC, 서명 검증, 로그) / shared by the app, the Finder extension and the unmount helper |
| `PhoneBridgeTests/` | 단위·통합 테스트(테스트용 가상 기기, 모의 MTP 백엔드) / tests |
| `scripts/` | 의존성 빌드, 릴리스, 설치, 검사 스크립트 / scripts |
| `docs/` | 설계·결정·점검 기록 / design and decision records |

설계는 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), 결정 기록은 [docs/DECISIONS.md](docs/DECISIONS.md), 알려진 문제는 [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md), 보안·안정성 점검은 [docs/AUDIT_2026-10-23.md](docs/AUDIT_2026-10-23.md)에 있습니다.

## 문제 신고 / Reporting issues
앱의 도움말 › 진단 정보 내보내기로 만든 파일을 첨부해 [Issues](https://github.com/garam918/phonebridge/issues)에 올려 주세요(파일·폴더 이름은 포함되지 않습니다).
Attach the file from Help › Export Diagnostics (it contains no file or folder names).

**보안 문제는 자세한 내용을 공개 Issue에 쓰지 마세요.** 제목 "Security contact"로 Issue를 열어 영향받는 부분만 적으면, 비공개로 받을 방법을 답해 드립니다 → [SECURITY.md](SECURITY.md)
**For security problems, do not post details in a public issue.** Open an issue titled "Security contact" naming only the affected part, and you will get a private way to send the details → [SECURITY.md](SECURITY.md)

## 라이선스 / License
PhoneBridge는 [MIT 라이선스](LICENSE)로 배포됩니다. / PhoneBridge is released under the [MIT License](LICENSE).

포함된 libmtp 1.1.23과 libusb 1.0.30은 LGPL-2.1-or-later이며, 수정 없이 동적 라이브러리로 들어 있습니다. → [NOTICE.txt](PhoneBridge/Resources/Licenses/NOTICE.txt), [LGPL-2.1.txt](PhoneBridge/Resources/Licenses/LGPL-2.1.txt), [docs/LICENSES.md](docs/LICENSES.md)
The bundled libmtp and libusb are LGPL-2.1-or-later, unmodified, linked dynamically.
