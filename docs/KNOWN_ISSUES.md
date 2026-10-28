# 알려진 문제 · 제약

## K1. 실제 Android 기기로 검증하지 않음 (가장 중요)
2단계 구현 시점에 Mac에 Android 기기가 연결돼 있지 않았다. 실기기 MTP 세션 열기, 저장소·폴더 조회, 잠금 처리, 충돌 감지는 **Mock과 이 Mac의 libusb/IOKit 동작으로만 검증**됐다. 특히 아래는 실기기에서 확인이 필요하다.
- 샌드박스(`device.usb`) 안에서 libmtp가 인터페이스를 claim하고 세션을 여는지
- macOS `ptpcamerad`가 Android MTP 인터페이스를 선점하는지, 그때 IORegistry에 `UsbExclusiveOwner`가 나타나는지
- 잠금 상태에서 저장소 0개 → 잠금 해제 후 같은 세션에서 저장소가 나타나는지 (기종·Android 버전별 차이 가능)
- IOKit 인터페이스 이름 키(`kUSBString` / 레지스트리 이름)가 “MTP”로 읽히는지

## K2. 링커 경고: 정적 라이브러리가 macOS 27용
Homebrew 병이 macOS 27에서 빌드돼 배포 대상 26.0과 `ld: warning: object file ... was built for newer 'macOS' version (27.0)` 경고가 난다. macOS 26에서 실행 보장을 위해 후속 단계에서 libusb/libmtp를 `MACOSX_DEPLOYMENT_TARGET=26.0`으로 직접 빌드(스크립트화)해야 한다.

## K3. LGPL 정적 링크
libmtp·libusb는 LGPL-2.1. 개발용 정적 링크는 문제없지만 배포 시 동적 링크 + 앱 번들 포함, 또는 재링크용 오브젝트 제공이 필요하다. 라이선스 고지도 추가해야 한다.

## K4. Homebrew 경로 고정
빌드 설정 `PB_HOMEBREW_PREFIX=/opt/homebrew`. Intel Mac(`/usr/local`)이나 다른 위치에서는 값을 바꿔야 한다. `scripts/bootstrap.sh`가 의존성을 확인한다.

## K5. `~/Documents` 아래 DerivedData는 서명 실패
iCloud/Finder 확장 속성 때문에 `codesign`이 “resource fork, Finder information, or similar detritus not allowed”로 실패한다. 기본 DerivedData(`~/Library/Developer/Xcode/DerivedData`)를 사용한다.

## K6. 잠금 판정의 모호성
libmtp `LIBMTP_Get_Storage`는 “저장소 0개”와 “GetStorageIDs 실패”를 같은 -1(오류 스택 없음)로 반환한다. 현재는 둘 다 잠금 상태로 간주하고 폴링한다. USB가 붙어 있는데 기기 MTP 서버가 멈춘 경우 계속 “잠금 해제” 안내가 보일 수 있다 (다시 시도로 세션 재생성 가능).

## K7. AppKit 기본 메뉴는 재실행 후 언어 반영
앱 화면·PhoneBridge 메뉴(이동, 보기 항목)는 즉시 바뀌지만, 편집/윈도우/앱 메뉴의 시스템 항목은 `AppleLanguages`를 따르므로 다음 실행부터 적용된다 (설정 화면에 안내). SwiftUI `Commands`의 즉시 갱신은 실제 앱에서 눈으로 확인하지 못했다.

## K8. UI 시각 검증 범위
실제 창 스크린샷은 화면 기록 권한이 필요해 찍지 않았다. 상태 화면(파일 전송 안내·충돌·잠금·빈 화면)은 `ImageRenderer`로 ko/en 렌더링해 확인했지만, `Table`/`NavigationSplitView`/스피너 같은 AppKit 기반 컨트롤은 오프스크린 렌더링되지 않아 실제 앱에서 확인이 필요하다.

## K9. 기능 범위 (의도된 미구현)
대용량 폴더 페이지네이션, Finder(FSKit) 통합, 여러 창은 아직 없다. (파일 전송·관리는 3단계에서 구현됨 — K13 이후 참고)

