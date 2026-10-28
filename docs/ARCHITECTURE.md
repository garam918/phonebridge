# PhoneBridge 아키텍처

## 1. 계층 구조

```
SwiftUI Views (Features/*)
   │  읽기: AppModel, DeviceBroker.devices, BrowserViewModel
   ▼
AppModel (@MainActor, 조합 루트 · DI)          LocalizationManager · AppSettings
   │
   ├── BrowserViewModel ──► DeviceFileSystem (protocol)
   │                           ├── MockDeviceFileSystem   (가상 기기, isMock = true)
   │                           └── MTPDeviceFileSystem    (세션 핸들만 보유)
   │                                     │
   └── DeviceBroker (@MainActor, 상태 머신, 세션 단독 소유)
          ├── USBDeviceMonitoring ── IOKitUSBMonitor (IONotificationPort, 전용 큐)
          ├── USBDeviceClassifier (순수 함수)
          └── MTPDeviceSession (actor, 기기별 DispatchSerialQueue executor)
                    └── MTPBackend ── LibMTPBackend
                                         └── PBMTPBridge.c (C) ── libmtp 1.1.23 ── libusb 1.0.30
```

- **UI → libmtp 직접 호출 없음.** Swift는 `PBMTPBridge.h`만 본다 (브리지 헤더). `libmtp.h`는 C 파일 내부 전용.
- **DeviceBroker**가 세션 생성/종료의 유일한 주체. UI는 `retry`, `refreshStorages`, `fileSystem(for:)`만 사용.

## 2. 동시성 모델

| 구성요소 | 실행 위치 | 이유 |
|---|---|---|
| Views, AppModel, DeviceBroker, BrowserViewModel | MainActor | 상태 소유. 블로킹 호출 없음 |
| IOKitUSBMonitor | 전용 serial `DispatchQueue` | IOKit 알림 포트를 그 큐에 연결, 모든 IOKit 상태를 큐에 한정 |
| MTPDeviceSession | 기기별 `DispatchSerialQueue`를 **custom executor**로 쓰는 actor | libmtp 블로킹 I/O가 메인 스레드·협력 스레드 풀을 막지 않음, 같은 기기 작업은 자동 직렬화 |
| PBMTPBridge `pb_open` | 전역 mutex | libmtp의 기기 열기 경로가 프로세스 전역 libusb 상태를 만짐 |

테스트(`mtpCallsAreSerializedAndNeverOnMainThread`)가 12개 동시 요청에서 최대 동시 호출 1, 메인 스레드 호출 0을 확인한다.

## 3. 연결 상태 머신

```
             USB attach
                │
          ┌─────▼──────┐ 인터페이스 미확정
          │ usbDetected│◄────────────┐
          └─────┬──────┘             │
   분류 결과:    │                    │
   ├─ MTP 후보 ─► connecting ──open──► (storages 비어 있음) waitingForMTP(.deviceLocked) ─폴링─► connected
   │              │  └ preflight busy ─► failed(.deviceBusy(owner))
   │              └ open 실패(1회 자동 재시도 후) ─► failed(error)
   ├─ 충전 전용/ADB만 ─► waitingForMTP(.fileTransferModeRequired)
   ├─ PTP 모드 ───────► waitingForMTP(.ptpModeSelected)
   ├─ iPhone/카메라 ──► unsupported(reason)  (iPhone·iPad 사진은 AppleDeviceManager, D75)
   └─ 무관한 기기 ────► (목록에 표시 안 함)

USB detach ─► reconnecting ─(유예 8초 내 같은 기기 재연결)─► 다시 분류
                         └─(유예 만료)─► disconnected ─► 목록에서 제거
```

- **USB 연결 vs MTP 접근**: `ConnectionState.isUSBPresent`와 `isMTPReady`가 분리돼 있고, 상태 화면은 “USB 연결 / MTP 파일 접근” 2단 체크리스트로 보여 준다.
- **모드 전환**: Android는 “충전 전용 → 파일 전송” 전환 시 PID와 IORegistry ID가 바뀐 채 재열거된다. 논리 ID를 `vendorID + USB 시리얼`로 잡아 같은 기기로 이어 붙인다 (시리얼이 없으면 `locationID`).
- **세대(generation)**: 세션을 만들거나 정리할 때마다 증가. 늦게 도착한 결과는 세대가 다르면 버린다.

