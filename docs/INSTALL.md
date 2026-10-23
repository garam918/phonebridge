# PhoneBridge 설치 및 제거 / Install and uninstall

## 한국어

### 필요 환경
- Apple Silicon(M1 이상) Mac, macOS 15(Sequoia) 이상
- Finder 사이드바 연결은 macOS 26 이상(15에서는 PhoneBridge 창으로 모두 사용)
- Android 기기와 **데이터 전송이 되는** USB 케이블(충전 전용 케이블은 기기가 보이지 않음)

### 설치
1. `PhoneBridge-<버전>.dmg`를 엽니다.
2. `PhoneBridge`를 `Applications`(응용 프로그램) 폴더로 끌어 놓습니다.
3. 응용 프로그램 폴더에서 PhoneBridge를 엽니다. 처음 실행하면 시작하기 안내가 나타납니다.
4. Android 기기를 연결하고 잠금을 해제한 뒤, 알림에서 USB 사용 목적을 **파일 전송**으로 바꿉니다. "휴대전화 데이터에 대한 접근을 허용할까요?"가 나오면 **허용**을 누릅니다.

> 배포본은 Apple의 공증(notarization)을 받은 DMG여야 합니다. "확인되지 않은 개발자" 경고가 나오면 공식 배포본이 아니므로 열지 마세요. PhoneBridge는 macOS 보안 설정을 바꾸라고 요구하지 않습니다.

### 터미널로 설치
- 설치 스크립트: `curl -fsSL https://github.com/garam918/phonebridge/releases/latest/download/install.sh | bash`
  - 받은 DMG의 체크섬, 개발자 서명(Developer ID, 팀 KB2PLX99H6), Apple 공증을 확인한 뒤에만 설치합니다.
  - `--user`: 관리자 권한 없이 `~/Applications`에 설치, `--check`: 확인만, `--uninstall [--zap]`: 제거
- Homebrew: `brew install --cask garam918/phonebridge/phonebridge` (제거: `brew uninstall --zap --cask phonebridge`)
- DMG 내려받기: https://github.com/garam918/phonebridge/releases/latest

### Finder 연결(선택)
Finder 사이드바에서 기기를 일반 디스크처럼 보려면 파일 시스템 확장을 한 번 켜야 합니다. macOS 보안 정책상 앱이 대신 켤 수 없습니다.
1. PhoneBridge › 설정 › Finder에서 **Finder 통합 사용**을 켭니다.
2. 확장이 꺼져 있으면 **시스템 설정 열기**를 누릅니다. 또는 직접 **시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램 › 파일 시스템 확장**에서 **PhoneBridge Finder**를 켭니다.
3. 기기를 다시 연결하거나 설정 › Finder에서 **Finder에 연결**을 누르면 Finder 사이드바의 위치 아래에 기기 저장소가 나타납니다.
- Finder 연결은 기본적으로 **읽기 전용**입니다. 쓰기는 실험 기능이며 가상 기기에서만 열려 있습니다(정식 지원 전).

### 업데이트
새 DMG의 PhoneBridge로 응용 프로그램 폴더의 앱을 대치합니다. 설정과 기록은 유지됩니다. 업데이트 전에 진행 중인 전송이 없는지 확인하고 앱을 종료하세요.

### 제거
1. 기기가 Finder에 연결되어 있으면 PhoneBridge에서 **기기 › 안전하게 연결 해제**(⌘E)를 누르거나 앱을 종료합니다(종료 시 PhoneBridge 볼륨을 해제함).
2. PhoneBridge를 종료하고 응용 프로그램 폴더의 `PhoneBridge.app`을 휴지통으로 옮깁니다(또는 `install.sh --uninstall`, `brew uninstall --cask phonebridge`). Finder 확장과 해제 도우미는 앱 안에 들어 있어 함께 제거됩니다.
3. (선택) 설정·기록·캐시까지 지우려면 Finder에서 ⇧⌘G로 다음 폴더를 열어 휴지통으로 옮깁니다.
   - `~/Library/Containers/com.phonebridge.PhoneBridge`
   - `~/Library/Containers/com.phonebridge.PhoneBridge.FinderVolume`
   - `~/Library/Group Containers/group.com.phonebridge.shared`
4. 휴대전화에는 아무것도 설치되지 않으므로 제거할 것이 없습니다. PhoneBridge가 휴대전화에 만든 임시 파일(`.phonebridge-`로 시작하는 숨김 파일)은 다음 연결 때 자동으로 정리되며, 제거 후에도 남아 있으면 휴대전화의 파일 앱에서 지워도 됩니다.

## English

### Requirements
- Apple Silicon Mac (M1 or later), macOS 15 (Sequoia) or later
- The Finder sidebar needs macOS 26 or later (on 15, everything works in the PhoneBridge window)
- A USB cable that carries **data** (charge-only cables do not show the device)

### Install
1. Open `PhoneBridge-<version>.dmg`.
2. Drag `PhoneBridge` to the `Applications` folder.
3. Open PhoneBridge from Applications. The first launch shows a short Getting Started guide.
4. Connect the Android device, unlock it and set the USB mode to **File transfer** in its notification. Tap **Allow** when it asks to allow access to phone data.

> Release builds are notarized DMGs. If macOS says the developer cannot be verified, it is not an official build; do not open it. PhoneBridge never asks you to change macOS security settings.

### Install from Terminal
- Script: `curl -fsSL https://github.com/garam918/phonebridge/releases/latest/download/install.sh | bash` — installs only after checking the checksum, the Developer ID signature (team KB2PLX99H6) and Apple notarization. Options: `--user`, `--check`, `--uninstall [--zap]`.
- Homebrew: `brew install --cask garam918/phonebridge/phonebridge` (remove: `brew uninstall --zap --cask phonebridge`).

### Finder (optional)
To see the device in the Finder sidebar like a disk, turn on the file system extension once. macOS does not let apps do this for you.
1. In PhoneBridge › Settings › Finder, turn on **Enable Finder integration**.
2. If the extension is off, click **Open System Settings**, or go to **System Settings › General › Login Items & Extensions › File System Extensions** and enable **PhoneBridge Finder**.
3. Reconnect the device or click **Mount in Finder**; the storage appears under Locations in the Finder sidebar.
- Finder access is **read-only** by default. Writing is experimental and only enabled for the virtual device.

### Update
Replace PhoneBridge in Applications with the one from the new DMG. Settings are kept. Quit the app (with no transfers running) first.

### Uninstall
1. If a device is mounted in Finder, choose **Device › Safely Disconnect** (⌘E) or quit PhoneBridge (quitting unmounts its volumes).
2. Quit PhoneBridge and move `PhoneBridge.app` from Applications to the Trash (or `install.sh --uninstall`, or `brew uninstall --cask phonebridge`). The Finder extension and the unmount helper live inside the app and go with it.
3. (Optional) To remove settings, logs and caches, open these folders with ⇧⌘G in Finder and move them to the Trash:
   - `~/Library/Containers/com.phonebridge.PhoneBridge`
   - `~/Library/Containers/com.phonebridge.PhoneBridge.FinderVolume`
   - `~/Library/Group Containers/group.com.phonebridge.shared`
4. Nothing is installed on the phone. Hidden temporary files PhoneBridge may have left there (names starting with `.phonebridge-`) are cleaned at the next connection; after uninstalling you can delete any that remain with the phone's Files app.