## K10. 대용량 폴더
`LIBMTP_Get_Files_And_Folders`는 폴더 전체 메타데이터를 한 번에 가져온다. 수천 개 파일이 있는 폴더(예: DCIM/Camera)는 첫 표시까지 수 초 걸릴 수 있다. 진행 표시는 있지만 취소·점진 표시가 없다.

## K11. 시리얼이 없는 기기
USB 시리얼이 없으면 논리 ID가 포트 위치(`locationID`) 기반이라, 다른 포트에 다시 꽂으면 새 기기로 취급된다.

## K12. 환경 메모
- `xcodebuild` 실행 시 “CoreSimulator is out of date” 경고가 출력되지만 macOS 빌드·테스트에는 영향 없음.
- 개발 인증서가 없어 ad-hoc 서명만 사용. 공증·배포 불가.

## K13. 파일 전송·편집은 실기기에서 검증하지 않음 (3단계, 가장 중요)
`LIBMTP_Get_File_To_File_Descriptor`, `LIBMTP_Send_File_From_File_Descriptor`, `Create_Folder`, `Set_File_Name`, `Delete_Object`, `Move_Object`, `Copy_Object`, `Get_Thumbnail`, capability 감지(`Check_Capability`, `Is_Property_Supported`)는 **컴파일·링크만 확인**됐다. 전송 로직은 Mock 기기(메모리)와 Mock MTP 백엔드(실제 fd 경유)로만 검증됐다. TEST_PLAN 3장(T1–T14)을 실기기에서 수행해야 한다.

## K14. 취소 후 MTP 세션 상태
libmtp는 진행률 콜백이 0이 아닌 값을 반환하면 전송을 중단한다. 일부 기기는 중단된 트랜잭션 뒤 세션이 불안정해질 수 있다(이후 명령 실패). 이 경우 스테이징 정리가 실패해 작업에 "정리하지 못한 임시 항목"이 표시되고, 재연결이 필요할 수 있다.

## K15. 긴 전송 중 같은 기기 탐색 대기
MTP 세션은 한 번에 한 트랜잭션만 처리한다. 수 GB 전송 중에는 같은 기기의 폴더 열기·검색·썸네일이 전송이 끝날 때까지 기다린다.

## K16. 검증 범위
완료 검증은 크기 비교다(D15). 내용 손상(같은 크기의 잘못된 바이트)은 감지하지 못한다.

## K17. 수정 날짜·파일 시스템 제약
- 업로드 시 수정 날짜를 MTP로 전달하지만 Android가 무시하고 업로드 시각으로 기록할 수 있다.
- SD 카드(FAT32)는 4 GB 초과 파일을 받을 수 없다. 사전 검사는 없고 기기 오류로 실패한다.
- 대소문자만 다른 이름은 충돌로 취급한다(Android 공유 저장소 규칙에 맞춘 안전한 쪽).

## K18. 드래그 앤 드롭 범위
- Android 항목을 Finder로 직접 끌어 놓는 것은 지원하지 않는다(다운로드 메뉴 또는 Mac 패널 사용).
- Mac 패널에서 끄는 항목은 앱 내부 페이로드라 Finder에는 놓을 수 없다.
- 서로 다른 Android 기기 사이의 복사·이동은 지원하지 않는다(안내 표시).
- Mac 패널은 탐색·업로드·복사/잘라내기·Finder에서 보기만 제공한다(Mac 쪽 이름 변경·삭제는 Finder 사용).

## K19. 검색
"하위 폴더 포함" 검색은 MTP로 폴더를 하나씩 열어 찾기 때문에 큰 저장소에서는 느리다. 결과는 2,000개로 제한된다.

## K20. 미리보기
1 GB 초과 파일과 Quick Look 미지원 형식(HWP, APK, ZIP 등)은 미리보기가 비활성이다. 동영상도 전체를 내려받은 뒤 재생된다. 캐시는 앱 실행·종료 시 삭제된다.

