# 테스트 계획

## 1. 자동 테스트 (Swift Testing, 앱 호스트 · 샌드박스 내 실행)

실행:

```bash
xcodebuild -project PhoneBridge.xcodeproj -scheme PhoneBridge -destination 'platform=macOS,arch=arm64' test
```

> DerivedData를 `~/Documents` 아래에 두면 Finder 확장 속성 때문에 코드 서명이 실패한다. 기본 DerivedData 위치를 사용한다.

| 스위트 | 종류 | 검증 내용 |
|---|---|---|
| DeviceBroker (mock USB + mock MTP) | Mock | 연결·저장소 로드, 무관한 장치 무시, 충전 전용 → 파일 전송 전환, PTP 모드, 인터페이스 대기, busy(소유 프로세스 표시·libmtp 미호출)·재시도, 잠금 → 해제, 열기 실패 자동 1회 재시도, 해제 → reconnecting → 제거·세션 종료, 유예 내 재연결(새 세대), 인터페이스 변동 무시, iPhone 미지원, **MTP 호출 직렬화 & 메인 스레드 0회**, 끊긴 세션 핸들 안전 실패, 종료 시 세션 정리, 목록 오류의 Swift 오류 변환 |
| AppModel connection recovery | Mock | 연결 기기 자동 선택·탐색, 데모 → 실제 기기 전환, **탐색 중 해제 시 오류 없이 UI 복구**, 재연결 시 새 세션 루트, 실패 시 상태 화면·알림 |
| BrowserViewModel | Mock | 루트 정렬(폴더 우선), 하위 이동/뒤로/앞으로/상위/경로 이동, 선택·정보, 정렬 변경, 늦은 응답 무시, 없는 폴더 오류, 초기화 |
| MockDeviceFileSystem / FileSorter | Mock | 저장소 2개, 중첩 폴더, 빈 폴더, 잘못된 ID, 저장소별 ID 분리, 자연 정렬(한글 포함), 크기·날짜·종류 정렬, Table 정렬 매핑 |
| USBDeviceClassifier / MTPErrorMapper / ConnectionState | 순수 로직 | 분류 규칙, 재열거 시 논리 ID 유지, libusb 버스 번호, 소유자 문자열 파싱, C 상태 코드 ↔ Swift 오류, USB/MTP 상태 분리 |
| Localization (ko / en) | 순수 로직 | 기본 한국어, 영어 전환·저장·재실행 시 유지, 관찰자 알림(재실행 없는 갱신), 인자 포맷, 모든 상태·오류 문구, 동적 키, 컴파일된 ko/en 키 집합 일치 |
| View rendering (offscreen) | Mock | 파일 전송 안내·충돌 안내·잠금 안내·빈 화면·전송 충돌 대화상자를 ko/en으로 렌더링, PNG 출력 (`~/Library/Containers/com.phonebridge.PhoneBridge/Data/tmp/PhoneBridgeRenders`) |
| TransferManager (mock device, real local files) | Mock 기기 + 실제 Mac 파일 | 작은 파일(검증·수정일), 폴더(빈 폴더 포함), 한글/영문/이모지 파일명 왕복, 중첩 폴더 업로드(.DS_Store 제외), 200개 파일 왕복, **4.5 GiB 업로드(64비트, 스트리밍)**, 300 MB 다운로드, 반복 다운로드(둘 다 유지 2·3), 대치/건너뛰기, 반복 업로드 후 대치(백업 정리), 폴더 병합 + 모두 적용, rename 미지원 시 대치 금지, 다운로드·업로드 취소(스테이징 정리), USB 분리(실패·재시도 가능), 중간 실패 시 부분 객체 정리, Mac 공간 부족·기기 공간 부족(사전 차단), 전송 중 기기 공간 부족, Mac 쓰기 권한 없음, Mac 읽기 권한 없음, 읽기 전용 저장소, 업로드·다운로드 검증 실패, 대치 실패 시 원본 유지, 쓰기 미지원 기기, 기기 내 복사·이동(직접), 같은 폴더 복사(번호), 자기 자신으로 이동 거부, Mac 경유 복사·이동, 트리 삭제, 기기→Mac 이동, 대기열 순서, 재시도 |
| Transfers via DeviceBroker session | Mock MTP 백엔드 | 실제 체인(Broker → MTPDeviceFileSystem → 세션 → fd)으로 다운로드·업로드(이모지 이름), 전송 중 직렬화·메인 스레드 0회, **전송 중 USB 분리 → 실패·스테이징 정리 → 재연결(새 세대) 후 재시도 성공(경로 재해석)** |
| FileNameRules | 순수 로직 | 이름 검증(금지 문자, 길이, 공백), Finder식 고유 이름, 업로드용 이름 정리 |
| Finder IPC protocol | 순수 로직 | 볼륨 URL 왕복·잘못된 URL 거부·프로세스 간 안정적 UUID, 요청/응답 JSON 왕복(4 GB 초과 오프셋, 이모지 이름) |
| MTP file repository | Mock MTP 백엔드 / Mock 기기 | 브로커 세션으로 목록·설명·stat, GetPartialObject 경로(캐시 없음), 미지원 기기 캐시 경로(한 번만 다운로드, 스테이징 잔여 없음, 무효화 후 재다운로드), ESTALE·ENXIO·ENOENT, 2.5 GiB 오프셋 읽기·파일 끝 짧은 읽기, 데모 제외 |
| Finder IPC over a real Unix socket | **실제 소켓**(같은 프로세스) | 탐색·읽기, POSIX 오류 전달, 서버 재시작 후 클라이언트 재연결, 허용되지 않은 코드 서명 거부, **앱 탐색과 Finder 읽기 동시 사용 시 세션 1개·직렬화·메인 스레드 0회** |
| Finder integration manager | 가짜 마운터 | 연결 시 자동 마운트, 분리 시 해제, 재연결 후 새 세대로 재마운트, 수동 마운트/해제 10회 반복, 마운트 실패 표시 후 재시도, 비활성화 시 전체 해제·서버 중지, App Group 없음 표시 |
| Finder writes (coordinator + repository) — W1 | Mock 기기 + **장애 주입** | 새 파일: 스테이징→크기 검증→최종 이름, 잔여물 없음. 교체: 백업 경유. 예상 밖 기존 파일·폴더 → EEXIST. **업로드 실패·부분 업로드·크기 불일치·최종 이름 변경 실패·업로드 중 분리 → 원본 내용·이름 유지**. 버퍼 이름 경로 탈출·크기 불일치·공간 부족·잘못된 이름은 기기 호출 전 거부. rename 미지원 기기는 새 파일만. **지연 삭제(D33)**: 즉시 숨김·유예 후 삭제, Finder "대치" 순서에서 새 파일 커밋 직후 원본 삭제, 새 파일 실패 시 원본 복원, 해제 시 즉시 정리, 폴더 삭제 시 안쪽 대기 삭제 정리. rename·rename-over·실패 시 복원, 이동+이름 변경·MoveObject 없으면 EXDEV·실패 시 원위치. 요청 직렬 처리. 저장소 쓰기 허용 꺼짐→EROFS, 읽기 전용 저장소, 오래된 세대→ESTALE, 쓰기 요청은 응답 유실 후 재전송 안 함 |
| Device leftover journal — W3 | Mock 기기 + 장애 주입 | 이전 실행의 스테이징 삭제, 백업은 이름이 비면 복원·차 있으면 삭제, 같은 실행·세션은 건드리지 않음, 핸들이 바뀌면 경로로 찾기, 임시 이름 아닌 항목 무시, 분리 시 보류, Finder 커밋 실패로 남은 스테이징·지연 삭제 중단·교체 중 원본이 백업으로 남은 경우 다음 실행에 정리/복원, 정상 쓰기·앱 전송 후 일지 비어 있음 |
| Finder write recovery — W3 | 임시 폴더 + 실제 `flock` | 사용 중·실패·해제 후 남은 버퍼 구분, 관리 파일·빈 버퍼·`.DS_Store` 내용·고아 설명 파일 자동 정리, Mac에 저장(덮어쓰기)·버리기, 사용 중 버퍼는 버리기 불가 |
| Finder writes over IPC v2 — W1 | **실제 소켓** | 확장과 같은 순서(쓰기 가능 확인→새 폴더→삭제→커밋→이동→목록) 왕복 |
| Host environment | **이 Mac의 실제 스택** | libmtp 1.1.23 링크, 샌드박스 안 libusb 열거, 없는 장치 preflight/open의 Swift 오류, **IOKit 모니터가 실제 USB 장치 감지** |

