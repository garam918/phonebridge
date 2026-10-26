# 설계 결정 기록 (ADR)

## D1. 1·2단계를 함께 구축 (2026-10-22)
2단계 착수 시 저장소에 `CLAUDE.md`만 있고 1단계 산출물(문서·코드)이 없었다. MTP 단계는 탐색기 UI·Mock·현지화 기반 위에서만 검증 가능하므로 1단계 기반을 먼저 만들고 2단계를 이어서 구현했다.

## D2. Xcode 프로젝트를 직접 작성 (XcodeGen 미사용)
외부 도구 의존을 줄이기 위해 `project.pbxproj`를 폴더 동기화 그룹(`PBXFileSystemSynchronizedRootGroup`)으로 작성. 파일 추가 시 프로젝트 파일 수정이 필요 없다.

## D3. libmtp + libusb는 Homebrew 정적 라이브러리로 링크
- 이유: 샌드박스 앱이 `/opt/homebrew`의 dylib를 로드하는 문제, Hardened Runtime 라이브러리 검증 문제를 피함. 개발 단계에서 가장 단순.
- 대가: libmtp(LGPL-2.1)·libusb(LGPL-2.1) 정적 링크는 배포 시 재링크 가능성 제공 의무가 생김 → 배포 단계(6단계)에서 동적 링크 + 앱 번들 내 Frameworks 포함 또는 오브젝트 파일 제공으로 전환해야 함 (KNOWN_ISSUES K3).
- Homebrew 병(bottle)이 macOS 27용으로 빌드돼 배포 대상 26.0과 링커 경고가 남 (K2).

## D4. `LIBMTP_Detect_Raw_Devices` 대신 IOKit 위치로 raw device 구성
`Detect`는 버스의 미등록 장치를 모두 열어 프로빙한다. 마우스·모니터 등 무관한 장치를 건드리지 않도록 IOKit이 찾은 bus/address/VID/PID로 직접 `LIBMTP_raw_device_t`를 만들고, quirk 플래그만 `LIBMTP_Get_Supported_Devices_List`에서 가져온다.

## D5. libusb preflight claim으로 충돌을 먼저 판정
libmtp는 열기 실패 원인을 반환하지 않고(NULL), 실패 시 USB 리셋까지 시도한다. 먼저 libusb로 MTP 인터페이스를 claim/release 해 “다른 프로그램 점유(busy)”를 정확히 구분하고, busy면 libmtp를 호출하지 않는다.

## D6. 다른 MTP 프로그램은 종료하지 않는다
ptpcamerad(이미지 캡처), Android File Transfer Agent, OpenMTP 등과 충돌 시 IORegistry에서 소유 프로세스 이름만 읽어 안내한다. 프로세스 종료·launchd 설정 변경은 하지 않는다 (요구사항 및 보안 정책).

## D7. 세션 actor + 기기별 직렬 큐 executor
`MTPDeviceSession`을 `DispatchSerialQueue`를 executor로 쓰는 actor로 구현. libmtp 블로킹 호출이 협력 스레드 풀을 점유하지 않고, 기기별 직렬화가 언어 차원에서 보장된다.

## D8. 논리 기기 ID = vendorID + USB 시리얼
Android는 USB 모드 전환 시 재열거되며 PID·IORegistry ID가 바뀐다. 시리얼은 유지되므로 이를 키로 써서 “충전 전용 → 파일 전송” 전환을 같은 기기의 상태 변화로 처리한다. 재열거 사이를 잇기 위해 해제 후 8초 `reconnecting` 유예를 둔다.

## D9. 잠금 상태 = “세션은 열렸지만 저장소 0개”
Android는 잠금 상태에서 MTP 세션은 열어 주지만 저장소 ID를 0개로 반환한다 (libmtp는 이때 오류 스택 없이 -1 반환). 이를 `waitingForMTP(.deviceLocked)`로 표시하고 같은 세션에서 2초 간격 폴링해 잠금 해제 시 자동으로 `connected`가 된다.

## D10. 런타임 언어 전환은 자체 LocalizationManager
SwiftUI 기본 조회는 프로세스 언어를 따라 재실행이 필요하다. 모든 앱 문자열을 `t(_:)`로 선택 언어의 `.lproj`에서 조회한다. 키는 `extractionState: manual`로 관리하고, `scripts/check-localization.py`와 단위 테스트로 누락을 검사한다.

## D11. App Sandbox 유지
처음부터 샌드박스 + `device.usb` 권한으로 개발해 FSKit 확장·배포 단계와 차이를 줄인다. 이 Mac에서 샌드박스 내 libusb 열거와 IOKit 감지가 동작함을 테스트로 확인했다. 실제 MTP 세션이 샌드박스에서 동작하는지는 실기기 검증 필요 (K1).

## D12. 재연결 시 저장소 루트로 복귀
MTP 객체 핸들은 세션 간 보장되지 않는다. 새 세션에서는 이전 경로를 복원하지 않고 저장소 루트로 돌아간다. 경로 이름 기반 복원은 후속 과제.

## D13. Mock 기기는 별도 섹션·배지·배너로 구분
`DeviceID.demo`, `isMock == true`, 사이드바 “가상 기기 (테스트용)” 섹션, “데모” 배지, 탐색기 상단 배너. 실제 기기가 연결되면 자동으로 실제 기기로 선택이 넘어간다. 설정에서 숨길 수 있다.

## D14. 2차 개발도 같은 세션·저장소에서 진행 (2026-10-22)
2단계 MTP 계층 직후 이어서 요청돼 같은 코드베이스 위에 확장했다. 1단계·2단계 기능과 테스트는 그대로 유지(기존 66개 테스트 전부 통과 상태 유지).

## D15. 검증은 크기 비교, 체크섬은 하지 않음
MTP에는 해시 명령이 없어 내용 검증을 하려면 전송한 파일을 다시 통째로 읽어야 한다(전송 시간 2배). 대신 스테이징 + 크기 검증 + 원자적 반영으로 "불완전한 파일이 최종 이름으로 남지 않는 것"을 보장한다. 필요 시 설정으로 다시 읽기 검증을 추가할 수 있다.

## D16. 업로드는 스테이징 이름 후 rename
MTP는 원자적 교체가 없다. 고유한 숨김 이름으로 올리고 검증한 뒤 rename한다. 정리 대상이 항상 고유 이름이라 실패 시 사용자 파일을 잘못 지울 위험이 없다. rename 미지원 기기에서는 덮어쓰기를 막는다(원본 보호 우선).

## D17. 전송 큐는 직렬
MTP 세션은 트랜잭션을 하나씩만 처리하므로 같은 기기에 대한 병렬 전송은 이득이 없고 충돌 처리만 복잡해진다. 여러 기기 동시 연결 시 기기별 병렬화는 후속 과제.

## D18. 기기 내부 드래그는 이동, 패널 간 드래그는 복사
Finder 규칙(같은 볼륨 = 이동, 다른 볼륨 = 복사)을 따른다. 잘라내기/붙여넣기로 패널 간 이동도 가능하며, 원본은 검증 후에만 삭제(Mac은 휴지통).

## D19. 미리보기는 Quick Look + 캐시 다운로드
기기 파일을 직접 스트리밍해 보여 줄 방법이 없어 캐시로 내려받은 뒤 Quick Look을 연다. 1 GB 초과·미지원 형식(HWP, APK, ZIP 등)은 미리보기 비활성. 캐시는 실행·종료 시 삭제. 정보 패널은 MTP 내장 썸네일만 사용(전체 다운로드 없음).

## D20. 로컬 접근 권한
샌드박스 유지. 기본 다운로드 위치는 Downloads 권한(`files.downloads.read-write`)으로 접근하는 실제 `~/Downloads`. 그 외 위치는 사용자가 패널에서 고른 폴더만 쓰며, Mac 패널 폴더는 보안 범위 북마크(`files.bookmarks.app-scope`)로 다음 실행에도 유지한다.

## D21. Mock 기기를 쓰기 가능한 테스트 장비로 확장
`MockDeviceFileSystem`은 메모리 내 쓰기·폴트 주입(지연, 중간 실패, 분리, 공간 부족, 읽기 전용, 부분 객체 잔존, 크기 위조)을 지원한다. 데모 기기에서도 업로드·삭제를 체험할 수 있다(앱 재실행 시 초기화).

---

# 4단계: Finder 통합 (FSKit) — 사전 검증과 설계 (2026-10-22)

## V0. 사전 검증 결과 (이 Mac의 실제 SDK·OS에서 확인)

| 항목 | 확인 방법 | 결과 |
|---|---|---|
| FSKit 사용 가능 여부 | `MacOSX27.0.sdk/System/Library/Frameworks/FSKit.framework` 헤더·`.swiftinterface` | 사용 가능. 가용성 매크로 V1 = macOS 15.4, V2 = 26.0, V2_4 = 26.4, V3 = 27.0 |
| `FSGenericURLResource` | `FSResource.h` | `FSKIT_API_AVAILABILITY_V2` → **macOS 26.0 이상**. URL 내용 해석은 전적으로 모듈 책임. Info.plist `FSSupportsGenericURLResources = true`, `FSSupportedSchemes = [scheme]` |
| 확장 구성 | Xcode 템플릿 `File System Extension.xctemplate`, 시스템 모듈 `com.apple.fskit.ftp.appex` | ExtensionKit `.appex`, `EXExtensionPointIdentifier = com.apple.fskit.fsmodule`, `@main struct … : UnaryFileSystemExtension`, 주 클래스 `FSUnaryFileSystem & FSUnaryFileSystemOperations` |
| entitlement | 템플릿 `.entitlements`, Apple `ftp` 모듈 서명 | `com.apple.developer.fskit.fsmodule = true` + App Sandbox. Apple의 URL 기반 `ftp` 모듈은 `network.client/server`만 추가로 사용 |
| 서명 환경 | `security find-identity`, 프로비저닝 프로필 | **Apple Development 인증서 없음**(Distribution만 있음), **macOS 프로비저닝 프로필 없음**. 실험 결과는 V7 |
| 설치된 FSKit 모듈 | `pluginkit -mAvvv -p com.apple.fskit.fsmodule` | exfat, msdos, ftp(일반 URL), Xcode DeviceFS 4개 |
| 마운트 절차 | `FSClient.h`, `mount(8)` | macOS 27: `FSClient.shared.mountSingleVolume(resource:bundleID:options:)` (V3, 프로그램 마운트). macOS 26: 프로그램 API 없음 → `mount -F -t <FSShortName> <url> <경로>`(터미널). 사용자는 **시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램 › 파일 시스템 확장**에서 모듈을 켜야 함(`FSClient.openFileSystemExtensionsSettings()`가 V3에서 이 화면을 연다). 앱이 대신 켤 수 없음(보안 설정) |
| 해제 절차 | FSKit에는 확장 쪽 "스스로 해제" API 없음 | 앱이 `FileManager.unmountVolume(at:)`으로 해제 → FSKit이 `unmount` → `deactivate` → `unloadResource` 순으로 호출 |
| 앱 ↔ 확장 통신 | 샌드박스 규칙, Apple 모듈 사례 | 확장은 별도 샌드박스 프로세스. 두 프로세스가 같은 **App Group** 컨테이너를 공유하면 그 안의 Unix 도메인 소켓으로 통신 가능. App Group은 팀 ID 접두어(`$(TeamIdentifierPrefix)…`)가 필요해 팀 서명이 있어야 확실히 동작 |
| 읽기 | `FSVolumeReadWriteOperations` | `read(from:at:length:into:)` 임의 오프셋 읽기. libmtp `LIBMTP_GetPartialObject`(기기가 `GetPartialObject` 지원 시) 사용, 미지원 시 앱 캐시로 전체 다운로드 후 범위 읽기 |
| 쓰기 | `write(contents:to:at:)` | 임의 오프셋 쓰기 요청이 옴. MTP에는 일반 임의 쓰기가 없음(`SendPartialObject`/`BeginEditObject`는 Android 확장이며 기기별 차이 큼) → 로컬 임시 파일 + 닫을 때 업로드 방식이 필요(V5) |
| macOS 버전 제한 | 위 가용성 | macOS 26.0: 일반 URL 리소스 가능, 프로그램 마운트 불가. macOS 27.0+: 프로그램 마운트 가능. 이 Mac은 27.0.1 |

## D22. Finder 경로: Finder → FSKit 확장 → DeviceBroker IPC → MTP File Repository → 네이티브 브리지
- 확장은 libmtp를 링크하지 않는다. 모든 요청을 앱의 `BrokerIPCServer`로 보내고, 앱의 `MTPFileRepository`가 **기존 DeviceBroker의 세션**(`DeviceFileSystem`)으로 처리한다. Finder가 별도 MTP 세션을 열 수 없도록 구조적으로 막는다.
- 앱이 실행 중이 아니면 확장은 마운트를 거부하거나(로드 실패) 작업마다 `EIO`/`ENXIO`를 돌려준다.

## D23. 볼륨 단위 = (기기, 저장소)
리소스 URL `phonebridge://volume?device=<DeviceID>&storage=<hex>&generation=<n>`. 볼륨 이름은 "기기 이름 – 저장소 이름". 세대가 바뀌면(재연결) 기존 마운트의 요청은 `ESTALE`로 실패하고, 앱이 해제 후 재마운트한다.

## D24. IPC 전송 방식
App Group 컨테이너 안의 Unix 도메인 소켓 + 길이 접두 프레임(JSON 헤더 + 바이너리 본문). 연결 시 프로토콜 버전 확인, 같은 사용자(uid) 확인, 상대 프로세스의 코드 서명 식별자 확인(감사 토큰). TCP 루프백은 다른 로컬 프로세스가 접속할 수 있어 쓰지 않는다. 소켓 경로를 주입할 수 있어 테스트에서는 임시 경로로 같은 프로세스 안에서 실제 소켓 왕복을 검증한다.