## K21. UI 상호작용 미확인
목록 행 드래그(`TableRow.draggable`), 폴더 행 드롭, 붙여넣기 명령(⌘V)과 Finder 클립보드 연동, Quick Look 패널, 2분할(HSplitView), 메뉴 단축키는 빌드만 확인됐고 실제 창에서 조작해 보지 않았다(K8과 같은 이유). 오프스크린 렌더링으로 확인한 것은 상태 화면과 충돌 대화상자뿐이다.

## K22. Finder(FSKit) 통합은 실제 Finder에서 동작을 확인하지 못함 (4단계 차단)
- 업데이트(16:25): 팀 서명 빌드는 성공(V7-2).
- **업데이트(21:31): 해결.** App Group 포털 등록 후 가상 기기 볼륨으로 실제 FSKit 마운트와 F1–F7·F10 실측 통과(V7-7). Finder 표시와 설정 화면의 마운트/해제 버튼은 사용자가 확인. 남은 미검증: 실제 Android 기기(F8·F9 포함), 동영상 미리보기.
- Xcode가 FSKit 권한(`com.apple.developer.fskit.fsmodule`)이 있는 확장을 **프로비저닝 프로필 없이 서명하지 않는다**. 이 Mac에는 Apple Development 인증서·macOS 개발 프로필이 없다.
- 수동 ad-hoc 서명 사본은 pluginkit에는 등록되지만 FSKit이 "disabled"로 보고 마운트를 거부했다(`mount -F` exit 69, `mountSingleVolume` EPERM). 확장 코드(로드·목록·읽기)는 한 번도 실행되지 않았다.
- ad-hoc 서명 앱은 팀 접두어 없는 App Group 컨테이너에 소켓을 만들 수 없다(EPERM). 팀 서명이 필요하다.
- 해결: 사용자가 Apple Development 인증서를 만든 뒤 `scripts/build-team-signed.sh <TEAM_ID>` 실행 → 시스템 설정에서 확장 켜기. 번들 ID `com.phonebridge.*`를 팀에 등록할 수 없으면 세 타깃의 번들 ID 접두어를 바꿔야 한다.

## K23. macOS 26에서는 앱에서 마운트 불가
`FSClient.mountSingleVolume`은 macOS 27부터다. macOS 26에서는 설정 화면이 수동 마운트 안내만 보여 준다(`mount -F -t phonebridge <url> <경로>`).

## K24. 앱이 실행 중이어야 함
MTP 세션은 앱의 DeviceBroker에만 있으므로 앱을 종료하면 Finder 볼륨 요청이 실패한다. 종료 시 앱이 볼륨을 먼저 해제한다. 앱 없이 동작하려면 브로커를 로그인 항목(launchd 에이전트)으로 분리해야 한다(후속 과제).

## K25. Finder 쓰기 미지원
Finder 볼륨은 읽기 전용이다(D28, D30). 쓰기 설계(D26)는 확정했지만 구현하지 않았다.

## K26. 디렉터리 변경 반영 지연
확장은 디렉터리 목록을 3초간 캐시한다. 앱이나 기기에서 바뀐 내용이 Finder에 최대 몇 초 늦게 보일 수 있다. FSKit 변경 알림 연동은 후속 과제.

## K27. FSKit 볼륨의 Spotlight 메타데이터 없음
Finder 볼륨에서 `mdls`/Spotlight 메타데이터를 얻을 수 없다. Quick Look 미리보기는 동작한다(실측).

## K28. 팀 빌드 시 Xcode 캐시 프로필
포털에서 App ID·App Group을 바꿔도 Xcode가 `~/Library/Developer/Xcode/UserData/Provisioning Profiles`의 오래된 프로필을 재사용할 수 있다. 이 경우 해당 프로필을 옮기고 다시 빌드하면 새 프로필을 받는다(V7-7).