정적 검사:

```bash
python3 scripts/check-localization.py
```

## 2. 실기기 수동 검증 체크리스트

준비: Android 기기, 데이터 전송 가능한 USB 케이블, Console.app 필터 `subsystem:com.phonebridge.PhoneBridge`.

| # | 시나리오 | 기대 결과 |
|---|---|---|
| M1 | 앱 실행 후 “충전 전용” 상태로 연결 | 사이드바에 기기 표시, 상태 “파일 전송 모드를 선택해 주세요”, USB 정상 / MTP 대기 |
| M2 | 기기에서 “파일 전송” 선택 | 수 초 내 “연결 중” → “연결됨”, 저장소(내부 저장공간 등) 표시, 탐색기 자동 열림 |
| M3 | 잠긴 상태로 파일 전송 모드 연결 | “기기 잠금을 해제해 주세요”, 잠금 해제·허용 후 자동 연결 |
| M4 | DCIM → Camera 등 여러 폴더 이동, 뒤로/앞으로/상위 | 목록·경로 막대·정보 패널 정상, 메인 스레드 멈춤 없음 |
| M5 | 탐색 중 케이블 분리 | 오류 대화상자 없이 “다시 연결 대기 중” → 8초 후 목록에서 사라지고 환영 화면 |
| M6 | 분리 후 8초 안에 재연결 | 같은 기기로 이어져 저장소 루트부터 탐색 |
| M7 | 이미지 캡처 앱을 연 채로 연결 | “다른 프로그램이 기기를 사용 중” + 소유 프로세스 이름, 앱 종료 후 “다시 시도”로 연결 |
| M8 | PTP(사진 전송) 모드 | “사진 전송(PTP) 모드로 연결됨” 안내 |
| M9 | SD 카드 있는 기기 | 저장소 2개 표시, 각각 탐색 가능 |
| M10 | 앱 종료(⌘Q) 중 연결 상태 | 로그에 “closed 1 session(s)”, 이후 다른 MTP 앱에서 바로 접근 가능 |
| M11 | 설정에서 English ↔ 한국어 | 재실행 없이 앱 화면 전환 (AppKit 기본 메뉴는 다음 실행부터) |