## 4. MTP 접근 경로

1. **Preflight (libusb)**: 같은 bus/address의 장치를 열고 MTP 데이터 인터페이스(bulk IN/OUT + interrupt IN)를 claim → 즉시 release. macOS에서 `LIBUSB_ERROR_ACCESS`는 다른 프로세스의 독점 사용을 뜻하므로 `busy`로 보고. libmtp가 장치를 리셋하기 전에 충돌을 구분한다.
2. **소유 프로세스 조회 (IOKit)**: busy면 IORegistry의 `UsbExclusiveOwner` / `IOUserClientCreator`에서 프로세스 이름을 읽어 “ptpcamerad (pid 512)”처럼 표시. 종료는 하지 않는다.
3. **세션 열기 (libmtp)**: `LIBMTP_Detect_Raw_Devices`(버스 전체 프로빙)를 쓰지 않고, IOKit이 준 bus/address/VID/PID로 raw device를 직접 만들고 libmtp 지원 목록에서 quirk 플래그만 가져와 `LIBMTP_Open_Raw_Device_Uncached` 호출. 미등록 Android는 libmtp가 `android.com` 확장을 보고 Android 플래그를 자동 적용.
4. **조회**: `LIBMTP_Get_Storage`, `LIBMTP_Get_Files_And_Folders(storage, parent)` — 폴더 단위 지연 조회 (전체 트리 캐시 없음).
5. **오류**: C 브리지가 libmtp error stack / libusb 코드를 `pb_status`로 변환 → `MTPErrorMapper`가 `DeviceError`로 → `LocalizationManager.message(for:)`가 현지화.

## 5. 파일 식별자

`FileItemID = (DeviceID, storageID: UInt32, objectID: UInt32)`

- MTP 객체 핸들은 저장소 범위에서만 의미가 있어 저장소 ID를 함께 보관.
- 저장소 루트는 `objectID = 0xFFFFFFFF` (libmtp 규약).
- 핸들은 세션이 바뀌면 무효. `DeviceFileSystem.generation`이 다른 핸들은 쓰지 않고, 재연결 시 탐색기는 저장소 루트로 돌아간다.
- 끊긴 세션의 `MTPDeviceFileSystem`은 닫힌 `MTPDeviceSession`을 가리키므로 모든 호출이 `.disconnected`로 안전하게 실패한다.

## 6. 현지화

- `Localizable.xcstrings` (sourceLanguage ko, 키 145개, extractionState manual)
- `LocalizationManager.t(_:)`가 선택 언어의 `.lproj` 번들에서 직접 조회 → `@Observable`이라 언어 변경 시 즉시 다시 그림.
- 설정 저장: `UserDefaults["app.language"]`. AppKit 기본 메뉴(편집/윈도우 등)는 `AppleLanguages`를 따르므로 다음 실행부터 적용.
- 날짜·크기·숫자 포맷도 선택 언어의 `Locale` 사용.

## 7. 디렉터리

```
PhoneBridge/
  App/            PhoneBridgeApp, AppModel(DI), AppSettings, AppCommands, ContentView
  Core/Models     DeviceID, FileItemID, StorageInfo, ConnectionState, DeviceError, FileItem
  Core/USB        USBDeviceSnapshot, USBDeviceClassifier, USBDeviceMonitoring, IOKitUSBMonitor
  Core/MTP        MTPBackend, MTPDeviceSession, LibMTPBackend, MTPErrorMapper
  Core/Broker     DeviceBroker
  Core/FileSystem DeviceFileSystem, MTPDeviceFileSystem, MockDeviceFileSystem, FileSorter
  Core/Logging    Log (os.Logger, subsystem com.phonebridge.PhoneBridge)
  Features/       Sidebar, Browser, Inspector, Status, DeviceState, Settings
  Localization/   LocalizationManager, Localizable.xcstrings
  Native/         PBMTPBridge.h/.c, PhoneBridge-Bridging-Header.h
PhoneBridgeTests/ Support(테스트 더블), Unit, Integration
Config/           PhoneBridge.entitlements
scripts/          bootstrap.sh, check-localization.py
```