## D25. 읽기 전략
`GetPartialObject` 지원 기기는 요청 범위만 읽는다. 미지원 기기는 앱 캐시(`Caches/FinderReadCache`)에 파일 전체를 스테이징 다운로드·크기 검증 후 범위 읽기. 캐시 키 = 기기·세대·저장소·객체·크기·수정시각. 쓰기 작업이 생기면 해당 키를 무효화한다.

## D26. 쓰기 지원(2단계)은 읽기 전용 검증 이후로 미룬다
요청대로 읽기 전용 구현이 실제 Finder에서 안정적으로 검증된 다음 착수한다. 설계만 확정해 둔다:
- 확장은 쓰기용으로 열린 파일을 자기 컨테이너의 임시 파일에 반영(임의 오프셋 쓰기는 로컬 파일에서만), 닫힘/동기화 시 앱으로 전체 내용을 스트리밍.
- 앱은 TransferManager와 같은 규칙으로 반영: 스테이징 이름 업로드 → 크기 검증 → 기존 파일 `.bak` 이름 변경 → 스테이징을 최종 이름으로 → 백업 삭제. MTP에는 원자적 교체가 없으므로 "이름 변경 두 번 사이" 짧은 구간에 최종 이름이 비어 있을 수 있음(한계). 실패 시 백업 이름을 원래대로 되돌리고, 되돌리기도 실패하면 백업을 남겨 원본이 사라지지 않게 한다.
- 업로드 성공 후 읽기 캐시와 디렉터리 캐시 무효화.

## V7. 실제 등록·마운트 실험 결과 (2026-10-22, macOS 27.0.1)

| 단계 | 결과 |
|---|---|
| Xcode 빌드(확장에 `com.apple.developer.fskit.fsmodule`) | **실패**: `"PhoneBridgeFinder" requires a provisioning profile`. → 기본 빌드는 FSKit 권한을 뺀 `PhoneBridgeFinder-Unprovisioned.entitlements` 사용(컴파일·임베드만 됨), 팀 빌드는 `PB_FINDER_ENTITLEMENTS=Config/PhoneBridgeFinder.entitlements` |
| 확장 임베드 | 성공: `PhoneBridge.app/Contents/Extensions/PhoneBridgeFinder.appex`, `EXExtensionPointIdentifier=com.apple.fskit.fsmodule`, `FSShortName=phonebridge`, `FSSupportsGenericURLResources=true` |
| ad-hoc 서명 + FSKit 권한(수동 재서명한 사본) 등록 | `pluginkit`에는 등록됨, `fskit_agent` 로그 "Added 1 identifiers" |
| `FSClient.installedExtensions` (ad-hoc 호출자) | PhoneBridge 모듈 **미포함**(Apple 모듈 4개만). `fskitd`: "errno 2, retrieving team ID" |
| `mount -F -t phonebridge phonebridge://… <경로>` | **실패**: `Module com.phonebridge.PhoneBridge.FinderVolume is disabled!` / `mount: Unable to invoke task` (exit 69) |
| `FSClient.mountSingleVolume` (macOS 27 API) | **실패**: `NSPOSIXErrorDomain Code=1 "Operation not permitted"` |
| 앱 샌드박스에서 App Group 소켓 | 컨테이너 조회는 성공하지만 `bind` → **EPERM**. 팀 접두어 없는 그룹(`com.phonebridge.shared`)은 ad-hoc 서명에서 쓰기가 허용되지 않음 |
| 실험 정리 | 수동 등록한 사본은 `pluginkit -r`, `lsregister -u`로 제거. 시스템 설정은 변경하지 않음 |

**결론**: 이 환경에서는 FSKit 확장 코드가 한 번도 실행되지 않았다. 차단 원인은 두 가지이며 둘 다 코드가 아니라 서명·사용자 설정 문제다.
1. **팀 서명 필요**: FSKit 권한과 App Group(팀 접두어)을 쓰려면 Apple Development 인증서와 개발 프로필이 필요. `scripts/build-team-signed.sh <TEAM_ID>`로 빌드 가능(Xcode가 사용자 계정에 App ID·App Group·프로필을 만들므로 사용자가 직접 실행).
2. **사용자 활성화 필요**: 시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램 › 파일 시스템 확장에서 사용자가 켜야 함. 앱은 설정 화면을 여는 것까지만 한다.

## D27. FSKit 확장은 V1(macOS 15.4) 프로토콜로 구현
배포 대상이 macOS 26이므로 `FSVolume.Operations`, `FSVolume.ReadWriteOperations`(V1)를 쓴다. macOS 27의 `FSVolume.Handler` 계열(V3)은 사용하지 않는다. 확장 타깃은 FSKit ObjC 콜백과의 호환을 위해 Swift 5 언어 모드.

## D28. 볼륨은 읽기 전용 권한 비트로 노출
디렉터리 `r-x`, 파일 `r--`, 모든 쓰기 계열 요청은 `EROFS`. Finder가 쓰기 불가 볼륨으로 표시하도록 해 2단계 전까지 데이터 변경 경로를 원천 차단한다.

## D29. 연결 해제·재연결 시 마운트 처리
앱이 기기 상태 변화마다 마운트 목록을 다시 계산한다. 기기가 사라지거나 세션 세대가 바뀐 볼륨은 해제하고 그 기기의 읽기 캐시를 비운다. 자동 마운트가 켜져 있으면 새 세대로 다시 마운트한다. 오래된 마운트로 들어오는 요청은 저장소가 `ESTALE`/`ENXIO`로 거절한다.

## D30. 2단계(쓰기)는 착수하지 않음
요청 조건("읽기 전용 구현이 안정적으로 검증된 다음")이 충족되지 않았다(V7). 설계(D26)만 확정하고 코드는 넣지 않았다.

### V7-2. 팀 서명 빌드 (2026-10-22 16:25)
- 사용자가 Xcode 계정 재로그인·Apple Development 인증서 생성 후 `scripts/build-team-signed.sh KB2PLX99H6` 실행 → **빌드 성공**. 스크립트에 `-allowProvisioningDeviceRegistration` 추가(이 Mac 등록 필요).
- 확장: `Mac Team Provisioning Profile: com.phonebridge.PhoneBridge.FinderVolume` 내장, `com.apple.developer.fskit.fsmodule = true`, App Group `KB2PLX99H6.com.phonebridge.shared`. 앱·확장 모두 TeamIdentifier `KB2PLX99H6`, `codesign --verify --deep --strict` 통과.
- 남은 차단: `mount -F` → 여전히 `Module … is disabled!`. 시스템 설정에서 사용자가 켜야 함(앱이 대신하지 않음).

### V7-3. 확장 활성화 실패 원인 분석과 수정 (2026-10-22 16:30)
- 증상: 시스템 설정에서 "PhoneBridge Finder"를 켤 수 없음.
- 증거: `taskgated-helper: Disallowing com.phonebridge.PhoneBridge because no eligible provisioning profiles found`. 앱 번들에 프로필 없음. 확장 프로필에는 FSKit 권한만 있고 서명이 주장한 App Group(`KB2PLX99H6.com.phonebridge.shared`)은 없음. 확장 프로세스는 한 번도 실행되지 않았고 충돌 보고서 없음. FSKit 로그는 대부분 `<private>`라 직접 사유는 확인 불가.
- 판단: 팀 접두어 App Group은 Xcode 자동 서명이 "프로필 불필요"로 취급해 앱에 프로필이 붙지 않았고, macOS 27의 taskgated가 이를 거부. 같은 이유로 확장 서명과 프로필 내용이 어긋남.
- 수정: App Group을 포털 등록형 `group.com.phonebridge.shared`로 변경(Xcode가 즉시 두 타깃 모두 "프로필 필요"로 판단함을 확인). ad-hoc 기본 빌드는 App Group 없는 `PhoneBridge-Unprovisioned.entitlements` 사용(`PB_APP_ENTITLEMENTS`).
- 추가 발견: 개발 빌드·테스트 실행이 DerivedData의 ad-hoc 사본을 같은 번들 ID로 다시 등록해 FSKit이 그 사본을 볼 수 있음 → 팀 빌드 스크립트가 별도 DerivedData로 빌드, 높은 빌드 번호 부여, `/Applications`에 설치·등록, 다른 사본 등록 해제, 프로필에 App Group 포함 여부를 출력.
- 검증 상태: 원인 가설이며 아직 확인되지 않음. 사용자가 스크립트를 다시 실행하고 토글을 시도해야 확정된다.

### V7-4. 중복 앱과 진단 빌드 (2026-10-22 16:35)
- 사용자 보고: 앱 검색에 PhoneBridge가 3개, 확장 토글이 켜지지 않음.
- 3개 = `/Applications` 설치본 + 팀 빌드 DerivedData 사본 + ad-hoc 개발 빌드 사본(Spotlight가 DerivedData도 색인). 두 DerivedData 사본을 삭제·등록 해제해 1개로 정리.
- 설치본은 capability 선언 전 빌드라 두 프로필 모두 App Group 미포함 상태였음.
- 진단 빌드 설치: 계정 변경 없이(캐시된 프로필만) 팀 서명, **App Group 제외**. 확장의 서명 권한(FSKit, 샌드박스)이 프로필로 전부 승인됨, 앱은 프로필이 필요한 권한 없음. 이 빌드로 토글이 켜지면 원인은 App Group으로 확정. 단, 이 빌드는 App Group이 없어 Finder 볼륨의 실제 데이터 통신은 불가(토글·등록 진단 전용).
- 재발 방지: ad-hoc 개발 빌드는 번들 ID `com.phonebridge.PhoneBridge.dev`(+`.FinderVolume`), 표시 이름 "PhoneBridge Dev". 팀 스크립트는 `PB_BUNDLE_SUFFIX=` `PB_DISPLAY_NAME=PhoneBridge`로 정식 ID를 빌드하고 설치 후 DerivedData 사본을 지운다. 개발 빌드의 콘솔 로그 subsystem·컨테이너 경로도 `.dev`로 바뀜.

### V7-5. 원인 확정과 FSKit 실행 확인 (2026-10-22 16:41)
- **원인 확정**: App Group을 뺀 진단 빌드에서 사용자가 "PhoneBridge Finder"를 켤 수 있었다. → 토글 실패 원인은 **프로필로 승인되지 않은 App Group 권한**.
- **FSKit 실행 확인**(실측): `mount -F -t phonebridge phonebridge://volume?device=demo:virtual-android&storage=10001&generation=1 <경로>` → FSKit이 설치본 확장(`com.phonebridge.PhoneBridge.FinderVolume`)을 실행하고 `loadResource`가 PhoneBridge 코드까지 도달. 코드가 App Group 컨테이너의 브로커 소켓에 접속을 시도하다 `ENOENT`(앱 쪽 서버 없음)로 정상 실패.
- **추가 충돌 발견·수정**: 개발 빌드 확장도 `FSShortName = phonebridge`라 `mount -F -t phonebridge`가 개발 모듈을 고를 수 있었음(실제로 한 번 그렇게 실행됨). 개발 빌드는 `PB_FS_SHORT_NAME = phonebridgedev`, 팀 빌드는 `phonebridge`.
- **남은 일**: App Group `group.com.phonebridge.shared`를 개발자 계정에 등록해 앱·확장 프로필에 포함 → 앱의 브로커 서버 시작 → 실제 볼륨 마운트·F1–F10 검증.

### V7-6. 팀 빌드로 App Group 등록 시도 (2026-10-22 16:43, 사용자 승인 후 실행)
- `scripts/build-team-signed.sh KB2PLX99H6` 실행 → 빌드·설치 성공, 그러나 **App Group 미등록**. 앱은 와일드카드 프로필(`Mac Team Provisioning Profile: *`), 확장은 `…FinderVolume` 프로필, 둘 다 App Group 없음. TargetAttributes의 `SystemCapabilities`(App Groups) 선언만으로는 명령줄 자동 서명이 포털에 그룹을 등록하지 않음.
- macOS 판정(실측): `taskgated-helper: com.phonebridge.PhoneBridge: Unsatisfied entitlements: com.apple.security.application-groups … Disallowing`. 그룹 컨테이너 접근 `Operation not permitted`.
- 확장 활성화 상태는 재설치 후에도 유지되었고(`mount -F`가 여전히 `loadResource`까지 도달), 소켓이 없어 마운트 실패.
- **필요한 수동 단계(포털)**: App Group `group.com.phonebridge.shared` 생성 → 명시적 App ID `com.phonebridge.PhoneBridge`(macOS) 생성 + App Groups 기능에 그룹 지정 → 기존 App ID `com.phonebridge.PhoneBridge.FinderVolume`에 App Groups 기능 추가·그룹 지정 → 스크립트 재실행.

### V7-7. 실제 FSKit 마운트·Finder 경로 검증 (2026-10-22 21:25–21:31, 가상 기기 볼륨)
- 사용자가 포털에서 App Group `group.com.phonebridge.shared`와 App ID(앱·확장)를 설정. Xcode가 오래된 캐시 프로필을 재사용하고 있어 두 캐시 프로필을 백업 폴더로 옮긴 뒤 재빌드 → **두 프로필 모두 App Group 포함**.
- 앱(팀 서명) 실행 → `Finder broker listening at …/Group Containers/group.com.phonebridge.shared/finder-broker.sock` (App Group 안 소켓 생성 성공).
- `mount -F -t phonebridge phonebridge://volume?device=demo:virtual-android&storage=10001&generation=1 <경로>` → **마운트 성공**(`phonebridge, fskit, mounted by <사용자>`), 확장 로그 `loaded 가상 Android 기기 – 내부 저장공간`.
- 실측 결과는 TEST_PLAN 4장 표에 기록(F1–F7, F10 통과, 가상 기기 기준).
- 함께 고친 것: 설정 Bool이 `YES`/`NO` 실행 인자를 무시하던 문제(`AppSettings.bool`), 앱 데모 기기에 검증용 폴더 "PhoneBridge 테스트"(5 GB 가상 영상, 실제 PNG·PDF·텍스트) 추가(`demoExtras`, 테스트 고정 데이터는 그대로).