결과 기록 양식: 기기 모델 / Android 버전 / USB VID:PID / 시나리오 / 결과 / 로그 발췌.

## 3. 실기기 수동 검증 체크리스트 — 파일 관리 (3단계)

| # | 시나리오 | 기대 결과 |
|---|---|---|
| T1 | 사진 1장 다운로드 (⇧⌘D) | `~/Downloads`에 저장, 크기·수정일 일치, `.phonebridge-*` 파일 없음 |
| T2 | DCIM/Camera 폴더 다운로드 (수백 장) | 하단 막대에 전체 진행률·속도·남은 시간, 완료 후 개수 일치 |
| T3 | 4 GB 이상 동영상 업로드/다운로드 (내부 저장공간) | 완료, 크기 일치 (SD 카드 FAT32는 4 GB 제한으로 실패 예상 — 사유 표시 확인) |
| T4 | Finder에서 폴더(빈 하위 폴더 포함)를 Android 패널로 드래그 | 구조 그대로 업로드 |
| T5 | 같은 파일 다시 업로드 → 대치 / 둘 다 유지 / 건너뛰기 | 각각 단일 파일 교체, "이름 2", 변화 없음. 기기에 `.phonebridge-*` 잔여 없음 |
| T6 | 업로드 중 취소 | 기기에 부분 파일·스테이징 파일 없음, 이후 같은 세션으로 탐색 계속 가능한지 확인 |
| T7 | 다운로드 중 케이블 분리 | 작업 실패(사유 표시), Mac에 스테이징 파일 없음, 재연결 후 재시도 성공 |
| T8 | 새 폴더·이름 변경(한글/이모지)·삭제(폴더 포함) | 기기 파일 앱/갤러리에서도 반영 확인 |
| T9 | 기기 내 잘라내기→붙여넣기, 폴더 위로 드래그 | 이동 완료 (MoveObject 미지원 기기는 Mac 경유로 완료되는지) |
| T10 | 사진·동영상·PDF·DOCX 미리보기(Space) | Quick Look 표시, HWP는 메뉴 비활성 |
| T11 | 정보 패널 썸네일 | 이미지·동영상에서 MTP 썸네일 표시 |
| T12 | Mac 디스크 거의 가득 찬 상태에서 큰 폴더 다운로드 | 시작 전 "Mac의 저장 공간이 부족합니다" |
| T13 | 2분할 모드에서 Mac 폴더 선택 후 앱 재실행 | 같은 폴더 다시 열림(보안 범위 북마크) |
| T14 | 전송 중 앱 종료(⌘Q) | 스테이징 정리 후 종료, 세션 닫힘 로그 |