## 8. 빌드 설정 요점

- Xcode 프로젝트 (objectVersion 77, 폴더 동기화 그룹), Swift 6 언어 모드, 배포 대상 macOS 26.0
- `PB_HOMEBREW_PREFIX=/opt/homebrew`, libmtp/libusb **정적 링크** + `-liconv`, IOKit/CoreFoundation/Security
- App Sandbox + `com.apple.security.device.usb` + 사용자 선택 파일 읽기/쓰기, Hardened Runtime
- 서명: ad-hoc (`-`) — 개발 인증서 없음

## 9. 파일 관리 · 전송 (3단계)

```
UI (Android 패널 / Mac 패널 / 전송 막대 / 시트)
   │  AppModel+Files: 클립보드, 드래그 페이로드, 파일 동작
   ▼
TransferManager (@MainActor, 직렬 큐)
   ├─ DeviceFileSystem (MTPDeviceFileSystem → MTPDeviceSession → libmtp fd 전송)
   ├─ LocalFileIO (open/write/fsync, errno → DeviceError)
   ├─ LocalVolumeInspecting (여유 공간)
   └─ 충돌 결정: conflictResolver(테스트) 또는 UI 시트(pendingConflict)
PreviewService: 캐시로 다운로드 → Quick Look, MTP 썸네일
LocalBrowserViewModel / LocalAccessManager: Mac 패널, 보안 범위 북마크
```

### 9.1 안전 규칙

| 단계 | 다운로드 (기기 → Mac) | 업로드 (Mac → 기기) |
|---|---|---|
| 사전 검사 | 대상 폴더 쓰기 권한, Mac 여유 공간 ≥ 합계 + 64 MB | 쓰기 capability, 저장소 읽기 전용 여부, 읽기 권한(전부 사전 열거), 기기 여유 공간 |
| 기록 | 같은 폴더의 숨김 스테이징 파일 `.phonebridge-<id>.download` | 기기에 스테이징 이름 `.phonebridge-<id>.part` (MTP rename 지원 시) |
| 검증 | 받은 크기 == MTP 객체 크기 | 기기 객체 메타데이터 크기 == 로컬 크기 |
| 반영 | 새 이름: `moveItem` / 대치: `replaceItemAt`(원자적 교체) | 기존 항목을 `.bak` 이름으로 옮김 → 스테이징을 최종 이름으로 → 백업 삭제. 실패 시 백업 이름 복원 |
| 실패·취소 | 스테이징 파일 삭제, 이미 완료된 파일은 유지 | 스테이징 객체 삭제(고유 이름이므로 사용자 파일을 지울 수 없음). 정리 실패 시 작업에 경고 표시 |
| rename 미지원 기기 | — | 최종 이름으로 직접 업로드, "대치" 금지(둘 다 유지만) |

- 이동(기기 → Mac, Mac → 기기, 기기 내 대체 경로)은 **전체가 검증 완료된 경우에만** 원본을 지운다. Mac 원본은 휴지통으로 보낸다.
- 기기 내 복사/이동: MTP CopyObject/MoveObject 지원 시 기기에서 직접, 아니면 앱 컨테이너 임시 폴더로 내려받았다가 다시 올린다.
- 충돌 비교는 대소문자 무시 (Android 공유 저장소 규칙). 이름은 Finder 방식 "이름 2.확장자".
- 재시도: 같은 요청을 새 작업으로 다시 넣는다. 세션 세대가 바뀌었으면 MTP 핸들 대신 **저장소 루트부터의 경로 이름**으로 다시 찾는다.

### 9.2 진행률·속도

