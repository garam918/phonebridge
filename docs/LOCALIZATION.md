# 현지화 지침 (4차 개발, 2026-10-23)

## 원칙
- 지원 언어: **한국어(ko, 기본값)**, English(en). 설정 › 일반 › 언어에서 바꾸며 앱 화면·메뉴·툴팁·오류·파일 상태가 즉시 바뀐다(`LocalizationManager`, `Localizable.xcstrings`).
- 모든 앱 문자열은 `loc.t(...)`를 거친다. 날짜·크기·숫자·시간은 선택한 언어의 `Locale`로 만든다(`formatDate`, `formatBytes`, `formatCount`, `formatDuration`, 화면 `\.locale`).
- **실제 파일·폴더 이름, 기기 이름, 기기가 알려 주는 저장소 이름은 번역하지 않는다.**
- 한국어는 macOS 한국어판에서 쓰는 말을 따른다.

## 용어집

| English | 한국어 | 비고 |
|---|---|---|
| Device / Connected Devices | 기기 / 연결된 기기 | |
| Storage (장소) | 저장소 | 내부 저장소, SD 카드 |
| Storage space (용량) | 저장 공간 | "저장 공간이 부족합니다" |
| File Transfer(s) | 파일 전송 | 전송 목록, 전송 실패 |
| Transfer Failed | 전송 실패 | |
| Mount in Finder / Unmount | Finder에 연결 / Finder에서 연결 해제 | "마운트"는 쓰지 않는다 |
| Safely Disconnect | 안전하게 연결 해제 | |
| Reconnect / Retry | 다시 연결 / 다시 시도 | |
| Quick Look | 훑어보기 | macOS Finder 용어 |
| Get Info | 정보 가져오기 | macOS Finder 용어 |
| Inspector | 정보 패널 | |
| Replace / Keep Both / Skip | 대치 / 둘 다 유지 / 건너뛰기 | macOS 복사 충돌 창 용어 |
| Enclosing Folder | 상위 폴더 | |
| Upload / Download | 업로드(Android로) / 다운로드(Mac으로) | 방향을 도움말에 함께 적는다 |
| File transfer mode (Android) | 파일 전송 모드 | 기기 메뉴: 'USB 사용 목적' › '파일 전송' |

## 운영체제가 정하는 문자열 (앱이 즉시 바꿀 수 없음)
macOS는 이런 문자열을 앱 프로세스의 언어(실행 시 `AppleLanguages`)로 만든다. PhoneBridge는 언어를 바꿀 때 `AppleLanguages`도 저장하므로 **앱을 다시 실행하면** 함께 바뀐다.
- 메뉴 막대의 시스템 항목: 앱 메뉴(서비스, 가리기, 종료), 편집, 윈도우, 도움말 메뉴의 기본 항목
- 시스템 창: 파일 열기/저장 패널의 버튼·사이드바(안내 문구는 앱이 넣으므로 즉시 바뀜), 훑어보기 창의 버튼, 설정 창 제목, 정보 창(About)
- 시스템이 만든 오류 설명(`localizedDescription`): 앱은 가능한 곳마다 자체 문구로 바꿔 보여 주고(Finder 연결 오류 등), 원문은 "자세한 정보"에만 둔다
- Finder 사이드바·창의 볼륨 이름은 기기 이름(번역 대상 아님)
- 시스템 알림: PhoneBridge는 시스템 알림(알림 센터)을 쓰지 않는다. 모든 알림은 앱 창 아래 상태 막대에 표시되며 즉시 언어가 바뀐다.