## 4. Finder(FSKit) 실제 검증 체크리스트 — 팀 서명 + 확장 활성화 후 수행

사전 조건: `scripts/build-team-signed.sh <TEAM_ID>`로 빌드, 앱 1회 실행, 시스템 설정에서 "PhoneBridge Finder" 켜기, PhoneBridge 설정 › Finder › "Finder 통합 사용" 켜기. 기기 없이도 "가상 기기" 볼륨으로 F1–F6을 먼저 확인할 수 있다.

| # | 요청된 검증 항목 | 절차 | 기대 결과 | 현재 상태 (2026-10-22 21:31, 가상 기기 볼륨) |
|---|---|---|---|---|
| F1 | Finder에서 기기 저장소 확인 | `mount -F`로 마운트 | 볼륨 이름·용량 표시 | **통과(실측)**: FSKit 마운트, `df` 238 GiB/92 GiB 여유(=256/98.4 GB), 루트 7개 폴더. **Finder 창·사이드바 표시: 사용자 확인(21:3x)** |
| F2 | 중첩 폴더 탐색 | `find`로 전체 순회 | 목록 일치 | **통과(실측)**: 폴더 14·파일 27, 빈 폴더 포함, 한글 이름 |
| F3 | 여러 파일 읽기 | 전 파일 바이트 검증 | 내용 일치 | **통과(실측)**: 27개 전부 바이트 일치(184 MB 영상 포함) |
| F4 | 파일 복사 및 미리보기 | `ditto`/`cp -R`, `qlmanage -t` | 복사본 일치, 미리보기 생성 | **통과(실측)**: 219 MB 복사 `diff -r` 동일. Quick Look이 PNG·PDF·텍스트(한글·이모지) 썸네일 생성. 동영상 미리보기는 실제 영상 데이터가 없어 미검증. Spotlight 메타데이터(`mdls`)는 볼륨에서 사용 불가 |
| F5 | 마운트/언마운트 반복 | `umount`/`mount -F` 5회 | 매번 성공 | **통과(실측)**: 5회 모두 성공, 잔여 마운트 0, 확장 프로세스 1개. **정정(V7-8)**: 이 시점 앱에는 `fskit.mount` 권한이 없어 앱 마운트 버튼은 동작할 수 없었다. 사용자가 본 볼륨은 CLI 마운트였다 |
| F6 | 앱과 Finder 동시 사용 | 두 볼륨 동시 마운트 + 병렬 읽기 | 오류 없음 | **부분 통과(실측)**: 내부·SD 볼륨 동시, 병렬 읽기·순회 오류 0. 앱 UI 탐색과의 동시 사용은 사용자 조작 필요(IPC 수준은 단위 테스트로 확인) |
| F7 | 대용량 파일 읽기 | 5 GB 파일 전체 검증 | 일치 | **통과(실측)**: 5,000,000,000 바이트 전부 일치, 4 GiB 넘는 오프셋 직접 읽기 일치(데모 메모리 데이터라 속도 수치는 의미 없음) |
| F8 | 케이블 분리 시 마운트 정리 | 마운트 중 분리 | 볼륨 해제 | **미검증**: 실제 Android 기기 필요(가상 기기는 분리 불가). 로직은 가짜 마운터 테스트로만 확인 |
| F9 | 연결 복구 이후 재마운트 | 다시 연결 | 새 세대로 재마운트 | **미검증**: 실제 기기 필요 |
| F10 | Finder 파일 수정 실패 시 데이터 보존 | 생성·복사·이름 변경·삭제·덧붙이기 시도 | 모두 거부, 변화 없음 | **통과(실측)**: 6가지 모두 `Permission denied`, 항목 수 41→41, 27개 파일 내용 그대로 |