### V7-8. 실제 Android 기기 검증 (2026-10-22 21:35–21:55, SM-S937N "가람의 S25 Edge")
기기: Samsung SM-S937N, MTP `04E8:6860`, GetPartialObject 지원(caps 63), 저장소 1개("내장 저장공간", 221 GiB 중 72 GiB 여유). 개인 파일이라 파일 이름·내용은 기록하지 않고 개수·해시만 확인했다.
- **앱 마운트 권한**: `FSClient.mountSingleVolume`이 `Client is missing 'com.apple.developer.fskit.mount'`(EPERM)로 실패 → 앱 권한 파일에 `com.apple.developer.fskit.mount` 추가(Xcode가 프로필에 자동 등록). **정정**: 그 전 기록의 "설정 › Finder 마운트 버튼 사용자 확인"은 앱에 이 권한이 없던 시점이라 앱 마운트였을 수 없다. 사용자가 본 볼륨은 CLI(`mount -F`) 마운트였고, 해제 버튼은 사용자 소유 마운트라 동작할 수 있었다(아래 언마운트 실험 참고).
- **한글 볼륨 이름**: 앱 마운트 시 fskitd가 볼륨 이름으로 `/Volumes/<이름>`을 만드는데, 이름에 ASCII 밖 문자가 있으면 `EINVAL`. 실측: "S25 Edge – Internal"(en dash만), "가람의 S25"(한글만), "가람의 S25 Edge - 내장 저장공간"(ASCII 하이픈) 모두 실패, "Galaxy S25 Edge Internal" 성공. URL 경로에 이름을 넣는 방법은 효과 없음(제거).
  - **해결(D31)**: 확장은 ASCII 마운트 이름(`PhoneBridge SM-S937N`, 둘째 저장소부터 ` 2`…)으로 볼륨을 만들고 `mount` 직후 `FSVolume.name`을 실제 이름으로 바꾼다. 실측: 마운트 경로 `/Volumes/PhoneBridge SM-S937N`, `URLResourceValues.volumeName`과 Finder `displayed name` = "가람의 S25 Edge – 내장 저장공간".
- **첫 연결 직후 preflight 실패**: 꽂은 직후 libusb가 IOKit이 알려준 주소에서 장치를 못 찾음("No USB device at bus 0 address 1") → 같은 연결에서 최신 USB 스냅숏으로 새 세션을 최대 2회 재시도(`transientRetries`). 단위 테스트 2개 추가. 실기기 재확인은 다음 재연결 때.
- **F8(분리 시 해제) 실패 — 원인 확정**: 분리 즉시 앱이 `FileManager.unmountVolume`을 호출했으나 "디스크를 추출할 수 없습니다". 시스템 로그: `authd: Sandbox denied authorizing right 'system.volume.network.unmount' by client '/Applications/PhoneBridge.app'`, `denied lookup: com.apple.unmountassistant.useragent … Sandbox restriction`.
  - 실험(샌드박스 프로브 앱, ad-hoc): `FSClient`가 만든 마운트는 **소유자 root**(fskitd), `mount -F` 마운트는 **소유자 사용자**. 샌드박스 프로세스는 사용자 소유 마운트는 해제 가능, root 소유 마운트는 위 권한 거부로 실패. 샌드박스 밖 프로세스(`diskutil unmount`, 서명 없는 `unmountVolume`)는 둘 다 해제 가능. 샌드박스 안에서 `mount -F` 실행은 `Unable to invoke task`(exit 69)로 불가.
  - FSKit 공개 API에는 클라이언트 측 언마운트가 없다(SDK 헤더 확인: `FSClient`는 마운트만, `FSResource.revoke`는 언마운트가 아님).
  - 결과: 분리 후 볼륨이 남고, 접근하면 `ESTALE`("Stale NFS file handle")로 안전하게 실패. 재연결 시 같은 이름이 사용 중이라 ` 1`, ` 2`가 붙은 새 마운트가 생김. 해결 방식은 사용자 결정 대기(K29).
- **F9(재연결 후 재마운트) 통과**: 분리 → 재연결 후 새 세대(2 → 14)로 자동 마운트, 새 볼륨에서 목록·읽기 정상. 커넥터 접촉이 순간 끊겼다 붙는 경우(21:42:47 → 49)도 새 세대로 다시 연결·마운트됨.
- 나머지 실측(앱 마운트 볼륨): F1 통과, F2 DCIM 3,428개 8초, F3 사진 20개 해시 안정·JPEG 전체 디코드, F4 `ditto` 6/6 동일·Quick Look 6/6(동영상 포함), F5 CLI 3회, F6 병렬 읽기·같은 저장소 이중 마운트 정상, F7 565 MB MP4 21.6 MB/s·임의 위치 읽기 일치(기기에 4 GB 넘는 파일 없음), F10 쓰기 6종 모두 거부·변화 없음.

## D31. 마운트 경로는 ASCII, 표시 이름은 실제 이름
fskitd가 ASCII 밖 마운트 지점 이름을 거부하므로(V7-8) `VolumeDescription.mountName`(ASCII)으로 마운트하고, 마운트 후 `FSVolume.name`을 "기기 – 저장소" 실제 이름으로 바꾼다. 이름이 이미 ASCII면 그대로 쓴다. Finder·`volumeName`은 실제 이름을 보여 주고 `/Volumes/` 경로와 AppleScript `name`만 ASCII다.

## D32. 볼륨 해제는 샌드박스 밖 XPC 헬퍼가 맡는다 (2026-10-22, 사용자 선택)
선택지: (1) 해제 전용 헬퍼, (2) 앱 샌드박스 해제, (3) 현 상태 유지 + Finder에서 꺼내기 안내. 사용자가 (1)을 골랐다.
- `PhoneBridgeUnmounter.xpc`(번들 ID `<앱 ID>.Unmounter`)를 앱 `Contents/XPCServices`에 넣는다. 샌드박스 없음, Hardened Runtime, 별도 권한 없음. 앱과 FSKit 확장은 샌드박스를 유지한다(D11 유지).
- 헬퍼는 요청 경로를 `realpath` + `statfs`로 다시 확인해 **이 빌드의 FSShortName 유형**(`phonebridge`/`phonebridgedev`), `phonebridge://` 원본, `/Volumes/` 아래 마운트 지점 자체일 때만 `FileManager.unmountVolume`을 호출한다. 그 밖에는 EPERM.
- 연결은 `setCodeSigningRequirement`로 호스트 앱 식별자 + 같은 팀 인증서만 허용(팀 서명이 없으면 식별자만).
- `JoinExistingSession = true` 필수: 기본(새 보안 세션)에서는 authd가 "session owner invalid (-3)"로 `system.volume.network.unmount`를 거부했다(실측). 사용자 세션에 합류하면 "세션 소유자가 admin 그룹" 규칙으로 승인된다(실측).
- 헬퍼에 연결할 수 없을 때(XPC 오류)만 앱이 직접 해제를 시도한다(사용자가 `mount -F`로 만든 사용자 소유 마운트는 샌드박스 앱도 해제 가능).
- 함께 바꾼 것: 세션 세대를 실행 시각(ms)에서 시작(이전 실행의 볼륨 주소와 겹치지 않음), 시작 시 이 빌드 유형의 남은 볼륨을 정리(이번 실행이 마운트한 경로는 건너뜀), 확장이 보고하는 파일 시스템 유형을 빌드별 FSShortName으로(개발 빌드 테스트 실행이 설치본 볼륨을 지운 사고를 막음).
- 대가: Mac App Store 배포 불가(모든 실행 파일이 샌드박스여야 함). 관리자 계정이 아니면 authd 규칙상 해제가 거부될 수 있음(미검증, K31).
- 실측(2026-10-22 22:01–22:03): 헬퍼가 이전 실행이 남긴 볼륨 2개 해제, 앱 종료 시 볼륨 해제, 재실행 시 재마운트.
- 실측(22:05, 케이블 분리): `connected → reconnecting` 0.4초 뒤 헬퍼가 `/Volumes/PhoneBridge SM-S937N` 해제 → **F8 통과**. 재연결(22:06:17)은 세션이 첫 시도에 열렸으나 저장소 목록이 비어 `waitingForMTP`(잠금 또는 "휴대전화 데이터 접근 허용" 대기)에 머묾 → 사용자가 잠금 해제·접근 허용(22:07:42) → 기기 재열거 → 새 세대로 연결·같은 경로에 재마운트(22:07:43) → **F9 통과**. 첫 연결 preflight 재시도는 이번에 필요하지 않아 실기기에서 발동하지 않음(단위 테스트로만 확인).

## V8. W0 Finder 쓰기 동작 관찰 (2026-10-22, 가상 기기 볼륨 전용 관찰 모드)
결과 전문: `docs/FINDER_WRITE_W0.md`, 호출 기록: `docs/w0-traces/`. 기기·앱으로 가는 쓰기 없음.
요약: 커밋 시점은 마지막 close가 맞고 close 오류는 `cp`·Finder 모두 사용자에게 보인다(Finder는 부분 파일 삭제). Finder는 복사마다 0바이트 자리표시 파일을 만들었다 지우고, "대치" 시 원본을 먼저 지우며, 시각·권한 설정은 close 뒤에 보낸다. 원자적 저장은 열린 파일을 최종 이름으로 rename한 뒤 닫는다. 이동·`replaceItemAt`은 폴더 간 rename. 희소 파일 복사는 크기 늘리기 + 끝부분 쓰기, 덧붙이기는 마지막 페이지 재기록. 호출의 60–95%가 `._*`/`.DS_Store`.

## D33. 파일 삭제는 지연 삭제
Finder "대치"가 원본을 먼저 지우므로(V8), 파일 삭제 요청은 기기에서 숨김 백업 이름 변경으로 처리하고 목록에서는 즉시 숨긴다. 같은 자리 새 파일의 커밋이 성공하거나 30초가 지나면 실제로 삭제하고, 새 파일 커밋이 실패하면 원본 이름으로 되돌린다. 사용자에게 보이는 동작은 Finder 기본 삭제 그대로(사용자 결정 유지), 원본 보호만 추가. 앱 비정상 종료로 남은 백업은 다음 세션 시작 시 정리 대상(이름 규칙으로만 식별).

## D34. W1 앱 쪽 쓰기 구현 규칙 (2026-10-22)
- **IPC v2** (`FinderIPC.protocolVersion = 2`): `writeCapabilities`, `createFolder`, `commitFile`, `rename`, `move`, `delete`와 응답 `writeCapabilities`, `done`. 버전이 다르면 연결 단계에서 거부(기존 규칙).
- **버퍼는 이름으로만 지정**: 커밋은 App Group의 `FinderWrites/` 안 파일 이름 하나(`isValidBufferName`: `/`·`..`·숨김 이름 금지)만 보낸다. 앱이 경로를 만들고 크기를 대조한다. 확장이 임의 경로를 읽게 할 수 없다.
- **쓰기 요청은 재전송하지 않는다**: 소켓 오류 후 재연결 재시도는 읽기 요청이거나 요청이 아직 전달되지 않았을 때만. 응답만 잃은 쓰기를 다시 보내 두 번 적용되는 일을 막는다.
- **교체는 명시적으로만**: 같은 이름의 기존 파일은 확장이 `replacing`으로 그 객체 ID를 지정했을 때만 교체. 다르면 EEXIST(앱 UI가 그사이 만든 파일 등 보호). 이름 비교는 대소문자 무시.
- **안전 순서는 TransferManager와 같다**: 숨김 스테이징 업로드 → 크기 확인 → 기존 파일 백업 이름 → 최종 이름 → 백업 삭제, 단계별 실패 시 복원. 이동은 MoveObject 후 이름 변경, 이름 변경 실패 시 원래 폴더로 되돌림. MoveObject가 없으면 EXDEV.
- **D33 구현**: 파일 삭제 = `.phonebridge-….deleted` 이름 변경 + 30초 타이머. 같은 (폴더, 이름)에 커밋·rename·move가 성공하면 즉시 실제 삭제, 실패하면 원래 이름으로 복원. 폴더 삭제 시 안쪽 대기 삭제를 먼저 끝내고, 보이는 항목이 남으면 ENOTEMPTY. 세션이 바뀌거나 앱이 끝날 때 모두 끝낸다(기기가 이미 분리됐으면 실패하고 숨김 백업이 남음 → W3 정리).
- **직렬 처리**: 쓰기 요청은 도착 순서대로 하나씩(여러 단계 요청이 섞이지 않게).
- **쓰기 허용 스위치**: `settings.finderWrites`(기본 꺼짐). UI는 W4. 꺼져 있거나 저장소가 읽기 전용이면 EROFS, `writeCapabilities.allowsWrites = false`.
- 새 오류: `DeviceError.folderNotEmpty`(ENOTEMPTY), `.crossFolderMoveUnsupported`(EXDEV), 한/영 문구 추가.
- 확인: 자동 테스트 157개 통과(W1 26개 추가). 설치본(IPC v2)으로 실기기 읽기 경로 재확인(루트 33개), 쓰기는 확장에서 계속 거부(W2 전).