- 전송 중 C 콜백이 `TransferProgress`(Mutex)에 기록하고 취소 플래그를 읽는다 → 세션 actor를 거치지 않고 즉시 취소.
- MainActor 티커가 150 ms마다 작업의 현재 바이트를 갱신하고 지수 평활(0.7/0.3)로 속도를 계산.
- 작업 단위 진행률(파일 수·바이트), 전체 진행률(활성 작업 합계), 남은 시간.

### 9.3 동시성

- 전송은 직렬 큐 하나. 한 기기의 MTP 세션은 한 번에 한 트랜잭션만 처리하므로 긴 전송 중에는 같은 기기의 폴더 탐색이 대기한다 (UI는 로딩 표시).
- 로컬 열거(`planLocal`)와 Mac 폴더 목록은 detached task에서 실행.

### 9.4 UI

- 기본은 Android 탐색기 하나. 툴바 버튼 / ⌥⌘2로 **Android | Mac 2분할**.
- 하단 전송 막대: 진행 중 개수·전체 진행률·속도·남은 시간, 펼치면 작업별 진행률·실패 사유·취소/재시도/제거.
- 드래그 페이로드는 `phonebridge-drag:` 접두어의 텍스트(JSON)로, 별도 UTType 선언 없이 앱 내부에서 주고받는다. Finder에서 오는 파일은 `fileURL`.
- Android 항목은 `DeviceDragItem`으로 끌린다: 파일 프로미스(앞) + 내부 텍스트 페이로드(뒤). 다른 앱이 놓기를 받으면 `DeviceDragExporter`가 전송 대기열로 `tmp/PhoneBridgeDrag/<uuid>/`에 내려받아 넘긴다(D45).

## 10. Finder 통합 (FSKit, 4단계 1차 — 읽기 전용)

```
Finder
  └─ PhoneBridgeFinder.appex (FSKit 모듈, 샌드박스, libmtp 없음)
       PhoneBridgeFileSystem: phonebridge://volume?device=…&storage=…&generation=… 로드
       PhoneBridgeVolume: lookup / enumerate("."·".." 규칙) / getAttributes / read, 쓰기는 EROFS
       FinderBrokerClient ── Unix 소켓 (App Group 컨테이너/finder-broker.sock)
                                │  [UInt32 헤더 길이][UInt32 본문 길이][JSON 헤더][바이트]
PhoneBridge.app                 ▼
  FinderBrokerServer: uid 확인 + 감사 토큰의 상대 코드에 서명 요구 조건 검사(같은 팀의 앱/확장만, D62)
  MTPFileRepository (@MainActor): DeviceBroker.fileSystem(for:) 또는 데모 기기
     ├─ GetPartialObject 지원 → 범위 읽기
     └─ 미지원 → Caches/FinderReadCache 에 스테이징 다운로드·크기 검증 후 범위 읽기
  FinderIntegrationManager: 서버 수명, 확장 상태, 마운트/해제, 자동 마운트, 해제·재연결 처리
     └─ VolumeMounting: SystemVolumeMounter(FSClient.mountSingleVolume) / 테스트용 가짜
          └─ 해제 ── NSXPCConnection ──► PhoneBridgeUnmounter.xpc (샌드박스 없음, JoinExistingSession)
                                           이 빌드의 phonebridge 유형 + /Volumes 아래만 해제(statfs 재확인)
```

- `PhoneBridgeUnmounter.xpc`는 PhoneBridge에서 유일하게 샌드박스 밖에서 돈다. `FSClient` 마운트는 root 소유라 샌드박스 앱은 해제 권한을 얻을 수 없기 때문이다(DECISIONS V7-8, D32). 연결은 같은 팀의 앱 식별자 코드 서명 요구 조건으로만 받는다.
- 마운트 경로 이름은 ASCII(`PhoneBridge <모델>`), Finder 표시 이름은 "기기 – 저장소"(D31). 세션 세대는 실행 시각(ms)에서 시작해 이전 실행의 볼륨과 겹치지 않고, 시작 시 남은 볼륨을 정리한다.