### 4-0. Finder 쓰기 설정 수동 확인 (W4, 가상 기기)

1. 설정 › Finder › "Finder에서 쓰기 허용"을 켠다 → 확인 창의 "허용". 2. 저장공간의 가상 기기 볼륨을 "마운트" → "쓰기 가능 (실험적)" 표시, Finder에서 새 폴더 만들기 가능. 3. 스위치를 끈다 → 볼륨이 다시 마운트되고 "읽기 전용" 표시, Finder에서 새 폴더 불가. 4. 휴대전화 볼륨은 켜도 "읽기 전용"이고 "지금은 가상 기기에서만" 안내가 보인다.

### 4-2. W5 실기기 쓰기 검증 절차 (사용자 승인 후 실행)

대상: 휴대전화 내장 저장공간 루트의 **전용 폴더 "PhoneBridge W5 테스트"** 한 곳. 다른 폴더는 읽지도 쓰지도 않는다.

1. 앱 실행(실행 인자는 저장되지 않음):
   `open -a /Applications/PhoneBridge.app --args -settings.finderIntegration YES -settings.finderAutoMount YES -settings.finderWrites YES -diagnostics.finderWritesRealDevices YES -diagnostics.finderWriteScope "PhoneBridge W5 테스트" -diagnostics.showStagingObjects YES`
   - `finderWriteScope`: 앱이 실기기 쓰기를 이 폴더 안으로만 허용(밖은 EACCES, 단위 테스트로 확인).
   - `showStagingObjects`: 숨김 스테이징·백업 객체도 목록에 보여 잔여물을 확인.
2. 휴대전화 볼륨이 "쓰기 가능"으로 다시 마운트되었는지 확인(`ls -ld`가 `drwxr-xr-x`).
3. `scripts/finder-write-check.sh "/Volumes/PhoneBridge SM-S937N" "PhoneBridge W5 테스트" 1024` — W1·W2·W3·W4·W5(대치, 덮어쓰기, 덧붙이기, 원자적 저장)·빈 파일·W6·W7·W10·W12. 해시·크기·시간만 출력.
4. **W8 케이블 분리(사용자 조작)**: 1 GB 파일을 Finder로 복사하는 도중 케이블을 뽑는다 → Finder 오류, 기존 파일 보존 확인 → 다시 꽂으면 일지 정리 로그(`cleaned … leftover`)와 남은 객체 0 확인. 버퍼는 복구 목록에 올라오는지 확인.
5. 잔여물 확인: 앱 볼륨과 별도로 `mount -F -t phonebridge "<앱 볼륨 URL>&staging=1" <임시 폴더>`로 진단 마운트(D41: 숨김 객체는 이 마운트에서만 보임) → `ls -aR` 테스트 폴더 → `.phonebridge-*`, `._*`, `.DS_Store` 없음.
6. 휴대전화의 "내 파일" 앱에서 테스트 폴더를 열어 내용이 보이는지 확인(사용자, 선택).
7. 정리(사용자 선택): 테스트 폴더 삭제 또는 보존. 마지막에 앱을 일반 실행 인자로 다시 시작(실기기 쓰기 다시 차단).

가상 기기 예행연습(2026-10-22 23:20, 200 MiB): 18/18 통과, 다시 마운트 후 숨김 객체 표시 상태에서도 잔여물 0.

**실기기 결과 (2026-10-22 23:22–23:31, SM-S937N, 사용자 승인, 테스트 폴더 안에서만)**