## D35. W2 확장 쪽 쓰기 구현 (2026-10-22)
- **쓰기 가능 여부는 마운트 시점에 결정**: 확장이 볼륨을 불러올 때 `writeCapabilities`를 묻고, 허용될 때만 권한 비트 `rwx`/`rw-`, open/close·preallocate·확장 속성 연산을 연다. 아니면 이전과 똑같이 읽기 전용(EROFS). 설정을 바꾸면 다시 마운트해야 반영(W4에서 앱이 자동 재마운트).
- **실기기 쓰기 차단(임시)**: W5 실기기 검증 전까지 저장소는 가상 기기 쓰기만 허용. 실기기는 `-diagnostics.finderWritesRealDevices YES` 실행 인자가 있어야 하며 UI는 없다. 테스트로 확인.
- **쓰기 버퍼**: 새 파일·수정 중인 파일은 App Group `FinderWrites/w-<uuid>`에 쓴다. 기존 기기 파일에 처음 쓰거나 크기를 바꿀 때 원본 전체를 받아 온다(0으로 잘라내면 생략). 쓰기는 파일을 줄이지 않는다(동시 쓰기 순서 보호).
- **커밋 = 마지막 쓰기 close**: `FinderWritePolicy.closeAction`(앱 테스트로 검증). 새 파일은 0바이트면 2초 뒤 생성(그 사이 지워지면 기기 호출 없음), 변경 없는 기존 파일은 업로드 안 함. close 응답은 업로드·검증 결과를 그대로 전달.
- **열린 파일 이름 변경**: 아직 기기에 없는 파일은 로컬에서만 이름이 바뀌고, 기기 파일 위로 바꾸면 그 파일을 숨겼다가 커밋 때 `replacing`으로 교체(원자적 저장). 기기 파일은 같은 폴더면 rename, 다르면 move.
- **macOS 관리 파일**: `._*`, `.DS_Store` 등은 확장 안에만 둔다(`FinderWritePolicy.isShadowName`). `.Trashes`, `.fseventsd`, `.Spotlight-V100` 등 폴더 생성은 EACCES.
- **확장 속성 결정(W0 결론 5)**: 확장 메모리에 직접 보관(`FSVolume.XattrOperations`, 항목당 128 KiB). 커널이 `._` 파일을 만들지 않게 되어 호출 수가 줄고, 태그·격리 속성이 마운트 중에는 보인다. 해제하면 사라진다(기기에 저장할 곳이 없음).
- **쓰기 전용 연결**: 확장은 IPC 연결을 두 개 쓴다. 긴 업로드가 읽기·목록 요청을 막지 않는다(가상 기기에서 확인. 실기기는 MTP 세션이 한 번에 한 작업만 하므로 업로드 중 탐색이 기다릴 수 있음 — W5 확인).
- W0 관찰 모드(`WriteObservation`, `observesWrites`)는 실제 쓰기 경로로 대체하며 제거. 가상 기기 진단: 업로드 512 MB 초과분은 내용을 저장하지 않음(메모리 보호), `-diagnostics.demoUploadMBps`로 업로드 속도 제한.

## V9. W2 가상 기기 볼륨 검증 (2026-10-22 22:49–, 설치본 팀 서명)
같은 시각 휴대전화 볼륨은 읽기 전용 유지(`dr-xr-xr-x`, `touch` 거부). 확인은 볼륨을 해제·다시 마운트해 확장 상태를 비운 뒤 가상 기기에서 다시 읽었다.

| 시나리오 | 결과 |
|---|---|
| `cp` 작은 파일 | 내용 일치 |
| Finder 복사(태그 있는 파일) | 내용 일치, `._` 파일 없음, 마운트 중 태그 읽힘 → 다시 마운트 후 없음(설계대로) |
| Finder 폴더 트리(한글·이모지·빈 폴더) | 구조·내용 일치 |
| Finder 200 MB 무작위 파일 | SHA-256 일치 |
| Finder "대치" | 새 내용, 원본·백업 잔여 없음 |
| 기존 파일 끝에 덧붙이기 | 원본 + 6바이트(88123 → 88129), 끝 내용 일치 |
| `touch` 빈 파일 | 2초 뒤 기기에 0바이트 파일 생성 |
| 원자적 저장(`Data.write(.atomic)`) | 최종 내용 v2 |
| `FileManager.replaceItemAt` | 대상 교체 성공 |
| Finder 이동, `rm -r`, Finder 삭제 | 반영, 다시 마운트 후 없음 |
| 공간 부족(200 GB 크기 지정) | close가 `ENOSPC(28)` 반환, 기기에 생성 안 됨 |
| `.DS_Store` | 마운트 중 확장에만 존재, 기기에 없음 |
| **5 GB 닫기 지연**(W0 남은 확인) | 가상 기기 업로드를 `-diagnostics.demoUploadMBps 25`로 제한. Finder 복사가 업로드 내내 close에서 기다린 뒤 **427초 만에 정상 완료**(시간 초과 없음), 다시 마운트 후 5,368,709,120바이트 확인. 업로드 중 다른 폴더 목록·읽기 0.01초(쓰기 전용 연결 효과) |

결론: W0의 남은 위험(수 분 걸리는 close)은 가상 기기 기준 문제없음. 실기기 MTP 속도(약 20 MB/s)에서 5 GB는 4–5분 걸리며 그동안 Finder 진행 막대가 끝 근처에서 멈춘 것처럼 보인다(진행 표시 개선은 추후 검토).

## D36. W3 실패·복구 (2026-10-22)
**기기에 남는 숨김 객체 — 정리 일지(`DeviceLeftoverJournal`)**
- 스테이징 업로드(`.part`), 교체 백업(`.bak`), 지연 삭제 백업(`.deleted`)을 **만들기 전에** 일지에 적고, 정리되면 지운다. 일지는 앱 컨테이너 `Application Support/PhoneBridge/DeviceLeftovers.json`. Finder 쓰기(`FinderWriteCoordinator`)와 앱 전송(`TransferManager`)이 같은 일지를 쓴다.
- **다음 세션에 정리**: 기기가 새 세션으로 연결될 때(가상 기기는 앱 시작 시) 이전 실행·이전 세대의 항목만 처리. 지금 세션에서 진행 중인 항목은 건드리지 않는다.
- 규칙: 스테이징은 삭제. 백업은 원래 이름이 비어 있으면 **되돌리고**(원본 보호), 이미 같은 이름의 파일이 있으면 삭제(새 파일이 자리를 잡은 것). 기록된 임시 이름과 정확히 같은 파일만 다루므로 사용자 파일은 절대 건드리지 않는다. 대상이 없으면 항목만 지우고, 기기가 다시 끊기면 항목을 남겨 다음에 재시도.
- MTP 핸들이 세션마다 바뀔 수 있어(앱 기존 가정) 폴더는 **핸들로 먼저, 안 되면 루트부터의 이름 경로로** 찾는다. Finder 커밋·삭제 요청에 `parentPath`를 추가(IPC v2 필드).
- 결과: 앱이 지연 삭제 30초 안에 종료되면 다음 연결 때 그 파일이 **되살아난다**(삭제보다 원본 보호를 우선한 D33과 같은 방향). 문서화.

**Mac에 남는 쓰기 버퍼 — 복구 목록(`FinderWriteRecovery`)**
- 확장은 실제 파일의 버퍼마다 `<버퍼>.json` 설명(볼륨, 폴더 경로, 파일 이름, 상태 writing/failed, 오류)을 두고, 사용하는 동안 버퍼에 `flock` 잠금을 건다. 업로드 실패 시 상태를 failed로 바꾼다. 볼륨이 해제되면 저장 안 된 파일의 잠금만 풀고 버퍼는 남긴다(관리 파일 버퍼는 삭제).
- 앱은 시작 시, 자기 볼륨 해제 후, 커밋 실패 1초 후, 설정 › Finder를 열 때 버퍼 폴더를 살핀다. **잠금이 없는 버퍼**(해제·확장 중단)와 **업로드 실패 버퍼**를 목록에 올린다. 잠긴 버퍼는 아직 Finder가 쓰는 중이므로 "Mac에 저장"만 허용하고 버리기는 막는다.
- 자동 삭제는 사용자 데이터가 아닌 것만: `s-` 관리 파일 버퍼, 0바이트 버퍼, `.DS_Store`·AppleDouble 내용의 버퍼(설명 파일 이전 빌드가 남긴 것), 버퍼 없는 설명 파일.
- UI: 설정 › Finder › "저장되지 않은 Finder 파일"(이름·볼륨/폴더·크기·상태, "Mac에 저장…", "버리기" 확인), 새로 발견되면 하단 알림. 한/영 문구.
- 버퍼 이름: 실제 파일 `w-<uuid>`, 관리 파일 `s-<uuid>`.

## V10. W3 가상 기기 검증 (2026-10-22 23:10–23:12)
| 상황 | 결과 |
|---|---|
| 앱 시작 시 W2 빌드가 남긴 버퍼 5개 | `.DS_Store` 내용 4개 자동 정리, 200 GB 테스트 파일 1개만 복구 목록(이름 없음) |
| 마운트 중 업로드 실패(공간 부족) | close가 ENOSPC, 1초 뒤 목록에 추가("사용 중" 1개) |
| 파일을 쓰는 도중 강제 해제(`umount -f`) | 확장이 "저장 안 된 파일" 2개의 잠금 해제, 앱 재시작 시 목록 3개·사용 중 0개 |
| 일반 쓰기 | 정상, 일지 항목 남지 않음(단위 테스트로 확인; 앱 컨테이너는 터미널에서 읽기 차단) |
| 기기 쪽 숨김 객체 정리 | 가상 기기는 앱 재시작 때마다 초기화되어 실제 앱에서는 재현 불가 → 단위 테스트(이전 실행 가정)로 확인: 스테이징 삭제, 백업 복원/삭제, 핸들 변경 시 경로로 찾기, 분리 시 보류, 실패 주입으로 만든 잔여물 정리 |
| 설정 화면 "Mac에 저장/버리기" 클릭 | **직접 조작하지 못함**(화면 제어 권한 없음). 같은 동작을 단위 테스트로 확인 |

## D37. W4 쓰기 허용 설정 (2026-10-22)
- 설정 › Finder에 "Finder에서 쓰기" 섹션: **"Finder에서 쓰기 허용" 스위치 + "실험적" 표시**, 기본 꺼짐(사용자 결정). Finder 통합이 꺼져 있으면 비활성.
- 켤 때 확인 창: 실험 기능, 원본 보호 방식(임시 이름 업로드 후 확인·교체), 중요한 파일 백업 권장, Finder 삭제는 휴지통 없음. 끌 때는 확인 없이 바로.
- 안내 문구: 꺼짐 — 읽기 전용(이전 `finder.readOnlyNote` 대체). 켜짐 — 가능한 작업, 닫을 때 업로드되어 큰 파일이 끝 무렵 멈춘 듯 보일 수 있음, 삭제 즉시 반영, 태그 등 Finder 정보는 기기에 저장 안 됨. 실기기 차단 중이면 "지금은 가상 기기에서만" 표시. 바꾸면 다시 마운트되며 열린 파일이 있으면 다시 마운트되지 않음.
- 볼륨 줄마다 "읽기 전용" / "쓰기 가능 (실험적)" 표시(`acceptsWrites`: 설정 켜짐 + 가상 기기 또는 실기기 허용).
- **자동 재마운트**: `setWritesEnabled`가 저장소 허용 상태를 바꾸고(끌 때는 지연 삭제를 먼저 끝냄) 앱이 마운트한 볼륨을 해제 후 다시 마운트한다. 확장은 볼륨을 불러올 때 읽기/쓰기를 정하기 때문. 해제에 실패한 볼륨(열린 파일)은 그대로 두고 상태에 이유를 보인다. 사용자가 터미널 `mount -F`로 붙인 볼륨은 대상이 아니다.
- 확인: 단위 테스트(켜기·끄기마다 재마운트, 같은 값이면 재마운트 없음, 기본값 꺼짐, 실기기는 허용 전까지 읽기 전용). 실제 앱에서 스위치 클릭은 화면 제어 권한이 없어 사용자 확인 필요.

## D38. W5 준비: 실기기 쓰기 범위 제한 (2026-10-22)
- 모든 쓰기 요청(새 폴더·커밋·이름 변경·이동·삭제)이 대상 폴더의 루트부터 경로를 함께 보낸다(IPC v2 필드 추가). W3 정리와 W5 범위 제한에 쓴다.
- `-diagnostics.finderWriteScope "<폴더>"`: 실기기 쓰기를 루트의 그 폴더 안으로만 허용. 루트에서는 그 폴더 자체의 생성·삭제만. 경로를 모르는 요청, 폴더 밖에서 안으로의 이동도 거부(EACCES). 가상 기기는 제한 없음.
- `-diagnostics.showStagingObjects YES`: 숨김 스테이징·백업 객체를 목록에 보여 잔여물 확인에 쓴다.
- `scripts/finder-write-check.sh`: 지정한 볼륨의 테스트 폴더 안에서만 쓰고 자기가 쓴 것만 다시 읽어 해시 비교. 가상 기기 예행연습 18/18 통과.
- 실기기에서 실행은 아직 하지 않았다(사용자 승인 대기).

## D39. 저장소 루트는 0xFFFFFFFF로 보낸다 (2026-10-22, W5에서 발견)
`pb_create_folder`와 `pb_upload_from_fd`가 루트를 0으로 바꿔 libmtp에 넘기고 있었다. Android MTP 서버는 SendObjectInfo의 부모 핸들로 0xFFFFFFFF(PTP 루트)만 받아들이고 0이면 `Invalid Object Handle`(2009)을 돌려준다(SM-S937N 실측). 두 함수 모두 0xFFFFFFFF를 그대로 넘기도록 수정. MoveObject/CopyObject는 기존대로 0(실기기에서 루트 이동은 아직 확인 안 함). 이 버그는 앱 창에서 저장소 루트로 바로 올리는 전송에도 해당했다(이전엔 실기기 루트 업로드를 시험하지 않음).

## V11. W5 실기기 쓰기 검증 (2026-10-22 23:22–23:31)
TEST_PLAN 4-2 표 참조. 자동 18/18, W8 케이블 분리에서 원본 복원 확인, 잔여물 0. 실기기 쓰기는 이번 검증용 실행 인자로만 열었고, 검증 후 일반 실행으로 되돌려 다시 막았다(`touch` 거부 확인).

## D40. 큰 업로드는 조각으로 (2026-10-23, 사용자 승인)
MTP는 한 번에 요청 하나만 처리하므로 한 번에 보내는 업로드는 끝날 때까지 같은 기기의 탐색·읽기를 막는다(V11에서 27.5초). 편집 확장(EditObjects + SendPartialObject)이 있는 기기에서 32 MiB 이상은 빈 객체를 만든 뒤 16 MiB씩 이어 붙인다. 조각마다 세션 작업이 따로라 그 사이에 대기 중인 요청이 실행된다. 스테이징 이름·크기 확인·교체·일지 규칙은 그대로. 편집 확장이 없는 기기는 기존 방식. 루트 핸들은 작업마다 다르다(SendObjectInfo 0xFFFFFFFF, MoveObject/CopyObject 0 — AOSP 확인, 실기기 확인).