## K29. 샌드박스 앱이 앱 마운트 볼륨을 해제하지 못함 (F8 실패) → D32로 해결, 실기기 케이블 분리로 확인(2026-10-22 22:05)
`FSClient.mountSingleVolume` 마운트는 root(fskitd) 소유이고, 해제에 필요한 `system.volume.network.unmount` 권한 요청을 App Sandbox가 거부한다. 분리·자동 해제·설정의 해제 버튼 모두 실패하며, 남은 볼륨은 `ESTALE`로 안전하게 실패한다. 우회: Finder에서 꺼내기(⏏) 또는 `diskutil unmount`. 근본 해결은 사용자 결정 대기(V7-8).

## K30. FSKit 마운트 지점 이름은 ASCII만 가능
한글·en dash가 들어간 볼륨 이름은 마운트 시 `EINVAL`. D31로 해결(경로는 ASCII, 표시 이름은 한글). AppleScript `name of disk`와 터미널 경로는 ASCII 이름을 쓴다.

## K31. 해제 헬퍼의 제약
- 관리자 아닌 계정: `system.volume.network.unmount` 규칙이 세션 소유자의 admin 그룹 소속을 요구하므로 해제가 거부될 수 있다(미검증). 이 경우 볼륨은 `ESTALE`로 안전하게 실패하고 Finder에서 꺼내야 한다.
- Mac App Store 배포 불가(샌드박스 밖 실행 파일 포함).
- 개발 빌드와 설치본은 파일 시스템 유형(`phonebridgedev`/`phonebridge`)으로 서로의 볼륨을 구분한다. 이 구분이 들어가기 전 빌드의 볼륨은 유형이 `phonebridge`로 표시된다.

## K32. Finder 쓰기 — W2 시점 한계
- 쓰기는 가상 기기 볼륨에서만 열려 있다(실기기는 W5 전까지 차단, D35). 설정 › Finder의 스위치로 켜고 끈다(D37).
- (W3에서 해결) 실패·중단된 쓰기 버퍼는 설정 › Finder의 복구 목록으로, 기기에 남은 숨김 객체는 다음 세션 정리로 처리(D36).
- 앱이 지연 삭제 30초 안에 종료·충돌하면 다음 연결 때 그 파일이 되살아난다(원본 보호 우선, D36).
- 가상 기기는 앱 재시작마다 초기화되므로 기기 쪽 정리는 실제 앱에서 재현하지 못하고 단위 테스트로만 확인했다. 실기기 확인은 W5.
- 태그·격리 속성 등 확장 속성은 마운트 중에만 유지된다(기기에 저장하지 않음).
- 큰 업로드 중 탐색 대기: 조각 업로드(D40)로 1 GiB 업로드 중 최대 약 1–2초(이전 27.5초, V12). 편집 확장이 없는 기기는 여전히 업로드가 끝날 때까지 기다린다. 큰 다운로드는 D52로 조각 읽기(부분 읽기 미지원 기기는 여전히 한 덩어리). 실기기 측정은 아직.
- 실기기 쓰기는 설정 › Finder의 별도 항목으로 켠다(D54, 기본 꺼짐). 검증된 기종은 1종.
- 쓰기 허용을 바꾸면 앱이 마운트한 볼륨은 자동으로 다시 마운트된다(D37). 터미널 `mount -F`로 붙인 볼륨은 직접 다시 마운트해야 한다. 열린 파일이 있는 볼륨은 다시 마운트되지 않는다.
- 분리·앱 강제 종료 시 남는 숨김 객체는 다음 세션에 정리된다(D36). 일지에 적히기 전 단계에서 앱이 죽는 경우는 없다(먼저 적고 만든다).
- (해결, D55) 교체·스테이징 안전 순서는 `SafeDeviceWrite` 한 곳에 있다.

## K33. 4차 시점 한계
- 운영체제가 만드는 문구(시스템 메뉴 항목, 파일 패널 버튼, 훑어보기 창, 설정 창 제목)는 앱을 다시 실행해야 언어가 바뀐다(`docs/LOCALIZATION.md`).
- (해결 중, D45) Android → Finder 직접 끌어다 놓기는 구현됐다. 실제 Finder에 놓는 동작은 K34 참고.
- 가상 기기의 저장소 이름("내부 저장공간")은 기기 데이터처럼 다뤄 번역하지 않는다.
- 정보 패널 너비는 고정(240pt)이다(D42, 자체 구현).
- 새 화면의 실기기 확인과 메뉴·VoiceOver 실제 조작 확인이 남아 있다(V13).