| # | 결과 |
|---|---|
| 범위 제한 | 테스트 폴더 밖 `mkdir` → Permission denied, 기기 변화 없음 |
| 루트 폴더 생성 | 처음 실패(`LIBMTP_Create_Folder` 2009 Invalid Object Handle) → 원인: 루트를 0으로 보냄. Android는 SendObjectInfo에서 0xFFFFFFFF만 루트로 인정 → 브리지 수정(D39) 후 성공 |
| W1 작은 파일(`cp`, Finder) | 통과(해시) |
| W2 1 GiB Finder 복사 | 통과(해시). 전체 37.5초, 업로드 31.1초(약 33 MiB/s) |
| W3 폴더 트리 | 통과 |
| W4 새 폴더·이름 변경 | 통과 |
| W5 대치·덮어쓰기·덧붙이기·원자적 저장 | 통과 |
| 빈 파일 | 통과(2초 뒤 생성) |
| W6 삭제(파일, 트리) | 통과 |
| W7 이동 | 통과(MoveObject) |
| W8 케이블 분리 | **통과**: Finder "대치"(1 GiB → 3 GiB) 시작 6초 뒤 분리 → Finder 오류(100006), 업로드 실패(disconnected), 볼륨 자동 해제, 올리지 못한 3 GiB 버퍼는 복구 목록. 다시 연결(잠금 해제 후) 즉시 정리 일지가 지연 삭제된 원본을 **되돌림**(`restored 1`) → 원본 1 GiB 해시 일치. 스테이징은 업로드 전에 분리돼 기기에 생기지 않음(`cleaned 0`) |
| W9 관리 파일 | 새로 마운트(숨김 객체 표시) 후 `._*`·`.DS_Store`·`.phonebridge-*` 없음 |
| W10 공간 부족 | close가 ENOSPC, 기기에 아무것도 올라가지 않음 |
| W11 쓰기 꺼짐 | 일반 실행으로 되돌린 뒤 `touch` → Permission denied |
| W12 동시 사용 | 오류 없음. 단 1 GiB 업로드 중 다른 폴더 목록이 최대 27.5초 대기(MTP 세션 하나, K32) |

남은 것: 기기에 스테이징 객체가 생긴 뒤 분리되는 경우의 정리는 단위 테스트로만 확인(이번 분리는 업로드 시작 전). 테스트 폴더는 사용자 요청으로 휴대전화에 남겨 둠(약 1.07 GB).

### 4-1. 실제 Android 기기 결과 (2026-10-22 21:35–21:55, Samsung SM-S937N, 앱이 `FSClient`로 마운트)

개인 기기라 파일 이름·내용은 기록하지 않았다(개수·해시만).

| # | 결과 |
|---|---|
| F1 | **통과**: 볼륨 이름·용량 표시. 한글 이름은 D31 이후 Finder에 "가람의 S25 Edge – 내장 저장공간"으로 표시, 경로는 `/Volumes/PhoneBridge SM-S937N` |
| F2 | **통과**: DCIM 하위 3,428개 목록 8초 |
| F3 | **통과**: 사진 20개 두 번 읽기 해시 동일, JPEG 시그니처·`sips` 전체 디코드 성공 |
| F4 | **통과**: `ditto` 복사 6/6 동일, Quick Look 썸네일 6/6(동영상 포함) |
| F5 | **통과(CLI 3회)**. 앱 경로의 해제는 F8과 같은 이유로 실패 |
| F6 | **통과**: 병렬 읽기, 같은 저장소 이중 마운트 동시 사용 |
| F7 | **통과**: 565 MB MP4 21.6 MB/s, 임의 위치 읽기 일치. 기기에 4 GB 넘는 파일 없음 |
| F8 | 수정 전 **실패**(샌드박스가 해제 권한 요청을 막음, V7-8·K29) → D32(해제 헬퍼) 후 **통과**(22:05): 분리 0.4초 뒤 헬퍼가 볼륨 해제, 남은 마운트 없음 |
| F9 | **통과**: 수정 전에도 새 세대로 자동 재마운트됐으나 F8 때문에 이름에 ` 1`/` 2`가 붙음. D32 후(22:07) 잠금 해제·데이터 접근 허용 직후 1초 안에 새 세대로 같은 경로 `/Volumes/PhoneBridge SM-S937N`에 재마운트, Finder 표시 이름 한글, 루트 33개·DCIM 3,428개, 사진 해시 두 번 동일 |
| F10 | **통과**: 쓰기 6종 모두 거부, 기기 변화 없음 |

