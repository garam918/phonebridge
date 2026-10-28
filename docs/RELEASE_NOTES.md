# 릴리스 노트 / Release Notes

## 1.0.0 수정 빌드 4 (2026-10-28, 버전 번호 1.0.0 유지) / 1.0.0 updated build 4 (version number unchanged)
빌드 202610281257, SHA-256 `9666ce9f6269fea0d1f8cbce06fbc5c18292ee05b6b900613657354c2846302c`

- **연결 실패 수정**: 수정 빌드 3에서 Android 휴대전화가 "다른 프로그램이 사용 중: ptpcamerad"로 연결되지 않던 문제를 고쳤습니다. iPhone·iPad 사진 탐색은 이제 iPhone·iPad가 연결되어 있을 때만 켜집니다. / **Connection fix**: in updated build 3, Android phones could fail with "in use by another program: ptpcamerad". iPhone & iPad photo browsing now runs only while one is connected.
- 실제 휴대전화로는 아직 확인하지 않았습니다. iPhone·iPad와 Android를 동시에 연결하면 같은 충돌이 생길 수 있습니다. / Not yet verified on a real phone. Connecting an iPhone/iPad and an Android phone at the same time may still conflict.
- 설치 스크립트를 다시 실행하거나 `brew reinstall --cask phonebridge`로 받으세요. / Re-run the install script or `brew reinstall --cask phonebridge`.

## 1.0.0 수정 빌드 3 (2026-10-28, 버전 번호 1.0.0 유지) / 1.0.0 updated build 3 (version number unchanged)
빌드 202610281054, SHA-256 `19e86cd03e8f60e7a19114962a3cd423d5d86342a0faa9fe80d46290bca10258`

- **휴대전화를 연결하면 PhoneBridge 열기**(설정 › 일반, 기본 꺼짐): 켜 두면 Android 기기를 꽂을 때 PhoneBridge가 자동으로 열립니다. / **Open PhoneBridge when a phone is connected** (Settings › General, off by default).
- **iPhone·iPad 사진·동영상**: 연결하면 사이드바 "iPhone·iPad"에 나타나고, 카메라 롤의 사진과 동영상을 탐색·Mac으로 가져오기·삭제할 수 있습니다(기기에 쓰기·이름 변경은 iOS가 허용하지 않음). 처음 연결할 때 기기에서 '신뢰'를 선택해야 합니다. "휴대전화를 연결하면 PhoneBridge 열기"도 iPhone·iPad에 적용됩니다. 실제 iPhone·iPad로는 아직 검증하지 않았습니다. / **iPhone & iPad photos and videos**: browse, import to the Mac and delete camera-roll photos and videos (iOS does not allow writing or renaming). Trust the Mac on the device the first time. "Open PhoneBridge when a phone is connected" also covers iPhone and iPad. Not yet verified on a real iPhone or iPad.
- Finder 복구 알림과 설정에 아이콘이 비어 보이던 문제를 고쳤습니다. / Fixed a missing icon in the Finder recovery notice and settings.
- **멈춤 수정**: 휴대전화 파일을 오른쪽 Mac 창, 휴대전화 창의 빈 곳이나 폴더 위로 끌어다 놓으면 앱이 응답 없음 상태로 멈추던 문제를 고쳤습니다. 폴더 위에 놓은 Finder 파일은 이제 그 폴더로 올라갑니다. 1.0.0의 모든 빌드에 있던 문제입니다. 그동안에는 우클릭 › '다운로드'나 툴바의 다운로드 버튼, 휴대전화 안에서는 잘라내기·붙여넣기를 쓰면 됩니다. / **Hang fixed**: dragging phone files onto the Mac pane, an empty spot of the phone pane or a folder in it froze the app. Finder files dropped on a folder now go into that folder. This affected every 1.0.0 build; until the update, use right-click › Download or the Download toolbar button, and Cut/Paste within the phone.
- 설정 › Finder에서 복구 파일을 다른 디스크에 저장할 때 큰 파일이면 앱이 잠시 응답하지 않던 문제를 고쳤습니다(복사를 백그라운드에서 함). / Saving a recovered Finder file to another disk no longer stalls the app.
- USB 사용 목적이 '파일 전송'이 아닐 때 '잠금 해제' 대신 '파일 전송/Android Auto' 선택까지 함께 안내합니다. / When the phone's USB mode is not File transfer, the guidance now says so instead of only asking to unlock.
- 이미 1.0.0을 설치했다면 업데이트 알림이 오지 않습니다. 설치 스크립트를 다시 실행하거나 `brew reinstall --cask phonebridge`로 받으세요. / Same version number: re-run the install script or `brew reinstall --cask phonebridge`.


## 1.0.0 수정 빌드 2 (2026-10-26, 버전 번호 1.0.0 유지)

- **새 앱 아이콘**: Android(녹색)와 Mac(파란색)을 잇는 다리.
- **가상 기기(테스트용) 제거**: 사이드바의 "가상 기기 (테스트용)"와 설정의 "가상 기기 표시"가 없어졌습니다.
- **Finder 쓰기는 스위치 하나**: 설정 › Finder › "Finder에서 쓰기 허용(실험적)"을 켜면 휴대전화에 씁니다(이전에는 가상 기기용 스위치와 실제 기기용 스위치가 따로 있었음). 이전에 켜 두었더라도 업데이트 후에는 꺼진 상태로 시작하며, 다시 켤 때 확인을 묻습니다.
- 이미 1.0.0을 설치했다면 업데이트 알림이 오지 않습니다. 설치 스크립트를 다시 실행하거나 `brew reinstall --cask phonebridge`로 받으세요.