## K34. Android → Finder 드래그(D45) 한계
- 실제 Finder 놓기는 자동화할 수 없다(화면 제어 권한 없음). 자동 테스트는 놓기가 읽는 것과 같은 `NSItemProvider`에서 파일을 꺼내 확인한다. SwiftUI가 이 항목을 Finder용 파일 프로미스로 넘기는지는 실제 드래그로 확인해야 한다(TEST_PLAN 6).
- (해결, D53) 한 번에 끌어 놓은 항목은 전송 작업 하나로 묶인다. 단 Finder가 항목을 하나씩 순서대로 요청하면 묶이지 않는다(미확인).
- 내려받기가 끝날 때까지 Finder가 기다린다. 큰 파일은 놓은 뒤 파일이 나타나기까지 시간이 걸리고, 진행 상황은 PhoneBridge 전송 목록에 보인다(Finder 쪽 진행 표시는 시스템에 달림).
- 전송 대기열이 직렬이므로 다른 큰 전송이 진행 중이면 그 뒤에 내려받는다.
- 비공개 사본(`tmp/PhoneBridgeDrag`)이 놓은 위치로 복사되므로 잠시 두 배의 공간을 쓴다. 30분 뒤(또는 다음 실행 때) 지운다.
- 폴더를 Finder에 놓으면 폴더 전체를 먼저 내려받은 뒤 한 번에 나타난다.
- 실기기에서는 아직 확인하지 않았다(가상 기기 먼저). 절차·검사 스크립트는 TEST_PLAN 6-1, `scripts/drag-check.sh`.

## K35. 배포 장애물 (2026-10-23, RELEASE_READINESS — 인증서·공증은 V19에서 해결)
- (해결, V19) Developer ID 인증서 발급, 앱·DMG 공증 Accepted, Gatekeeper 통과.
- (해결, V19) FSKit 권한은 Developer ID 프로필에 포함됨.
- (해결, V20) 배포 저장소 garam918/phonebridge, 1.0.0 공개.
- Mac App Store 불가(샌드박스 밖 해제 헬퍼, D32).
- (해결, D69) PhoneBridge 자체 라이선스는 MIT. LGPL 준수 방식 법무 검토는 아직.

## K36. Address Sanitizer와 Swift Testing
`#expect(optionalUInt64 == 리터럴)` 형태가 ASan에서 Swift Testing의 AnyHashable 변환 중 stack-buffer-overflow로 보고된다(앱 코드가 아니라 테스트 매크로 변환 코드). 테스트는 값을 먼저 `#require`로 풀어 비교하도록 바꿨다. 새 테스트도 같은 방식을 쓴다.

## K37. 검증 환경의 한계
- 최소 버전은 15.0으로 바뀜(D58, K41). M1 등 다른 Apple Silicon 칩도 미검증.
- 저장소가 iCloud Drive(`~/Documents`) 안에 있어 빌드 산출물에 Finder 메타데이터가 붙을 수 있다. 릴리스는 `~/Library/Developer/PhoneBridge/release`에서 만든다.
- 모의 다운로드 처리 속도는 실행마다 편차가 크다(188–2,832 MiB/s). 하한만 의미 있게 보고한다.