## D41. 임시 객체는 Finder 항목이 되지 않는다
조각 업로드 중 임시 객체는 크기가 자라는 상태로 기기에 존재한다. 이것이 Finder 항목(vnode)으로 캐시되면 업로드 뒤 같은 객체와 충돌해 크기·내용이 잘못 보일 수 있다(V12). 확장은 `.phonebridge-` 이름을 목록에서 항상 숨기고, `&staging=1` 진단 마운트에서만 보인다. 앱의 마운트에는 이 값이 붙지 않는다.

## V12. 조각 업로드·루트 이동 실기기 확인 (2026-10-23 00:00–00:11)
`docs/REVIEW_UPLOAD_WAIT_AND_ROOT_MOVE.md` 3장. 탐색 대기 27.5초 → 최대 1.9초, 속도 유지, 1 GiB 해시 일치(수정 후 3/3), 루트 이동 왕복 해시 일치. 이번 시험 파일 20개(약 18 GB)는 사용자 요청으로 테스트 폴더 안에서 삭제(2026-10-23, 지연 삭제 후 진단 마운트에서 숨김 객체 포함 0개 확인). W5 원래 파일(big.bin, plain.bin, 메모 1.txt, 이름 바꾼 폴더/사진 😀.dat)과 폴더는 유지.

## D42. 4차: 정보 패널과 Android | Mac 분할은 자체 구현 (2026-10-23)
macOS 27에서 SwiftUI `.inspector`와 `HSplitView`(Android | Mac)를 함께 쓰면 AppKit의 제약 갱신 패스가 끝나지 않아("more Update Constraints in Window passes than there are views") 앱이 종료됐다. Mac 패널을 켠 상태에서 실행할 때마다, 또는 둘 다 켤 때마다 재현(이분 탐색: 탐색 폴더 열기·패널 내용·최소 너비와 무관, 두 구성요소의 조합). 이전 단계부터 있던 결함으로, 실제 창 캡처 검증에서 처음 드러났다.
- 정보 패널: 상세 영역 오른쪽의 고정 너비(240pt) 열. 창이 좁아 패널이 최소 너비(Android 340 + Mac 260)보다 좁아지면 정보 패널이 자동으로 비켜 준다(`Layout.inspectorFits`).
- Android | Mac: 비율 분할(`SplitPanes`). 경계선을 끌어 비율을 바꾸고 설정에 저장(0.15–0.85, 기본 0.55). 창을 키우면 두 패널이 함께 커진다(`NSSplitView`는 늘어난 폭을 오른쪽에만 줘 Android 목록이 이름 열만 남았음).

## D43. 안전하게 연결 해제
새 연결 상태 `safelyDisconnected`: USB는 연결돼 있지만 MTP 세션을 닫아 케이블을 뽑아도 되는 상태. 순서: 진행 중 전송이 있으면 확인 창(취소 후 해제) → 그 기기의 Finder 볼륨 해제(실패 시 중단하고 안내) → 지연 삭제 정리 → 세션 닫기 → "이제 케이블을 분리해도 됩니다" 알림. 같은 연결의 인터페이스 알림으로는 다시 연결하지 않고, '다시 연결' 또는 다시 꽂으면 연결. 메뉴 기기 › 안전하게 연결 해제(⌘E), 사이드바 기기 우클릭.

## D44. 4차 사용자 경험 기준
- 용어·현지화: `docs/LOCALIZATION.md`(용어집, 운영체제 문자열 한계). macOS 한국어판 용어(훑어보기, 정보 가져오기, 대치…), "마운트" 대신 "Finder에 연결".
- 오류는 "무엇이 문제인지 + 무엇을 하면 되는지" 두 줄: 전송 실패에 해결 방법(`LocalizationManager.remedy`), Finder 연결 문제는 시스템 오류 문구 대신 `FinderProblem`별 안내와 해결 버튼(시스템 설정 열기).
- 시스템 언어를 따르는 SwiftUI 기본 문구(`ContentUnavailableView.search`)는 자체 문구로 교체.
- 첫 실행 안내(4단계)와 도움말 › 시작하기 / 연결 문제 해결. 기기 없을 때 화면에 "기기가 보이지 않나요?" 점검 목록.
- 접근성: 연결 상태 점·Finder 표시에 VoiceOver 레이블, 전송 진행률 레이블, 아이콘 보기 항목의 열기/선택 동작, 장식 이미지는 숨김.
- 단축키 추가: 열기 ⌘O, 정보 가져오기 ⌘I, 이름으로 검색 ⌘F, 안전하게 연결 해제 ⌘E.

## V13. 4차 검증 (2026-10-23)
- 자동 테스트 190개 통과(4차: 상태·해결 문구 번역, 안전한 연결 해제(브로커·앱·Finder), 배치 규칙, 렌더 행렬).
- 오프스크린 렌더 105장(한/영 × 라이트/다크 × 460/640 등): 연결 상태 8종, 기기 없음, 첫 실행 안내, 문제 해결, 전송 행(진행/완료/저장 공간 부족/연결 끊김/취소), Finder 문제 4종, 충돌 창. 직접 확인.
- 실제 창 캡처 40장(진단 실행 인자 `-diagnostics.windowSnapshots`, 개발 빌드, 가상 기기): 한/영 × 라이트/다크 × 900/1280pt, 목록·아이콘·환영·첫 실행 안내·설정. 제약 루프 0회. Mac 패널은 빈 임시 폴더로 고정(첫 실행에서 사용자 다운로드 폴더 목록이 한 번 찍혀 즉시 삭제하고 보호 장치 추가).
- 한계: 오프스크린 렌더는 AppKit 컨트롤(진행 막대, 버튼, 표)을 그리지 못하고, 창 캡처는 사이드바의 반투명 배경을 그리지 못한다(빈 영역으로 보임). 실기기는 이번 확인 시점에 연결돼 있지 않아 새 화면의 실기기 확인은 남음. 메뉴·키보드·VoiceOver의 실제 조작은 화면 제어 권한이 없어 사용자 확인 필요.

## D45. Android → Finder 직접 드래그 = 파일 프로미스 + 전송 대기열 (2026-10-23)
- Android 패널의 행·아이콘은 `DeviceDragItem`(Transferable)을 끈다. 표현 순서: ① 파일 프로미스(`FileRepresentation`, 파일은 `public.data`, 폴더는 `public.folder`, 제안 이름 = 기기의 원래 이름) ② 앱 내부용 텍스트 페이로드(기존 `phonebridge-drag:`). 받는 쪽이 파일을 먼저 고르도록 파일을 앞에 둔다(Finder가 텍스트 조각 파일을 만들지 않게).
- Finder(또는 다른 앱)가 놓기를 받아들일 때만 내려받는다. 내려받기는 `TransferManager` 대기열의 `.download` 작업(`isDragExport`)으로 실행되어 진행률·취소·크기 검증·폴더 재귀를 그대로 쓴다. 대상은 앱 컨테이너의 `tmp/PhoneBridgeDrag/<uuid>/`이고 시스템이 그 파일을 놓은 위치로 복사한다. 사본은 다음 내보내기 때 30분 지난 것, 앱 시작 때 전부 지운다.
- 앱 안의 놓기(Mac 패널, Android 폴더 위)는 계속 텍스트 페이로드를 읽고 내보내기를 일으키지 않는다. 여러 행을 끌면 행마다 같은 선택 페이로드가 오므로 한 번만 처리한다(이전엔 중복 작업이 생길 수 있었음).
- 아이콘 보기는 macOS 26 `dragContainer`로 선택된 항목을 각각 별도 파일로 끈다. 목록 보기는 `TableRow.draggable`.
- 실패하면 받는 앱이 이미 놓기를 포기한 뒤이므로 전송 목록에서 '다시 시도'를 내놓지 않는다(`canRetry = false`). 전송 행 설명은 "끌어 놓은 위치로 다운로드".
- AppKit `NSFilePromiseProvider`를 직접 쓰는 방법은 SwiftUI `Table` 행에서 드래그 세션을 직접 시작해야 해서 택하지 않았다.

## V14. Android → Finder 드래그 가상 기기 검증 (2026-10-23)
- 자동 테스트 199개 통과(새 `DragExportTests` 9개 포함). 놓기가 읽는 `NSItemProvider`에서 꺼낸 파일 크기와 폴더 내용이 가상 기기와 일치, 앱 안 놓기는 내려받기를 일으키지 않음.
- 팀 서명 설치본(빌드 202610231049) 실행 확인. 실제 Finder 창에 놓는 동작은 화면 제어 권한이 없어 사용자 확인 대기(TEST_PLAN 6).

## D46. 네이티브 라이브러리: 고정 소스 → macOS 26용 동적 라이브러리 (2026-10-23)
- 이전: Homebrew의 `libmtp.a`·`libusb-1.0.a`를 정적 연결. 문제 ① Homebrew 병이 이 Mac(macOS 27)용으로 빌드되어 `minos 27.0` — 앱 최소 버전 26.0과 불일치 ② LGPL-2.1 정적 연결은 재연결 가능한 목적 파일 제공 의무.
- 변경: `scripts/build-native-deps.sh`가 libusb 1.0.30·libmtp 1.1.23 업스트림 소스(Homebrew가 고정한 SHA-256으로 검증, Homebrew 다운로드 캐시 우선)를 arm64·macOS 26.0으로 동적 빌드해 `Vendor/native`에 둔다. 설치 이름 `@rpath/…`, 앱 `Contents/Frameworks`에 "Embed Native Libraries" 단계로 서명 복사. 라이선스 전문·저자 목록 함께 보관.
- `ARCHS = arm64`(Apple Silicon 전용 목표, 라이브러리도 arm64 단일).
- 앱 안 고지: `Resources/Licenses/NOTICE.txt`, `LGPL-2.1.txt`, 도움말 › 오픈소스 라이선스.

## D47. 기록(로그)에 개인 정보 남기지 않기
파일·폴더 이름, 기기의 개인 이름(friendly name), Mac 경로, 전송 대상 폴더 이름은 `privacy: .private`, 일련번호가 든 기기 식별자는 `.private(mask: .hash)`. 모델명·USB ID·오류 코드·크기·시간은 공개. 진단 내보내기가 이 기록을 그대로 담으므로 함께 정함.

## D48. 종료는 반드시 끝난다
`applicationShouldTerminate`는 정리(전송 취소 → Finder 해제 → 세션 닫기)를 시작하고, 5초가 지나면 끝나지 않았어도 종료를 승인한다. 이전 구현은 타임아웃이 정리 작업을 "취소"만 해서 취소를 확인하지 않는 대기(예: 응답 없는 XPC)가 있으면 앱이 영원히 남을 수 있었다. 진단 화면 순회가 주 액터 작업 안에서 `terminate`를 불러 교착되던 문제도 수정(런 루프에서 호출).

## D49. 진단 정보 내보내기
도움말 › 진단 정보 내보내기…(연결 문제 해결 창에도 버튼): 앱·macOS·Mac 모델, 설정 요약, 기기(모델·USB ID·상태, 일련번호는 SHA-256 앞 8자리), Finder·전송 상태(이름·경로 없이 상태 종류만), 이번 실행의 앱 기록(`OSLogStore`, 비공개 값은 macOS가 `<private>`로 가림, 최근 3,000줄). 사용자가 고른 위치에 텍스트로 저장만 하고 보내지 않는다. Finder 확장·헬퍼 프로세스의 기록은 샌드박스상 읽을 수 없어 빠진다.

## D50. 안정화에서 고친 것
- Mac 쪽 다운로드 임시 파일 일지(`LocalStagingJournal`): 충돌로 사용자 폴더에 남은 `.phonebridge-….download`를 다음 실행 때 지움(폴더는 앱 범위 보안 북마크로 다시 연다, 정확한 임시 이름만 삭제).
- 미리보기 캐시 상한 2 GB(가장 오래 안 쓴 것부터 삭제).
- 1만 개 선택 드래그 멈춤(O(n²)) → 선택 페이로드 캐시(`DragPayloadKey`: 선택·목록 버전·세대·폴더·검색어).
- C 브리지: 썸네일 실패 시 버퍼 해제, 업로드 이름 복사 실패 처리, 이름 변경 NULL 검사.
- 진단 실행 인자 `-diagnostics.autoMountDemo YES`: 가상 기기도 Finder에 자동 마운트(클릭 없이 마운트 확인).

## V15. 정식 배포 안정화 검증 (2026-10-23 11:00–11:31)
`RELEASE_READINESS.md`. 요약: 테스트 210개 통과, ASan/UBSan·TSan 통과, `leaks` 앱 코드 누수 0, Release 아카이브·엄격 서명 검증·DMG 성공(Apple Development, 배포 불가), Gatekeeper 거부(예상), Developer ID 인증서 없음. 설치본 Finder 마운트는 확장 꺼짐 의심으로 실패(K38).

## V16. Finder 마운트 재확인 (2026-10-23 12:32–12:33, 설치본 202610231128, 가상 기기)
사용자가 PhoneBridge Finder 확장을 다시 켠 뒤, `-settings.finderIntegration YES -settings.showDemoDevice YES -diagnostics.autoMountDemo YES`로 실행.
- 마운트: 실행 1초 안에 `/Volumes/PhoneBridge Demo`(내부 저장공간), `/Volumes/PhoneBridge Demo 2`(SD 카드), 유형 `phonebridge, fskit`. Finder 표시 이름 "가상 Android 기기 – 내부 저장공간"(D31), 용량 256 GB.
- 목록: 루트 8개 폴더, Documents 3개(빈 폴더 포함), SD 카드 2개 폴더.
- 읽기: `메모.txt` 2,048바이트 두 번 해시 동일, 5 GB 가상 영상 앞 64 MiB 읽기, PNG 훑어보기 썸네일 생성(`qlmanage`).
- 쓰기: 쓰기 설정 꺼짐 상태에서 `touch`·`mkdir` 모두 Permission denied, 변화 없음. (볼륨의 `volumeIsReadOnly`는 false로 보고되고 거부는 항목 권한으로 이뤄짐)
- 종료: 앱 1초 안에 종료, 해제 헬퍼가 볼륨 해제, 남은 마운트 0, 세션 정리 로그.
- 기록에 기기 이름은 `<private>`로 남음(D47 확인).
- 미확인: 실기기로 새 빌드(동적 라이브러리) Finder 마운트, Finder 창에서의 클릭 조작.