- 프로토콜 버전 3: 헤더 한도(4 MiB)를 넘는 응답은 `encodedInBody` 표시와 함께 본문으로 간다. 클라이언트는 전송 오류 뒤 연결을 새로 연다(D65).
- `Shared/*`(FinderIPC, Unmounter, CodeSigning)는 앱·확장·해제 헬퍼 세 타깃에 함께 컴파일된다.
- Finder가 만드는 MTP 세션은 없다: 확장 프로세스는 libmtp/libusb를 링크하지 않으며, 테스트(`appAndFinderShareOneSerializedSession`)가 IPC 읽기 중 세션 열기 횟수가 늘지 않고 MTP 호출이 계속 직렬화됨을 확인한다.
- 빌드 설정: `PB_APP_GROUP = group.com.phonebridge.shared`, `PB_FINDER_ENTITLEMENTS`(기본: FSKit 권한 없는 ad-hoc용).

## 배포 구성 (5차, D46–D50)
- `PhoneBridge.app/Contents/Frameworks/libmtp.9.dylib`, `libusb-1.0.0.dylib`: `scripts/build-native-deps.sh`가 고정 소스(SHA-256 검증)에서 macOS 15·arm64로 빌드(`Vendor/native`, 릴리스는 매번 다시 빌드, D66), 빌드 단계 "Embed Native Libraries"가 서명 복사.
- `Resources/NOTICE.txt`, `LGPL-2.1.txt`: 오픈소스 고지(도움말 메뉴).
- `DiagnosticsReport`: 상태 요약 + `OSLogStore`(현재 프로세스) → 사용자가 고른 텍스트 파일.
- `LocalStagingJournal`(Mac 쪽 다운로드 임시 파일), `DeviceLeftoverJournal`(기기 쪽), `FinderWriteRecovery`(Finder 쓰기 버퍼): 비정상 종료 복구 세 갈래.
- 릴리스: `scripts/release.sh` → `~/Library/Developer/PhoneBridge/release/<버전-빌드>/`(iCloud 밖).

## iPhone·iPad 사진 (D75)
- `Core/Apple/`: `AppleDeviceManager`(ImageCaptureCore `ICDeviceBrowser`, 메인 액터) → 기기별 `AppleDeviceRecord`(connecting / needsTrust / loading / ready / failed)와 준비된 기기의 `ImageCaptureFileSystem`.
- `ImageCaptureFileSystem: DeviceFileSystem` ← `CameraBackend` 프로토콜(`ICCameraBackend` 실기기 / 테스트 가짜). 읽기·섬네일·삭제만, 쓰기 계열은 `unsupportedOperation`. 브라우저·전송 대기열·드래그·미리보기는 Android와 공용.
- `AppModel`: 기기 ID가 `ios:`로 시작하면 `appleDevices`에서 찾는다(`detailContent` `.appleDeviceState`, `syncBrowser`, 전송 `fileSystemProvider`). `DeviceBroker`(libmtp)는 iPhone을 열지 않는다.

## 연결 시 자동 실행 (D73)
- `PhoneBridgeLauncher.app`(로그인 항목, `Contents/Library/LoginItems`, 백그라운드 전용, 샌드박스 + USB 권한): `IOKitUSBMonitor` 이벤트를 `PhoneAttachDetector`로 판단해 Android 기기가 새로 꽂히면 `NSWorkspace.openApplication`으로 PhoneBridge를 연다. 기기와 통신하지 않는다.
- `USBDetection/`(앱과 런처가 함께 컴파일): `USBDeviceSnapshot`, `USBDeviceClassifier`(+`UnsupportedReason`), `USBDeviceMonitoring`, `IOKitUSBMonitor`, `PhoneAttachDetector`. 앱 전용 `logicalID`(`DeviceID`)는 `PhoneBridge/Core/USB/USBDeviceSnapshot+DeviceID.swift`.
- 앱: `LaunchOnConnectSetting`이 `SMAppService.loginItem(identifier: <앱 ID>.Launcher)`를 등록·해제한다. 상태의 원본은 macOS(로그인 항목)이고 앱은 따로 저장하지 않는다.