## 5. 4차: 사용자 경험·현지화 검증

자동:
- `ViewRenderingTests`: 상태·안내·전송·Finder 문제·충돌 화면을 한/영 × 라이트/다크 × 두 너비로 렌더(`~/Library/Containers/com.phonebridge.PhoneBridge.dev/Data/tmp/PhoneBridgeRenders`).
- 배치 규칙(`Layout`), 상태·해결 문구 번역, 안전한 연결 해제(브로커·앱·Finder).
- `python3 scripts/check-localization.py`: 코드의 문자열 키가 모두 한/영 값을 가짐.

실제 창 캡처(개발 빌드):
```
"<DerivedData>/PhoneBridge.app/Contents/MacOS/PhoneBridge" -settings.showDemoDevice YES -settings.onboardingCompleted YES -diagnostics.windowSnapshots YES
```
→ `~/Library/Containers/com.phonebridge.PhoneBridge.dev/Data/tmp/PhoneBridgeWindows`(한/영 × 라이트/다크 × 900/1280, 목록·아이콘·환영·첫 실행 안내·설정). 끝나면 앱이 스스로 종료한다.

사용자 확인(화면 조작 필요):
1. 설정 › 일반 › 언어를 바꾸면 메뉴(파일·보기·기기·이동·도움말), 툴팁, 상태 막대, 오류가 즉시 바뀐다. 편집·윈도우 같은 macOS 메뉴는 다시 실행 후.
2. 기기 › 안전하게 연결 해제(⌘E) → "이제 케이블을 분리해도 됩니다" → 다시 연결.
3. 전송 중 ⌘E → 확인 창.
4. VoiceOver(⌘F5): 사이드바 연결 상태, 아이콘 보기 항목 열기, 전송 진행률 읽기.
5. 창을 가장 작게(900pt) 줄인 뒤 Mac 패널을 켜면 정보 패널이 비켜 주고, 넓히면 다시 나타난다.

## 6. Android → Finder 직접 드래그 (D45)
자동(가상 기기, `DragExportTests` 9개): 대기열을 거친 파일·폴더 내려받기와 원래 이름, 실패 시 오류·잔여물 없음, 작업 취소 → 내보내기 취소, 오래된 사본 정리, 항목 제공자의 형식 순서(파일/폴더 → 텍스트, `fileURL` 아님), 앱 안 놓기는 선택 페이로드 1회·내려받기 없음, 아이콘 보기 다중 선택.

수동(가상 기기, 설치본):
1. 사이드바 '가상 기기' › Documents › `메모.txt`를 Finder 창(또는 데스크탑)에 끌어 놓는다 → 같은 이름의 파일이 생기고 크기 2,048바이트. 전송 목록에 "끌어 놓은 위치로 다운로드" 완료 행.
2. `가계부 2026.xlsx`와 `메모.txt`를 함께 선택해 목록 보기에서 끈다 → 두 파일 모두 생긴다(텍스트 조각 파일이 생기면 실패).
3. 아이콘 보기에서 2를 반복.
4. 루트의 `Documents` 폴더를 끈다 → 폴더와 안의 파일 2개, 빈 폴더 1개.
5. Download › `app-release.apk`(약 38 MB)를 끌어 놓고 전송 목록에서 취소 → Finder에 파일이 생기지 않는다.
6. Android 항목을 Mac 패널·Android 폴더 위로 끄는 기존 동작이 그대로인지(중복 작업 없음).