## K38. 재설치 후 Finder 확장 꺼짐 (한 번 발생, 이후 업데이트 두 번은 유지)
빌드 202610231128 설치 직후 가상 기기 Finder 마운트가 RunningBoard "Client not authorized"(ExtensionKit 오류 2)로 실패했다. 앱을 다시 실행해도 같았다. 확장이 꺼진 상태로 보이며, 켜는 것은 시스템 설정의 사용자 조작이다(앱·스크립트로 바꾸지 않음). 사용자가 다시 켠 뒤 마운트가 되는지, 그리고 업데이트 설치마다 꺼지는지 확인해야 한다. 꺼진다면 업데이트 안내에 "확장 다시 켜기"를 넣어야 한다.
- 2026-10-23 12:32: 사용자가 시스템 설정에서 확장을 다시 켠 뒤 즉시(1초 안) 가상 기기 저장소 2개가 마운트됐다(V16). 남은 확인: 다음 업데이트 설치 후에도 켜져 있는지.
- 2026-10-23 13:28·13:30: 업데이트 설치(202610231328, 202610231330) 두 번 모두 확장이 켜진 채 유지되고 바로 마운트됐다. 처음 꺼진 원인(동적 라이브러리를 넣은 첫 빌드였음)은 확인하지 못했다. 앱은 꺼져 있으면 설정 › Finder에 이유와 "시스템 설정 열기"를 보여 준다.

## K39. Thread Sanitizer 오탐: 실행기가 DispatchSerialQueue인 액터
`MTPDeviceSession`은 libmtp 호출을 전용 직렬 큐에서 돌리려고 그 큐를 액터 실행기로 쓴다. TSan은 이 경우 같은 액터의 연속된 메서드(open → close)를 경쟁으로 보고한다. `scripts/tsan-executor-probe.swift`가 앱과 무관한 최소 액터로 같은 보고를 재현하고, 기본 실행기 액터는 보고하지 않는다. 직렬성은 모의 백엔드의 동시 호출 수 검사(`mtpCallsAreSerializedAndNeverOnMainThread`)로 따로 확인한다. TSan 실행 시 `TEST_RUNNER_TSAN_OPTIONS=halt_on_error=0`으로 끝까지 돌리고 이 패턴은 제외해 읽는다.

## K40. 한글 이름 정규화의 범위 (D51)
기기로 보내는 새 이름만 NFC로 바꾼다. 다른 프로그램이 기기에 NFD로 저장한 기존 이름은 그대로 보이고(분리된 자모), Mac으로 내려받을 때도 기기 이름 그대로 쓴다.

## K41. macOS 15·26 실제 실행 미검증 (D58)
최소 버전 15로 빌드·검사만 했다. 이 Mac은 macOS 27이고 가상 머신 도구가 없어 15·26에서 실행해 보지 못했다. 컴파일러의 사용 가능 버전 검사는 통과했지만, SwiftUI 동작 차이(표, 검색, 끌어 놓기)는 실제 실행으로만 알 수 있다. macOS 가상 머신은 USB를 연결할 수 없으므로 실기기 확인에는 해당 버전의 실제 Mac이 필요하다. `DISTRIBUTION.md`의 설치 확인 매트릭스.

## K42. 터미널 설치·제거의 한계
- `install.sh --uninstall --zap`과 `brew uninstall --zap`이 앱 컨테이너를 휴지통으로 옮기지 못할 수 있다(macOS가 다른 앱의 컨테이너 접근을 막음). 실패하면 Finder로 옮기라고 안내한다.
- 관리자 계정이 아니면 `/Applications`에 쓸 수 없어 `--user`(~/Applications)를 써야 한다. 스크립트는 스스로 sudo를 쓰지 않는다.
- (해결) 주소는 garam918/phonebridge.

## K43. 공증 빌드 내보내기의 타임스탬프 오류
Xcode 내보내기(Developer ID 서명)가 "timestamps differ by N seconds - check your system clock"으로 실패할 수 있다. 시계가 정확해도 Apple 타임스탬프 서버가 늦게 응답하면 생긴다(V20: 두 번 실패 후 성공). `sntp time.apple.com`으로 시계를 확인하고, 정상이면 잠시 뒤 `release.sh`를 다시 실행한다.