## D51. 기기에 보내는 이름은 NFC(완성형)
macOS 파일 이름은 조합형(NFD)일 수 있다(압축 해제, 오래된 디스크, 일부 앱). 그대로 보내면 Android에서 자모가 분리되어 보인다. `FileNameRules.deviceForm`(NFC)을 기기 경계에서 적용: `MTPDeviceFileSystem`·가상 기기의 업로드·새 폴더·이름 변경(앱과 Finder 쓰기 모두 이 경로), 업로드 이름 정리, 이름 길이 검사(NFC 기준 — 조합형으로 255바이트를 넘던 이름이 거부되던 문제 함께 해결). 이름 비교는 Swift 문자열 비교가 정규 동치를 쓰므로 이미 두 형태를 같게 본다(충돌 확인 테스트로 확인). 기기에 이미 NFD로 저장된 이름(다른 도구가 쓴 것)은 바꾸지 않는다.

## D52. 큰 다운로드도 조각으로
기기가 부분 읽기(GetPartialObject)를 지원하면 32 MiB 이상 파일을 16 MiB 조각으로 받는다. 조각마다 세션 대기열의 별도 작업이라 목록·썸네일·Finder 읽기가 사이에 끼어든다(D40의 다운로드 짝). 조각이 연결 끊김·취소가 아닌 이유로 실패하면(예: 32비트 오프셋만 지원하는 기기의 4 GiB 이후) 파일을 처음부터 한 번에 다시 받는다. 실기기 속도 영향은 미측정(업로드는 차이 없었음, V12).

## D53. 한 번에 끌어 놓은 항목은 하나의 전송 작업
파일 프로미스는 항목마다 따로 요청되므로 150 ms 안에 같은 기기·세션에서 온 요청을 한 비공개 폴더·한 다운로드 작업으로 묶는다(전송 목록 1줄). 같은 이름(다른 폴더의 같은 이름)은 충돌 질문을 피하려고 다른 묶음으로 나눈다. 작업 중 일부가 실패해도 이미 다 받은 파일은 전달한다(파일은 스테이징 후 이름 변경이라 있으면 완전함, 폴더는 작업 성공일 때만). Finder가 항목을 동시에 요청하는지는 실제 Finder 놓기로 확인 필요.

## D54. 실기기 Finder 쓰기는 설정으로
설정 › Finder › Finder에서 쓰기 허용(실험적) 아래에 "실제 Android 기기에도 쓰기 허용"(기본 꺼짐, 별도 확인 창: 되돌릴 수 없는 삭제, 검증 기종 1종, 백업 권고). 켜면 안내 문구가 검증 범위를 계속 보여 준다. 바꾸면 Finder 볼륨을 다시 마운트한다. 진단 실행 인자 `-diagnostics.finderWritesRealDevices`·`-diagnostics.finderWriteScope`는 그대로 동작한다(범위 제한은 여전히 진단 전용).

## D55. 원본 보호 쓰기는 한 곳(`SafeDeviceWrite`)
`TransferManager.uploadFile`과 `FinderWriteCoordinator`가 따로 갖던 스테이징·크기 확인·백업 교체·복원·일지 기록을 `SafeDeviceWrite`로 합쳤다. 호출하는 쪽 차이는 주입: 앱 전송은 취소 확인(`checkpoint`)과 남은 숨김 파일 경고(`onLeftover`), Finder는 지연 삭제(D33)를 그 바깥에서 유지. 이름 변경 미지원 기기에서 실패한 업로드의 부분 객체(원래 비어 있던 최종 이름)는 두 경로 모두 지운다.

## D56. Finder 확장 상태 파일
확장 기록은 앱이 읽을 수 없어(별도 샌드박스) 확장이 App Group 컨테이너에 `ExtensionStatus.json`을 남긴다: 이벤트 종류(로드/마운트/해제/쓰기 실패 등), 오류 코드·오류 키, 프로세스별 마운트 수, 최근 100개. 파일·폴더·기기 이름 없음, 사용자 홈 경로는 `/Users/…`로 가림. 볼륨마다 확장 프로세스가 따로 뜰 수 있어 쓰기마다 잠금(flock) 아래 다시 읽고 합친다. 진단 내보내기의 "[finder extension]" 절.

## D57. 썸네일 캐시는 최근 사용 순(LRU)
300개가 넘으면 전부 비우던 방식을 600개 LRU로 교체(썸네일 없음 기록은 2,400개). 많은 사진을 스크롤했다 돌아와도 최근 것은 다시 받지 않는다.

## V17. 보완 7건 검증 (2026-10-23 13:14–13:31)
- 테스트 231개 통과(새 21개: 한글 이름 5, 조각 다운로드 3, 드래그 묶음 3, 실기기 쓰기 설정 2, SafeDeviceWrite 3, 확장 상태·진단 3, LRU 2). ASan/UBSan 230개 통과.
- TSan: 230개 통과, 경고 5건 모두 `MTPDeviceSession`(DispatchSerialQueue 실행기 액터)의 open→close 패턴. 같은 액터 패턴의 최소 프로그램으로 TSan 오탐 재현(K39, `scripts/tsan-executor-probe.swift`).
- 설치본 202610231328·202610231330: 업데이트 두 번 모두 Finder 확장 켜짐 유지, 가상 기기 저장소 2개 마운트, 종료 시 해제. 확장 상태 파일이 마운트·해제 때 갱신되고 두 확장 프로세스의 기록이 합쳐짐(크기 증가로 확인, 내용은 macOS 보호로 터미널에서 읽을 수 없음 — 앱 쪽 읽기는 테스트로 확인).
- 미확인: 실기기에서 조각 다운로드 속도·탐색 대기, 실기기 Finder 쓰기 설정 화면 조작, Finder 다중 끌어 놓기의 실제 묶음 동작.

## D58. 최소 macOS 15(Sequoia), Finder 연결은 26 이상 (2026-10-23, 사용자 결정)
- 앱·해제 헬퍼·libmtp·libusb: `MACOSX_DEPLOYMENT_TARGET`·minos 15.0. Finder 확장만 26.0(FSKit URL 자원). FSKit은 약한 연결(`-weak_framework FSKit`, 15.4 전에는 없음).
- `FinderSupport`: 15 → `unavailable`(설정 › Finder는 안내만, 메뉴·사이드바의 Finder 항목 숨김, 서버 시작 안 함), 26 → `manualMount`, 27+ → `full`.
- macOS 26 전용 SwiftUI 다중 끌기(`dragContainer`)는 26 이상에서만, 15에서는 아이콘 하나씩 끌기(앱 안 놓기는 여전히 선택 전체).
- 검토한 대안: 14(Sonoma)는 잠금 API(Synchronization, 15)를 바꿔야 하고, 13 이하는 Observation 전면 교체 필요 — 사용자가 15를 선택.

## D59. 설치 경로: DMG + 터미널(설치 스크립트, Homebrew Cask)
- 셋 다 같은 공증 DMG. `scripts/install.sh`는 curl로 받은 파일이 격리 표시 없이 Gatekeeper 검사를 건너뛰는 점을 메우려고 직접 검사한다(SHA-256, Developer ID, 팀 ID, `spctl` 공증, 번들 ID). 실패하면 설치하지 않고 우회 수단을 제공하지 않는다. 기존 앱은 휴지통으로, 새 앱은 숨김 이름으로 복사·재검증 후 교체.
- Homebrew Cask(`packaging/homebrew/Casks/phonebridge.rb`): arm64·Sequoia 이상 조건, 종료 후 제거, `zap`으로 컨테이너 정리. `brew style` 통과.
- `scripts/release.sh`가 버전 이름 DMG와 고정 이름 DMG(`PhoneBridge.dmg`, "latest" 주소용)·체크섬·`install.sh`를 만들고, `scripts/publish-metadata.sh`가 공증 확인 후 Cask·스크립트의 버전·체크섬·저장소를 채운다.

## V18. 최소 버전·설치 경로 검증 (2026-10-23 14:20–14:35, macOS 27 Mac)
- 테스트 233개 통과(15 대상 빌드, macOS 15 Finder 차단 동작 2개 추가). 현지화 검사 통과.
- Release 아카이브: 앱·헬퍼·libmtp·libusb minos 15.0, 확장 26.0, `LSMinimumSystemVersion` 15.0, FSKit weak, arm64 — 스크립트 자동 검사 통과. Apple Development 서명이라 배포 불가(K35).
- `install.sh`: 개발 서명 DMG 거부(Developer ID 아님), 체크섬 변조 거부, http 거부, macOS 14 거부. 서명·공증 확인 명령을 시험용으로 대체한 환경(임시 폴더·임시 HOME)에서 설치·업데이트(이전 앱 휴지통)·제거(`--zap`) 흐름 통과. 디스크 이미지는 매번 해제됨.
- 시험 중 실수: 첫 시험에서 임시 HOME 지정이 적용되지 않아 시험용 앱 사본 2개("PhoneBridge.app 20261023-14…", Release 시험 빌드)가 사용자의 실제 휴지통으로 들어감. 터미널은 휴지통을 읽을 수 없어 지우지 못했고, 사용자에게 알림.
- Cask: `brew style` 통과. `publish-metadata.sh`의 치환은 복사본에서 확인.
- 미검증: macOS 15·26에서 실제 실행(가상 머신 도구 없음), 공증 DMG로의 실제 설치(인증서 없음), Homebrew 탭 설치.

## V19. 첫 공증 릴리스 빌드 (2026-10-23 14:49–14:53, 0.4.0, 시험용)
- 준비(사용자): Developer ID Application 인증서 발급·개인 키 백업 확인, `notarytool` 자격 증명 `phonebridge-notary` 저장.
- `scripts/release.sh KB2PLX99H6 phonebridge-notary`: Release 아카이브 → Developer ID 서명(앱·확장·헬퍼·라이브러리, 타임스탬프) → 최소 버전 검사 통과 → 앱 공증 **Accepted**·스테이플 → DMG 공증 **Accepted**·스테이플 → `spctl` "Notarized Developer ID". 산출물 `~/Library/Developer/PhoneBridge/release/0.4.0-202610231449/`.
- **K35의 FSKit 질문 해결**: Developer ID용 "Mac Team Direct Provisioning Profile"에 앱 `com.apple.developer.fskit.mount`, 확장 `com.apple.developer.fskit.fsmodule`, App Group이 들어가고 `ProvisionsAllDevices = true`(모든 Mac). Xcode가 자동 생성.
- `install.sh`: 공증 DMG 두 이름 모두 `--check` 통과(체크섬, Developer ID, 팀, 공증). 실제 설치로 `/Applications`의 개발 빌드를 교체(이전 앱은 휴지통), 설치된 앱 `spctl` accepted.
- 공증 빌드에서 가상 기기 Finder 마운트 2초 안에 2개, 종료 시 해제. 서명 주체가 Apple Development → Developer ID로 바뀌었는데도 Finder 확장 켜짐이 유지됨.
- 남음: 배포 저장소·버전 번호 결정 후 공개 업로드, 새 사용자 계정·다른 Mac에서의 첫 실행, macOS 15·26 실행(K41).

## D60. 1.0.0 공개: 배포 전용 공개 저장소 (2026-10-23, 사용자 결정)
- `garam918/phonebridge`(공개): README(한/영), 설치·개인정보·사용 설명서, NOTICE·LGPL 전문, `install.sh`. **소스 코드는 올리지 않음**(PhoneBridge 라이선스 미정, LGPL 검토 전).
- `garam918/homebrew-phonebridge`(공개): `Casks/phonebridge.rb`.
- 커밋 작성자는 GitHub noreply 주소(`…+garam918@users.noreply.github.com`, 두 저장소의 로컬 설정만) — 개인 이메일이 공개 기록에 남지 않게.
- 버전 `MARKETING_VERSION` 1.0.0.

## V20. 1.0.0 릴리스 (2026-10-23 15:07–15:20)
- 공증 빌드: 처음 두 번은 내보내기 서명 중 "timestamps differ by 202/348 seconds - check your system clock"으로 실패. 이 Mac 시계는 정확(sntp 오차 0.001초), 직접 서명 시험에서 Apple 타임스탬프 서버 응답이 느렸음 → 일시적 서버 지연으로 판단, 세 번째에 성공(K43).
- 앱·DMG 공증 Accepted, Gatekeeper "Notarized Developer ID", SHA-256 `12bff234…0dd6106a`.
- GitHub 릴리스 v1.0.0: `PhoneBridge-1.0.0.dmg`(+.sha256), `PhoneBridge.dmg`(+.sha256), `install.sh`.
- GitHub에서 확인: `curl … | bash -s -- --check` 통과, `brew tap`·`brew info`·`brew fetch`(체크섬)·`brew audit --online` 통과, `curl … | bash`로 설치본 0.4.0 → 1.0.0 실제 업데이트(이전 앱 휴지통), 설치본 Gatekeeper 통과·실행.
- 남음: 새 사용자 계정·다른 Mac 첫 실행, macOS 15·26 실행(K41), Homebrew로의 실제 설치(이 Mac에는 이미 앱이 있어 내려받기·검사까지만).