## 1.0.0 updated build 2 (2026-10-26, version number unchanged)

- **New app icon**: a bridge between Android (green) and the Mac (blue).
- **Virtual (test) device removed**: the "Virtual devices (testing)" sidebar entry and the "Show virtual device" setting are gone.
- **One switch for Finder writing**: Settings › Finder › "Allow writing from Finder (experimental)" now writes to phones (previously there were separate switches for the virtual device and real devices). It starts off after this update, even if it was on before, and asks for confirmation when turned on.
- If 1.0.0 is already installed you will not be notified; run the install script again or `brew reinstall --cask phonebridge`.

---

## 1.0.0 수정 빌드 (2026-10-25, 버전 번호 1.0.0 유지)

보안·데이터 보호 수정 빌드입니다. 새 기능은 없고, 버전 번호는 1.0.0 그대로입니다. 이미 1.0.0을 설치했다면 업데이트 알림이 오지 않으니 설치 스크립트를 다시 실행하거나 `brew reinstall --cask phonebridge`로 받으세요. 이번 빌드부터 PhoneBridge는 MIT 라이선스로 공개됩니다. 전체 점검 결과는 `docs/AUDIT_2026-10-23.md`, 결정 기록은 `docs/DECISIONS.md` D61–D66에 있습니다.

### 파일을 잃을 수 있던 문제
- **잘라내기(이동)**: 전송 중 폴더에 새로 생긴 파일이나, 기기가 목록에 보여 주지 못한 파일까지 원본 폴더와 함께 지워질 수 있던 문제를 고쳤습니다. 이제 옮긴 항목만 지우고, 남은 것이 있는 폴더는 기기에 그대로 둡니다(전송 목록에 표시).
- **같은 이름의 두 항목을 한 번에 옮길 때**: 한 작업이 자기가 방금 만든 파일을 덮어쓰지 않고 "이름 2"로 둘 다 남깁니다.
- **기기 안 복사·이동의 "대치"**: 도중에 케이블이 빠져도 기존 파일이 다음 연결 때 복원됩니다.
- **Finder에서 큰 파일 "대치"**: 업로드가 오래 걸리다 실패해도 원본이 되살아납니다. 이름 변경을 지원하지 않는 기기에서는 Finder의 파일 삭제를 막습니다(PhoneBridge 창에서는 삭제 가능).
- **복구 목록의 "Mac에 저장"**: 저장이 실패해도 Mac의 기존 파일이 지워지지 않습니다.

### 보안
- Finder 연결 통로는 같은 개발자가 서명한 PhoneBridge 구성 요소만 받습니다(이전에는 다른 프로그램이 이름만 흉내 내도 접근할 수 있었음).
- 비정상적인 기기가 보낸 `..`·`/` 같은 파일 이름이 고른 폴더 밖에 쓰이지 않습니다.
- 시스템 기록(로그)과 진단 보고서에 기기 일련번호·Mac 경로·파일 이름이 공개 값으로 남지 않습니다.
- 배포 빌드는 매번 검증된 소스에서 libmtp·libusb를 다시 빌드합니다.

### 안정성
- 항목이 수만 개인 폴더를 Finder에서 열면 볼륨 전체가 멈추던 문제를 고쳤습니다.
- 전송 중 종료하면 확인을 묻습니다. 전송 중에 창을 닫으면 전송을 계속합니다(Dock 아이콘으로 창을 다시 엽니다).
- 종료 때 전송이 멈춰 있어도 Finder 볼륨 해제와 기기 연결 정리를 항상 합니다.

### 업데이트할 때
- Finder에 PhoneBridge 볼륨이 연결된 채 업데이트했다면, 볼륨을 한 번 꺼낸 뒤 다시 연결하세요(앱과 Finder 확장 사이 통신 방식이 바뀜).

---

## 1.0.0 updated build (2026-10-25, version number unchanged)

A security and data-protection build; no new features, same version number 1.0.0. If you already have 1.0.0 you get no update prompt: run the install script again or `brew reinstall --cask phonebridge`. From this build on, PhoneBridge is open source under the MIT License.

**Data loss fixes**
- Moving (cut) a folder off the device no longer deletes files that appeared during the transfer or that the device could not list; folders that still hold such items stay on the device and are reported.
- One move never overwrites a file it just wrote (two items with the same name are kept as "name 2").
- Replacing a file inside the device keeps a recoverable backup if the cable is pulled.
- A slow Finder "Replace" that fails brings the original back. On devices without rename, Finder can no longer delete files (use the PhoneBridge window).
- "Save to Mac" in the recovery list no longer deletes the existing Mac file when the save fails.

**Security**
- The Finder connection only accepts PhoneBridge components signed by the same developer.
- File names such as `..` or names containing `/` from a misbehaving device can no longer write outside the chosen folder.
- Device serial numbers, Mac paths and file names are no longer logged as public values (system log and diagnostics report).
- Release builds always rebuild libmtp and libusb from verified sources.

**Stability**
- Opening a folder with tens of thousands of items in Finder no longer stalls the whole volume.
- Quitting during a transfer asks first; closing the window during a transfer keeps it running (reopen from the Dock).
- Quitting always unmounts Finder volumes and closes device sessions, even if a transfer is stuck.

**When updating**: if a PhoneBridge volume was mounted in Finder, eject it and connect again (the app–extension protocol changed).