## K44. 다른 PhoneBridge 사본이 Finder 확장을 가로챔 (2026-10-24, V22)
- 증상: 확장을 켜도 마운트가 `com.apple.extensionKit.errorDomain 2`로 실패. 시스템 로그(fskit_agent)에 `/Applications`가 아닌 사본(릴리스 아카이브, Xcode 빌드, 열어 본 DMG)의 확장 경로가 보인다.
- 원인: LaunchServices에 PhoneBridge 사본이 여러 개 등록되면 ExtensionKit이 그중 실행할 수 없는 사본(개발 서명·아카이브 중간 산출물)의 확장을 고른다. 이 Mac에는 개발·테스트·릴리스 과정에서 20개 넘게 쌓여 있었다.
- 해결(이 Mac에서 확인): `/Applications` 밖의 PhoneBridge 등록만 지운다(파일은 그대로). 앱을 한 번 실행하면 `/Applications` 사본의 확장이 다시 등록된다.
  `lsregister -dump | grep 'path:.*/PhoneBridge.app'`로 찾고 각 경로에 `lsregister -u <경로>` (`lsregister`: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`)
- 개발 중에는 빌드할 때마다 다시 생길 수 있다(Xcode DerivedData의 Debug 빌드는 지워도 곧 다시 등록됨).
- (D68) `install.sh`는 설치·검사 때 연 DMG 사본과 휴지통으로 옮긴 이전 앱의 등록을 지운다. 사용자가 Finder에서 직접 연 DMG나 다른 폴더에 둔 사본은 여전히 원인이 될 수 있다.

## K45. Homebrew 7은 외부 탭을 "신뢰"해야 설치한다
Homebrew 7부터 공식이 아닌 탭의 Cask는 `brew trust --cask garam918/phonebridge/phonebridge`(또는 `brew trust garam918/phonebridge`)로 한 번 허용해야 읽는다. 허용하지 않으면 "Refusing to load cask … from untrusted tap"으로 설치가 멈춘다(2026-10-26 확인). 설치 안내(README, INSTALL, 탭 README, 릴리스 설명)에 이 단계를 넣었다. 이 Mac의 신뢰 목록은 바꾸지 않고 임시 설정 폴더(`XDG_CONFIG_HOME`)로만 확인했다.

## K46. 연결 시 자동 실행 — 확인 범위 (D73)
- 실제 휴대전화를 꽂아서 열리는지는 아직 확인하지 않았다(V25는 등록·런처 실행·앱 열기 단계까지).
- 같은 휴대전화를 뽑았다가 20초 안에 다시 꽂으면 USB 모드 변경으로 보고 다시 열지 않는다.
- 로그인할 때 이미 꽂혀 있던 휴대전화로는 열지 않는다(꽂는 순간에만 반응).
- 이 Mac처럼 Samsung DEVGURU 드라이버가 켜져 있는 Mac에서는 앱이 열려도 휴대전화에 접근하지 못한다(드라이버 확장을 꺼야 함).
- 앱을 지우지 않고 다른 위치로 옮기면 로그인 항목이 예전 위치를 가리킬 수 있다. 설정에서 한 번 껐다 켜면 다시 등록된다.

## K47. iPhone·iPad — 실기기 미검증과 제한 (D75)
- 실제 iPhone·iPad로는 아직 한 번도 확인하지 않았다(V26은 가짜 백엔드 테스트와 Image Capture 시작까지). 샌드박스 앱에서 기기 발견·세션 열기·읽기·삭제가 실제로 되는지는 기기를 꽂아 봐야 안다.
- 사진·동영상만 보인다. 앱 문서·파일 앱 내용은 Apple 비공개 프로토콜이라 다루지 않는다. 기기에 파일을 넣거나 이름을 바꿀 수 없다.
- iCloud 사진의 "iPhone 저장 공간 최적화"가 켜져 있으면 원본이 기기에 없는 항목은 목록에 없거나 가져오기가 실패할 수 있다.
- Live Photo는 사진(HEIC/JPG)과 동영상(MOV) 두 파일로, 편집한 사진은 `IMG_E….` 같은 별도 파일로 보일 수 있다(Image Capture가 보여 주는 그대로).
- 사진이 많으면 처음 목록을 읽는 데 시간이 걸린다("사진 목록을 읽는 중"). 연결 중 새로 찍은 사진은 새로 고침(⌘R)으로 보인다.
- 사진 앱·이미지 캡처가 같은 기기를 쓰고 있으면 세션이 열리지 않을 수 있다. 사진 앱의 "이 기기를 연결하면 사진 열기"가 켜져 있으면 사진 앱도 함께 열린다.
- iOS가 삭제를 거부하면(기기 설정·제한) 오류로 표시된다. 삭제한 항목은 기기의 "최근 삭제된 항목"으로 가는지 iOS 버전에 따라 다를 수 있다(미확인).
- Finder 마운트는 Android 기기만 지원한다.

## K48. (해결, D77) 휴대전화 파일을 Mac 창이나 폴더 위로 끌어다 놓으면 앱이 멈춤
- 1.0.0 모든 빌드(배포판 포함)에 있음. 휴대전화 → Mac 창, 휴대전화 창 빈 곳, 휴대전화 창의 폴더 위(목록·아이콘) 모두 해당. 다음 빌드에서 수정. 그전까지는 우클릭 › '다운로드', 툴바의 다운로드 버튼, ⌘C → Mac 창에서 ⌘V를 쓰면 멈추지 않는다.
- 확인 범위: 가상 기기로 합성 마우스 드래그(이 Mac). 실제 휴대전화로 같은 드래그는 아직 확인하지 않았다. 휴대전화 창 빈 곳에 놓는 경우는 멈추지 않는 것까지만 확인(드롭 처리 진입 기록 없음). 그전까지 휴대전화 안에서 옮기려면 잘라내기(⌘X) → 붙여넣기(⌘V).

## K49. 멈춤·무한 대기 위험 점검 결과 (2026-10-28, 3·4 처리)
점검: 동기 대기(세마포어·`sync`·잠금·`runModal`), 메인 스레드 파일 작업, 끝나지 않을 수 있는 대기, 가상 기기 실측. 아래는 확인된 멈춤이 아니라 위험이다.
1. **Finder 연동 확장 → 앱 요청에 시간 제한 없음**: 앱이 응답하지 않으면(예: K48) Finder 볼륨을 여는 Finder 창도 함께 기다린다. 큰 파일 읽기는 정상적으로도 오래 걸려 일괄 제한은 곤란.
2. **iPhone·iPad(D75, 미배포·실기기 미검증)**: ① Image Capture 요청(읽기·섬네일·삭제)의 완료 콜백이 오지 않으면 전송이 끝나지 않고 취소도 듣지 않는다(종료 시 시간 제한으로만 정리). ② 목록·항목 조회마다 카탈로그 전체를 메인 스레드에서 훑는다 — 사진이 수만 장이면 여러 장을 가져올 때 화면이 끊길 수 있다.
3. (해결) **Finder 쓰기 복구 파일 저장**(설정 › Finder): 복사를 메인 스레드에서 해 외장 디스크로 저장하면 큰 파일 동안 응답 없음 → 복사를 백그라운드로 옮기고 복사 중에는 저장·버리기 버튼을 막고 진행 표시(`FinderWriteRecovery.save`가 async). 기존 테스트 3개 통과. 큰 파일·외장 디스크로는 실측하지 않았다.
4. (문제 아님) **겹친 시트**: macOS 27에서 작은 시험 앱으로 확인 — 시트가 열린 동안 다른 시트를 요청하면, 수정자 체인에서 앞에 선언된 시트는 열린 시트를 바로 대신하고, 뒤에 선언된 시트는 열린 시트가 닫히면 이어서 나타난다. PhoneBridge의 충돌 질문은 '연결 문제 해결'·시작 안내보다 앞(바로 대신), 이름 입력 창보다 뒤(닫히면 표시)라 전송이 멈춘 채 남지 않는다. macOS 15에서는 확인하지 않았다.
문제없음 확인: Finder IPC 서버의 세마포어(전용 스레드), 종료(시간 제한), 진단 정보 내보내기(로그 수집 백그라운드), 전송 파일 쓰기·`fsync`(메인 밖), MTP 호출(장치별 직렬 큐).