## D61. 이동은 복사한 것만 지운다 (2026-10-23, 점검 H1·H5·H6)
- **폴더 삭제 전 확인**: 이동(기기 → Mac, Mac 경유 기기 내 이동)은 원본 폴더를 지우기 직전에 `childCount`(GetObjectHandles 개수)로 비었는지 확인하고, 비어 있지 않으면 지우지 않고 작업에 "기기에 그대로 둔 폴더"로 표시한다. Android는 폴더를 재귀 삭제하므로, 전송 중 새로 생긴 파일·숨김 임시 객체·libmtp가 메타데이터를 못 읽어 목록에서 조용히 뺀 객체가 복사 없이 지워질 수 있었다. 개수는 목록(`Get_Files_And_Folders`)이 아니라 핸들 목록에서 세므로 목록에서 빠진 객체도 포함된다(`pb_count_children`).
- Mac 경유 기기 내 이동은 복사가 끝난 뒤 트리를 다시 걷지 않고, 실제로 복사한 항목만 지운다.
- 삭제 작업(사용자가 고른 "삭제")은 그대로 재귀 삭제한다.
- **작업 내 충돌은 항상 둘 다 유지**: 한 작업이 이미 쓴 Mac 파일·폴더(파일 시스템 식별자로 비교 — 대소문자·유니코드 정규화 차이 포함)와 겹치면 묻지 않고 번호를 붙인다. "모두 대치"가 걸려 있어도 자기 결과를 덮지 않는다(이동이면 두 원본이 모두 지워지던 경로).
- 기기 객체 이름은 앞뒤 공백을 자르지 않는다(`a.txt`와 `a.txt `가 같은 이름이 되던 문제). 기기 정보 문자열(제조사·모델 등)은 계속 정리한다.
- **기기 안 복사·이동의 대치**도 `SafeDeviceWrite.swap`을 쓴다: 백업 이름을 일지에 먼저 적고 옮기므로, 분리·충돌로 복원하지 못해도 다음 세션 정리에서 되살린다.
- 테스트: 가상 기기에 `deletesFoldersRecursively`(Android 동작), `unlistedObjects`(libmtp 목록 누락), `nodesAddedAfterDownload`(전송 중 기기 쓰기) 결함 주입 추가. 새 회귀 테스트 7개 중 H1·H5 4개는 수정을 끈 상태에서 실패함을 확인.
- 남음: Android의 폴더 재귀 삭제와 `LIBMTP_Get_Children` 동작은 실기기 확인 전(K1).

## D62. IPC 상대는 서명 요구 조건으로만 확인 (2026-10-23, 점검 H2)
- Finder 브로커 소켓은 상대의 서명 식별자 문자열만 비교했다. 식별자는 누구나 `codesign -s - -i <확장 ID>`로 붙일 수 있어, 같은 사용자의 아무 프로세스가 휴대폰 파일을 읽고(쓰기 허용 시 지우고) 할 수 있었다.
- 이제 감사 토큰으로 얻은 상대 코드에 `SecCodeCheckValidity`로 요구 조건을 검사한다(`Shared/CodeSigning/PeerRequirement.swift`, 앱·확장·해제 헬퍼 공용).
  - 팀 빌드: `(identifier 앱 or identifier 확장) and anchor apple generic and certificate leaf[subject.OU] = 팀` — Apple Development·Developer ID 모두 해당.
  - 팀 없는 ad-hoc 빌드·단위 테스트: 자기 자신과 같은 실행 파일만(`cdhash`). 이 빌드에서는 FSKit이 확장을 싣지 않으므로(K22) 잃는 기능이 없다.
  - 요구 조건을 만들 수 없으면 모든 연결을 거부한다.
- 해제 헬퍼도 같은 헬퍼로 팀 조건을 만든다(ad-hoc은 이전처럼 식별자만 — 앱 번들 전용 XPC 서비스).
- 확인: 설치된 1.0.0(Developer ID, 팀 KB2PLX99H6)에 `codesign --verify -R`로 같은 조건을 적용 — 실제 앱·확장 통과, 확장 식별자로 ad-hoc 서명한 위조 실행 파일은 거부(이전 식별자 검사는 통과시킴), 다른 팀 조건은 실제 확장도 거부. 단위·통합 테스트 7개 추가.
- 남음: W5 쓰기 범위 검사가 확장이 보낸 `parentPath`를 믿는 점은 그대로다. 이제 상대가 우리 확장으로 한정되므로 공격 경로가 아니라 확장 버그에 대한 안전장치 문제다.

## D63. 지연 삭제는 대치가 끝날 때까지 기다린다 (2026-10-23, 점검 H3·M4·M5)
- **H3**: Finder "대치"는 삭제 → 새 파일 쓰기 → 닫을 때 commit 순서다. 30초 유예 타이머가 진행 중인 업로드와 무관하게 만료돼, 큰 파일(실기기 약 0.5 GB 이상)의 업로드가 그 뒤 실패하면 원본이 없었다. 이제 유예가 끝날 때 다음 중 하나면 다시 유예를 준다.
  - 같은 이름(같은 폴더)으로 가는 commit·rename·move가 대기 중이거나 실행 중
  - 확장이 같은 저장소·폴더·이름의 쓰기 버퍼를 아직 쥐고 있음(매니페스트 `writing` + 잠금). Finder가 아직 새 파일을 복사해 넣는 중
  - 결과는 그 요청이 정한다: 성공하면 백업 삭제, 실패하면 원래 이름으로 복원.
- 해제·연결 끊김·쓰기 끄기·종료 때의 `finishAllPendingDeletes`도 같은 규칙: 실행 중인 요청이 있으면 맡기고, 쓰는 중인 버퍼가 있으면 백업을 기기에 일지와 함께 남겨 다음 세션에 복원한다(D36 원본 보호 우선).
- **M5**: rename을 지원하지 않는 기기는 파일을 숨길 수 없으므로 Finder에서 파일 삭제를 거부한다(ENOTSUP). 업로드 쪽의 "rename 없으면 대치 금지"(D55)와 같은 원칙. 빈 폴더 삭제와 새 파일 쓰기는 그대로. 이런 기기의 파일 삭제는 PhoneBridge 창에서 한다.
- **M4**: 복구 목록의 "Mac에 저장"은 대상 파일을 먼저 지우지 않고, 같은 볼륨의 임시 위치에 복사한 뒤 `replaceItemAt`으로 원자적으로 바꾼다. 복사가 실패하면 기존 파일이 그대로다.
- 테스트 5개 추가, 수정을 끈 상태에서 5개 모두 실패함을 확인.
- 남음: 버퍼 매니페스트의 폴더 경로는 "최선 노력"이라, 경로가 없으면 같은 저장소의 같은 이름 버퍼만으로도 유예가 늘어난다(안전한 쪽). Finder가 임시 이름에 쓴 뒤 rename하는 저장 방식은 rename 요청이 올 때까지 버퍼 이름이 달라 보호받지 못할 수 있다. 실기기 확인 전.

## D64. 기기가 준 이름은 경로 한 칸으로만 쓴다 (2026-10-23, 점검 H4)
- 기기가 보고한 파일 이름을 Mac 경로에 그대로 붙여, `..`·`../../x`·`a/b` 같은 이름을 보고하는 비정상·악의적 MTP 기기(리눅스 가젯 등)가 사용자가 고른 폴더 밖에 쓰거나, `..` 폴더를 상위 폴더에 합치게 할 수 있었다. Android는 이런 이름을 만들지 않는다.
- **MTP 경계**: `MTPDeviceFileSystem`이 객체 이름을 `FileNameRules.singleComponent`로 정리한다 — `/`·NUL → `_`, 빈 이름·`.`·`..` → `_`, 그 밖의 이름은 그대로. 전송·미리보기·끌어다 놓기·Finder 볼륨 목록이 모두 정리된 이름을 받는다.
- **Mac 쓰기 지점**: 기기 이름으로 Mac 경로를 만드는 곳(다운로드 대상, 폴더 안 하위 경로, Mac 경유 복사의 임시 폴더, 끌어다 놓기 묶음, 미리보기 캐시)은 `LocalFileIO.child`/`descendant`를 거친다. 이름을 다시 정리하고, 결과가 그 폴더 바로 아래가 아니면 `.invalidName`으로 거부한다(가상 기기처럼 경계를 거치지 않는 파일 시스템에도 적용되는 이중 방어).
- 부작용: 정리된 이름으로 기기 쪽 이름을 되돌리는 경우(대치 실패 후 복원 등) 원래의 `/` 들어간 이름 대신 `_` 이름이 된다. Android에서는 생기지 않는 이름이라 받아들인다.
- 테스트 4개 추가(이름 규칙, 경로 가두기, 가상 기기의 적대적 이름 다운로드, 모의 MTP 백엔드 경계). 정리를 끈 상태에서 4개 모두 실패함을 확인.
- 남음: 255바이트를 넘는 이름은 정리하지 않고 Mac 쓰기 오류로 실패한다. 핸들 0·0xFFFFFFFF 같은 예약 핸들을 보고하는 기기 처리(점검 낮음 항목)는 그대로.

## D65. 큰 폴더 응답·종료 흐름 (2026-10-23, 점검 M1·M2·M3)
- **M1 — Finder 볼륨 먹통**: 항목이 약 3만 5천 개를 넘는 폴더는 목록 응답이 헤더 한도(4 MiB)를 넘었다. 확장은 프레임을 거부하면서 나머지 바이트를 읽지 않고 연결을 유지해, 이후 모든 요청이 남은 바이트를 응답으로 읽어 볼륨 전체가 다시 마운트할 때까지 동작하지 않았다.
  - 서버: 헤더에 담기지 않는 응답은 `encodedInBody` 표시와 함께 본문(64 MiB, 약 50만 항목)으로 보낸다. 그보다 크면 읽을 수 없는 프레임 대신 EFBIG 실패로 답한다.
  - 클라이언트: 서버의 실패 응답이 아닌 모든 전송 오류(프레임 크기 초과, 해석 실패, 읽기·쓰기 실패) 뒤에는 연결을 버리고 다음 요청에서 새로 연결한다.
  - IPC 프로토콜 버전 2 → 3. 앱과 확장은 한 번들로 함께 바뀌지만, 업데이트 직후 이미 마운트된 볼륨이 이전 확장 프로세스로 남아 있으면 버전 불일치로 실패할 수 있다(다시 마운트하면 해결).
- **M2 — 종료가 정리를 건너뜀**: 취소된 작업이 기기 응답을 기다린 뒤 충돌 질문을 띄우고 답을 무한정 기다렸다. 종료 단계는 하나의 5초 예산을 나눠 쓰므로 Finder 볼륨 해제·MTP 세션 종료가 건너뛰어졌다.
  - 충돌 질문 직전에 취소를 확인한다(`decide`).
  - 종료 순서를 `ShutdownSequence`로 분리: 전송 중지는 최대 2초, 그 뒤 Finder 정리와 세션 종료는 항상 실행한다(전체 5초 감시는 그대로).
- **M3 — 묻지 않고 전송 취소**: 전송이 진행 중이면 ⌘Q에 확인 대화상자("진행 중인 전송 N개를 취소하고 종료할까요?", 기본 버튼 "계속 전송"). 마지막 창을 닫아도 전송 중이면 앱이 종료되지 않고 전송을 계속한다(Dock 아이콘으로 창을 다시 연다).
- 테스트 7개 추가. 수정을 끈 상태에서 대응하는 5개가 실패함을 확인.
- 남음: 창을 닫은 뒤 Dock 아이콘으로 `Window` 장면이 다시 열리는지, 확인 대화상자의 실제 모양은 실제 앱에서 확인하지 않았다. 전송이 끝난 뒤 창 없이 남은 앱은 자동으로 종료하지 않는다.

## D66. 공개 로그에는 개인정보를 남기지 않는다, 릴리스는 라이브러리를 항상 다시 빌드 (2026-10-23, 점검 M12·M13·M14)
- **M12**: 폴더 목록 실패 로그가 `FileItemID`를 공개로 남겨 기기 일련번호가 통합 로그와 진단 보고서에 평문으로 들어갔다(PRIVACY.md와 어긋남). 이제 기기 ID는 해시, 저장소·객체 번호만 공개.
- **M13**: 공개 로그에서 뺀 것
  - `DeviceError.technicalDetail`의 Mac 경로·시스템 메시지 → 공개 로그는 `logDetail`(로컬 파일 오류에서는 없음). 사용자에게 보이는 "자세히"는 그대로.
  - macOS 오류의 `localizedDescription`(파일 이름을 인용) → 공개는 `publicSummary`(도메인·코드), 설명은 비공개.
  - 앱 → 확장으로 넘어가는 오류 메시지(확장이 공개로 기록하고 확장 상태 파일에 남김)에서도 `localizedDescription` 대신 도메인·코드.
  - 브로커 소켓 경로(계정 이름 포함)와 그 경로가 들어간 bind/connect 오류 메시지, 확장의 이전 파일 이름 1곳, 창 스냅숏 폴더 경로.
  - 마운트 지점(`/Volumes/PhoneBridge <모델>`, D31)은 공개로 둔다(표시: `log-privacy: public-ok`).
- `scripts/check-log-privacy.py`: 공개로 기록되는 값 중 경로·이름·ID·시스템 설명을 찾아 실패. 원래의 문제 4곳을 되돌리면 모두 잡는 것을 확인. 단위 테스트 2개(`logDetail`, `publicSummary`).
- **M14**: `release.sh`가 `Vendor/native`에 라이브러리가 있으면 소스 체크섬 확인 없이 그대로 Developer ID로 서명·공증했다. 이제 릴리스마다 `build-native-deps.sh --force`로 고정·SHA-256 검증된 소스에서 다시 빌드한다(이 Mac에서 14초). 릴리스 시작 때 현지화·로그 개인정보 검사도 실행.
- `build-native-deps.sh`의 `*.la` 지우기에 `(N)`을 붙여, 일치하는 파일이 없을 때 zsh가 스크립트를 멈추지 않게 했다.
- 남음: 진단 보고서는 macOS가 가리는 만큼만 가린다(비공개 값 기록을 켠 Mac에서는 이름이 보일 수 있음). `release.sh`의 DMG 서명이 팀을 지정하지 않는 점(점검 낮음)은 그대로.