### 6-1. 실기기 드래그 확인 절차 (준비 완료, 실행 전)
대상: 휴대전화 내장 저장공간 루트의 **"PhoneBridge W5 테스트"** 폴더 안 파일만 끈다(W5에서 만든 시험 파일: `plain.bin`, `메모 1.txt`, `big.bin`(1 GiB), `이름 바꾼 폴더/사진 😀.dat`). 다른 폴더는 열지 않는다. 기기에 쓰지 않는다(드래그 내보내기는 읽기만 한다).
놓는 곳: Mac의 빈 폴더 `~/PhoneBridge 드래그 확인`(준비됨). 검사 스크립트는 이 폴더 안의 항목만 보며, 테스트 폴더에 없는 항목은 이름 없이 개수만 센다.

1. 휴대전화 연결·잠금 해제·파일 전송 모드. 앱을 Finder 연결(읽기 전용)과 함께 실행 — 비교용 독립 읽기 경로:
   `open -a /Applications/PhoneBridge.app --args -settings.finderIntegration YES -settings.finderAutoMount YES`
2. 앱에서 휴대전화 › 내장 저장공간 › "PhoneBridge W5 테스트"를 열고 Finder 창에 `~/PhoneBridge 드래그 확인`을 연다.
3. (D1) `메모 1.txt` 하나를 목록 보기에서 끌어 놓는다.
4. (D2) `plain.bin`과 `이름 바꾼 폴더`를 함께 선택해 목록 보기에서 끈다(파일 + 폴더, 다중 행).
5. (D3) 아이콘 보기로 바꿔 같은 두 항목을 다시 끌어 놓는다 → Finder가 이름 충돌을 묻는다. '대치'를 고른다(아이콘 보기 다중 끌기 확인).
6. (D4) `big.bin`(1 GiB)을 끌어 놓고 전송 목록에서 진행률·속도를 본 뒤 끝까지 기다린다.
7. 여기서 9번 검사를 한 번 실행해 D1–D4 결과를 남긴다.
   (D5, 선택) 놓은 `big.bin`을 휴지통으로 옮긴 뒤 다시 끌어 놓고, 진행 중에 전송 목록에서 취소 → Finder에 `big.bin`이 생기지 않는지.
8. (D6, 선택) D5와 같은 방법으로 시작한 뒤 케이블 분리 → 작업이 "연결 끊김"으로 실패하고 Finder에 부분 파일이 남지 않는지, 다시 꽂으면 정상 연결되는지.
9. 검사: `scripts/drag-check.sh "$HOME/PhoneBridge 드래그 확인" "/Volumes/PhoneBridge SM-S937N" "PhoneBridge W5 테스트"` — 크기·SHA-256(볼륨으로 다시 읽은 값과 비교), 폴더 구조, 텍스트 조각 파일 없음, 부분 파일 없음.
10. 로그: `/usr/bin/log show --last 30m --predicate 'process == "PhoneBridge" AND category == "transfer"'` — `drag export requested` 횟수, 각 작업의 완료/취소/실패, 파일 이름은 기록되지 않음.
11. 정리(사용자 선택): `~/PhoneBridge 드래그 확인` 삭제 여부. 휴대전화 쪽은 변하지 않는다.

## 7. 배포 전 확인 (5차, `RELEASE_READINESS.md`)
자동: `xcodebuild … test`(210개), 같은 명령에 `-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES` 및 `-enableThreadSanitizer YES`, `python3 scripts/check-localization.py`, `StabilityTests`·`PerformanceTests`(수치는 로그의 `PERF` 줄).
누수: 개발 빌드를 `MallocStackLogging=lite leaks --atExit -- <앱>/Contents/MacOS/PhoneBridge -diagnostics.windowSnapshots YES` — 앱 코드에서 나온 누수 0이어야 함(시스템 프레임워크 순환은 기록만).
패키지: `scripts/release.sh <TEAM> [notary 프로필]` → 엄격 서명 검증, `minos 26.0`, `get-task-allow` 없음, DMG 내용. Developer ID가 있으면 공증·스테이플 후 다른 Mac(또는 새 사용자 계정)에서 설치·`spctl` 확인.
Finder: 확장 켠 상태에서 `open -a /Applications/PhoneBridge.app --args -settings.finderIntegration YES -settings.showDemoDevice YES -diagnostics.autoMountDemo YES` → `mount | grep phonebridge`, 볼륨 목록, 앱 종료 시 해제.

