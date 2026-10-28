# 개인정보 처리 방식 / Privacy

## 한국어

**요약: PhoneBridge는 아무 데이터도 외부로 보내지 않습니다.** 서버, 계정, 분석(analytics), 광고, 자동 오류 보고가 없습니다. 앱에는 네트워크 권한(`com.apple.security.network.client`)이 없어 macOS 샌드박스가 인터넷 연결을 막습니다.

### 앱이 다루는 정보
| 정보 | 용도 | 저장 위치 | 외부 전송 |
|---|---|---|---|
| 휴대전화의 파일·폴더 목록과 내용 | 사용자가 요청한 탐색·복사·미리보기 | 메모리, 사용자가 고른 Mac 폴더 | 없음 |
| 미리보기용 임시 사본 | 훑어보기(Quick Look) | 앱 컨테이너 캐시(최대 2 GB, 시작·종료 시 삭제) | 없음 |
| Finder로 끌어 놓을 때의 임시 사본 | 놓은 위치로 복사하기 전 보관 | 앱 컨테이너 tmp(30분 뒤 또는 다음 실행 때 삭제) | 없음 |
| 기기 모델명·제조사·USB ID·일련번호 | 기기 구분, 재연결 인식 | 메모리(일련번호는 기기 식별자로만 사용) | 없음 |
| 마지막으로 연 Mac 폴더(보안 북마크) | 다시 열 때 권한 유지 | 앱 설정 | 없음 |
| 전송 중 임시 파일 기록(이름 없이 위치만) | 비정상 종료 후 정리 | 앱 컨테이너 Application Support | 없음 |
| Finder 쓰기 버퍼(실험 기능 사용 시) | 업로드 전 보관, 실패 시 복구 | App Group 컨테이너 | 없음 |
| 앱 설정(언어, 보기 방식 등) | 설정 유지 | UserDefaults(앱 컨테이너) | 없음 |
| Finder 확장 상태(이벤트 종류·오류 코드, 최근 100개, 이름 없음) | 진단 정보 내보내기 | App Group 컨테이너 `ExtensionStatus.json` | 없음 |
| iPhone·iPad 사진·동영상 목록과 내용(macOS 이미지 캡처를 통해) | 사용자가 요청한 탐색·가져오기·삭제 | 메모리, 사용자가 고른 Mac 폴더 | 없음 |
| USB 연결 감지("휴대전화를 연결하면 열기"를 켰을 때) | Android 기기나 iPhone·iPad가 꽂히면 PhoneBridge 열기 | 메모리(기기 종류만 판단, 저장하지 않음) | 없음 |

### 시스템 기록(로그)
- 문제 진단을 위해 macOS 통합 기록(Unified Log)에 앱 동작을 남깁니다.
- **파일·폴더 이름, 기기 이름(예: "홍길동의 Galaxy"), Mac 경로**는 "비공개" 값으로 기록되어 macOS가 `<private>`로 가립니다. 기기 일련번호가 포함된 식별자는 해시로만 기록됩니다.
- 기기 모델명, USB ID, 오류 코드, 바이트 수, 시간은 그대로 기록됩니다.

### 진단 정보 내보내기
도움말 › 진단 정보 내보내기는 사용자가 고른 위치에 텍스트 파일 하나를 만듭니다. 앱이 자동으로 보내지 않으며, 사용자가 직접 지원 요청에 첨부할 때만 전달됩니다. 포함 내용: 앱·macOS 버전, Mac 모델, 설정 요약, 연결된 기기의 모델·USB ID·상태(일련번호는 짧은 해시), Finder·전송 상태(파일 이름 없음), 이번 실행의 앱 기록(비공개 값은 `<private>`). 저장 전에 파일을 열어 내용을 확인할 수 있습니다.

### 휴대전화에 남기는 것
PhoneBridge는 휴대전화에 앱을 설치하지 않습니다. 업로드·교체 중에만 `.phonebridge-`로 시작하는 숨김 임시 파일을 만들고, 끝나면(또는 다음 연결 때) 지웁니다.

### 삭제
앱과 함께 위 저장 위치를 지우면 모든 정보가 사라집니다(`docs/INSTALL.md` 제거 절차).

## English

**In short: PhoneBridge sends nothing anywhere.** There is no server, account, analytics, advertising or automatic crash reporting. The app has no network entitlement, so the macOS sandbox blocks internet access.

- **Phone files and folders** are read only when you browse, copy or preview them, and are written only where you choose.
- **Temporary copies** (previews: app cache, at most 2 GB, cleared at launch and quit; drag to Finder: app tmp, removed after 30 minutes or at next launch) stay inside the app's container.
- **Device details** (model, manufacturer, USB ids, serial number) identify the device for reconnection and stay in memory.
- **Open on connect** (when turned on): a login-item helper reads USB descriptors to recognise an Android device and opens PhoneBridge. It stores nothing and never accesses the phone.
- **Finder extension status** (event kinds and error codes, last 100, no names) is kept in the App Group container for diagnostics.
- **Logs** go to the macOS unified log. File and folder names, device names and Mac paths are logged as private values (shown as `<private>`); identifiers containing serial numbers are logged only as hashes.
- **Help › Export Diagnostics** writes one text file where you choose. Nothing is sent automatically; you decide whether to attach it to a support request. It contains versions, Mac model, settings, device models / USB ids / states (serials as short hashes), Finder and transfer state without file names, and this launch's log with private values redacted.
- **On the phone** PhoneBridge installs nothing. It creates hidden temporary files starting with `.phonebridge-` only during uploads and replacements and removes them afterwards (or at the next connection).
- **Removal**: delete the app and the folders listed in `docs/INSTALL.md`.