## V21. 1.0.1 릴리스 빌드 (2026-10-23 16:23–16:30, 공개 전)
- 내용: 점검 수정 D61–D66(높음 6개, 중간 M1–M5·M12–M14). 릴리스 노트 `docs/RELEASE_NOTES.md`.
- 사전 검사: 현지화·로그 개인정보 검사 OK, 테스트 265개 통과, 정적 분석 신규 경고 없음.
- 첫 시도는 내보내기 서명에서 "timestamps differ by 189 seconds"로 실패(K43과 같음). 시계 오차 0.0008초(sntp) — 타임스탬프 서버 지연으로 보고 재시도, 성공.
- `release.sh`가 이제 라이브러리를 검증된 소스에서 다시 빌드(D66). 앱·DMG 공증 Accepted, 스테이플, Gatekeeper "Notarized Developer ID". 산출물 `~/Library/Developer/PhoneBridge/release/1.0.1-202610231627/`, SHA-256 `1bef83ef…0ef43f8a`.
- 추가 확인: DMG 안 앱 버전 1.0.1(빌드 202610231627), 앱·확장·헬퍼 모두 `get-task-allow` 없음, 서명된 확장이 브로커 요구 조건(D62)을, 앱이 해제 헬퍼 조건을 만족, `install.sh --check --dmg` 통과.
- `publish-metadata.sh`로 Cask를 1.0.1로 갱신(`install.sh`는 변경 없음). GitHub 업로드·탭 갱신은 사용자 확인 대기.

## D67. 버전 번호는 1.0.0 유지 (2026-10-24, 사용자 결정)
- `MARKETING_VERSION`을 1.0.0으로 되돌리고, Cask를 공개된 1.0.0 값으로 복원. V21의 1.0.1 산출물은 배포하지 않는다.
- 참고: 같은 번호로 다시 배포하면 Homebrew·`install.sh`는 이미 1.0.0을 설치한 사용자에게 업데이트로 알리지 않고, 이미 공개된 1.0.0 DMG의 SHA-256과 달라진다.

## V22. 수정 빌드 설치 검증 (2026-10-24 14:29–14:47, 이 Mac, 실기기 SM-F731N 연결)
- 공증된 수정 빌드(V21, 앱 정보 1.0.1)를 `install.sh --dmg`로 설치해 검증한 뒤, `install.sh`로 공개 1.0.0(빌드 202610231507)을 다시 설치했다. 사용자 설정은 바꾸지 않고 Finder 연결은 실행 인자(`-settings.finderIntegration YES` 등, 그 실행에만 적용)로 켰다. Finder 확장은 사용자가 시스템 설정에서 켰다.
- **종료 정리(M2)**: 실기기 세션이 열린 상태 → 약 1초에 종료, 세션 닫힘. 볼륨 4개(가상 2, 실기기 2) 마운트 상태 → 1.4초에 종료, 해제 헬퍼가 4개 모두 해제(헬퍼의 서명 조건 정리 후에도 앱을 받아들임), 세션 닫힘, 소켓 삭제, 시간 초과 없음.
- **Finder 연결(H2·프로토콜 v3)**: 4개 볼륨 0.4초 안에 마운트. 가상 기기: 목록, 파일 읽기·복사(2.5 MB 크기 일치), 범위 읽기, 쓰기 끔 상태에서 쓰기 거부. 실기기(읽기 전용): 루트·DCIM·Camera(2,626개, 19초 — K10)·Screenshots(402개) 목록, 범위 읽기, 큰 목록 뒤에도 연결 정상.
- **H2 공격 재현**: 확장 식별자로 ad-hoc 서명한 프로그램과 일반 프로세스 모두 브로커가 거부("rejected Finder broker client"). 1.0.0은 식별자만 보고 받아들이던 경우.
- **로그(M12·M13)**: 일반 실행에서 기기 ID `<mask.hash>`, 소켓 경로 `<private>`. Xcode·`xcodebuild test` 실행은 `OS_ACTIVITY_DT_MODE` 때문에 비공개 값이 그대로 저장되므로 개인정보 확인에 쓸 수 없다(작은 시험 프로그램으로 확인).
- 확인 못 함: 전송 중 종료 확인 창의 모양, 창을 닫은 뒤 Dock으로 다시 열기, 수만 개 폴더(M1)의 실제 Finder 동작, 실기기 이동·대치(H1·H5·H6).
- 새 문제 K44(아래), 관찰: 마운트 원본 URL(`mount` 출력)에 기기 일련번호가 들어 있어 같은 Mac의 다른 사용자도 볼 수 있다(점검 낮음 항목에 추가).

## D68. 설치 스크립트가 남는 사본의 등록을 지운다 (2026-10-24, K44)
- `install.sh`가 DMG를 열어 검증·복사하는 동안 macOS가 DMG 안의 앱을 LaunchServices에 등록하고, 분리한 뒤에도 등록이 남았다(이전 스크립트로 전체 설치해 재현). 이런 사본은 Finder 확장 선택을 흐릴 수 있다(K44).
- 이제 DMG를 분리하기 전에 그 사본과 확장의 등록을 지우고(`lsregister -u`, 검사 모드 포함), 휴지통으로 옮긴 이전 앱(제거 모드 포함)의 등록도 지운다. 파일은 건드리지 않는다.
- 스테이징 경로는 지우지 않는다: LaunchServices가 옮겨진 번들을 따라가므로 설치된 앱의 등록까지 지워진다(시험 중 확인한 부작용). 설치 직후 확장 등록은 `lsregister`로 할 수 없고 앱 첫 실행 때 된다.
- 확인(이 Mac, 공개 1.0.0 DMG로 같은 버전 재설치): 이전 스크립트는 DMG 사본 등록을 남김, 새 스크립트는 남는 사본 0개·휴지통 사본 등록 0개, 첫 실행 뒤 `/Applications` 확장 등록 정상. 제거 모드는 실행해 보지 않았다.
- 공개된 1.0.0 릴리스의 `install.sh`(GitHub `latest/download/install.sh`)는 그대로다. 다시 올려야 사용자에게 적용된다.

## D69. MIT 라이선스로 소스 공개, 수정 빌드를 먼저 배포 (2026-10-25, 사용자 결정)
- PhoneBridge 자체 라이선스는 MIT(저작권자 Garam Im). 저장소 루트 `LICENSE`, 앱 `NOTICE.txt`(MIT 전문 + LGPL 고지), `NSHumanReadableCopyright`. libmtp·libusb는 LGPL-2.1 그대로(동적 연결).
- 소스는 새 저장소가 아니라 기존 배포 저장소 `garam918/phonebridge`에 올린다(D60의 "소스는 올리지 않음"을 바꿈). 루트의 `install.sh`·`NOTICE.txt`·`LGPL-2.1.txt` 사본은 프로젝트 안의 원본(`scripts/`, `PhoneBridge/Resources/Licenses/`)으로 옮긴다. README는 설치 안내 + 소스 빌드.
- 공개 순서: 배포 중인 1.0.0의 보안 결함(H1–H6 등)이 코드·점검 보고서 공개로 먼저 알려지지 않도록, 수정 빌드를 1.0.0 번호 그대로 먼저 배포(v1.0.0 릴리스 파일 교체, Homebrew Cask SHA-256 갱신)한 뒤 코드를 올린다.

## V23. 수정 빌드 배포와 소스 공개 (2026-10-25 14:03–14:30)
- 빌드: `release.sh`로 1.0.0(빌드 202610251403), MIT 저작권 표기·고지 포함. 앱·DMG 공증 Accepted(첫 시도), SHA-256 `1faeffdf…ae64622d`. 확인: 앱 버전·저작권, `get-task-allow` 없음(3개 번들), 확장이 브로커 요구 조건(D62) 만족, `install.sh --check` 통과, 테스트 265개.
- 공개(사용자가 터미널에서 실행 — 이 세션의 권한 설정이 공개 업로드를 막음): ① v1.0.0 릴리스 파일 5개 교체 ② 릴리스 설명에 수정 빌드 안내 ③ Homebrew 탭 Cask SHA-256 갱신(11d29d1) ④ 소스 푸시(613e9f2, 파일 162개, 작성자 noreply).
- ①과 ③ 사이 약 20분 동안 Homebrew 설치는 체크섬 불일치로 실패했다(파일은 새 DMG, Cask는 이전 체크섬). 다음에는 파일 교체 직후 바로 탭을 갱신한다.
- 공개 결과 확인: 공개 `install.sh`(latest)가 프로젝트와 같고 `--check` 통과, 받은 DMG가 공증 빌드와 같음, `brew fetch` 체크섬 통과, GitHub가 라이선스를 MIT로 인식, README 링크 13개 모두 존재, 빌드 산출물·Vendor·자격 증명 파일 없음.
- 남음: 저장소 "Private vulnerability reporting"이 꺼져 있어 README의 보안 신고 안내가 아직 동작하지 않음(저장소 Settings › Security에서 켜야 함). 이 프로젝트 폴더는 git 저장소가 아니므로 이후 변경은 `~/Library/Developer/PhoneBridge/publish/phonebridge`로 옮겨 커밋해야 한다.

## D70. 보안 신고는 Issue로 연락만 요청 (2026-10-25, 사용자 결정)
- 저장소의 비공개 취약점 신고 기능은 켜지 않는다. 대신 `SECURITY.md`: 제목 "Security contact"로 Issue를 열어 영향받는 부분만 적고(재현 방법·코드·로그는 쓰지 않음), 관리자가 그 Issue에서 비공개 전달 방법을 답한다. README는 이 파일을 가리킨다.
- 신고용 이메일 주소는 공개하지 않는다(정한 주소 없음).

## D71. 앱 아이콘: "다리" (2026-10-25, 사용자 결정)
- 후보 3개(폰과 폴더, 다리, 연결 고리, `design/app-icon/*.svg`) 중 2번 "다리": 녹색(Android)·파란색(Mac)으로 나뉜 배경 위 흰 현수교. 이름과 바로 이어지고 16px에서도 아치 모양이 남는다.
- 원본 `design/app-icon/candidate-2-bridge.svg`(1024 캔버스, 824px 둥근 사각형). macOS 내장 SVG 렌더링(AppKit)으로 16–1024px PNG 10개를 만들어 `AppIcon.appiconset`에 넣었다. 다시 만들 때는 같은 방식으로 SVG에서 렌더링한다.
- 확인(macOS 27): actool이 `AppIcon.icns`를 경고 없이 생성, 시스템이 표시하는 아이콘(`NSWorkspace`)에 회색 틀 없이 표준 둥근 사각형으로 인식되고 유리 테두리가 더해짐.
- 공개된 1.0.0 빌드에는 아직 없다(다음 릴리스부터).

## D72. 가상 기기(테스트용)를 앱에서 뺀다 (2026-10-26, 사용자 결정)
- 사이드바 "가상 기기 (테스트용)"와 설정 › 일반 "가상 기기 표시"를 없앴다. 가상 기기는 개발 확인용 실행 인자 `-diagnostics.virtualDevice YES`로만 나타난다(저장되지 않음). 자동 테스트와 휴대전화 없이 하는 Finder 확인(`-diagnostics.autoMountDemo`)이 이 경로를 쓴다. 예전 설정 키(`settings.showDemoDevice`)는 더 읽지 않는다.
- Finder 쓰기는 스위치 하나(D54의 두 단계 대신): "Finder에서 쓰기 허용(실험적)"이 휴대전화 쓰기를 켜고, 확인 창은 실기기 문구(되돌릴 수 없는 삭제, 백업 권고)를 쓴다. 저장 키를 `settings.finderWritesDevices`로 바꿔, 예전에 가상 기기 전용으로 켠 동의가 휴대전화 쓰기로 이어지지 않게 했다(업데이트 후 꺼진 상태). 진단 인자 `-diagnostics.finderWritesRealDevices`·`finderWriteScope`는 그대로.
- 테스트: 예전 키가 새 설정으로 넘어가지 않음, 진단 인자 동작, 스위치 하나로 쓰기 허용·해제. 265개 통과.
- 배포: 사용자 결정으로 버전 1.0.0 유지, v1.0.0 파일 교체(D67·D69와 같은 방식), 새 아이콘(D71) 포함.

## V24. 수정 빌드 2 배포 (2026-10-26 15:17–15:35, 1.0.0 유지)
- 빌드 202610261517: 가상 기기 제거·Finder 쓰기 스위치 하나(D72), 새 아이콘(D71). `release.sh` 사전 검사(현지화·로그 개인정보) OK, 테스트 265개, 앱·DMG 공증 Accepted, Gatekeeper 통과, `get-task-allow` 없음(3개 번들), 앱 안 `AppIcon.icns`가 다리 아이콘, 예전 "가상 기기 표시" 문구 없음. SHA-256 `64351a32…56964de`.
- 배포 순서(V23의 Homebrew 공백을 피함): ① v1.0.0 파일 5개 교체 → ② 바로 탭 Cask 갱신(f338aab) → ③ 릴리스 설명에 수정 빌드 2 안내·새 체크섬 → ④ 소스 푸시(e511706, 28개 파일). 이번 세션에서 공개 업로드가 막히지 않았다.
- GitHub에서 확인: 두 이름의 체크섬 일치, `curl … | bash -s -- --check` 통과, `curl … | bash`로 이 Mac 설치본을 새 빌드로 갱신(Gatekeeper 통과, 실행).
- Homebrew 7은 외부 탭 Cask를 "신뢰"해야 읽는다(K45): 임시 설정 폴더에서 `brew trust` 후 `brew info`·`brew fetch`(체크섬)·`brew audit --online` 통과. 설치 안내 4곳에 `brew trust` 단계 추가·푸시.
- 남음: 설정 화면에서 가상 기기 항목이 사라진 것과 Finder 쓰기 확인 창 문구는 실제 화면에서 보지 않았다(문자열·코드·테스트로 확인).
