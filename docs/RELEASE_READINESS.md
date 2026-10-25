# 정식 배포 준비 보고서 (2026-10-23, 0.4.0)

## 결론
**배포 준비: 대부분 완료. 실제 배포: 불가(장애물 있음).**
- 배포용 빌드·서명 검증·DMG 생성 파이프라인은 동작한다(`scripts/release.sh`). 다만 만들어진 DMG는 **"Apple Development" 서명이라 다른 Mac에서 열리지 않는다**(Gatekeeper 거부, 실측).
- 배포를 막는 장애물(우선순위 순):
  1. **Developer ID Application 인증서 없음** → 공증(notarization) 불가. 키체인에는 Apple Distribution, iPhone Distribution, Apple Development만 있다. 팀의 Account Holder가 발급해야 한다. Mac App Store는 D32(샌드박스 밖 해제 헬퍼) 때문에 불가.
  2. **FSKit 권한의 Developer ID 프로필 미확인**: `com.apple.developer.fskit.fsmodule`(확장)과 `com.apple.developer.fskit.mount`(앱)가 Developer ID 배포 프로필에 들어가는지 확인하지 못했다(인증서가 없어 내보내기 시도 불가).
  3. **실기기 호환성 표본 1대**: Samsung Galaxy S25 Edge(SM-S937N)만 검증. Galaxy Tab·Pixel·기타 기기, SD 카드, macOS 26 Mac은 미검증(`DEVICE_MATRIX.md`).
  4. **업데이트 시 Finder 확장 꺼짐 가능성**: 빌드 202610231128 설치 직후 마운트가 "Client not authorized"로 실패했고, 사용자가 시스템 설정에서 확장을 다시 켜자 정상 마운트됐다(V16). 업데이트마다 꺼지는지는 다음 설치 때 확인 필요(K38).
  5. **법무 확인**: LGPL 준수 방식(D46)과 PhoneBridge 자체 라이선스·저작권 표기 미정.

## 1. 빌드
| 항목 | 결과 |
|---|---|
| Debug 빌드(개발, ad-hoc) | ✅ 성공 |
| 팀 서명 설치본(Debug, Apple Development) | ✅ 빌드 202610231128, `/Applications` 설치, 실행·종료 확인 |
| Release 아카이브 → 내보내기(Apple Development) | ✅ `~/Library/Developer/PhoneBridge/release/0.4.0-202610231126/` |
| 서명 검증 | ✅ `codesign --verify --deep --strict` 통과. 앱·확장·헬퍼·dylib 모두 Hardened Runtime, `get-task-allow` 없음 |
| 최소 OS | ✅ 앱·libmtp·libusb 모두 `minos 26.0`, arm64 단일 |
| DMG | ✅ 1.5 MB, 앱 + 응용 프로그램 바로가기 + 설치 안내 + 라이선스, 이름에 `NOT-FOR-DISTRIBUTION` |
| Gatekeeper(`spctl`) | ❌ rejected (예상대로, Developer ID·공증 없음) |
| 공증·스테이플 | — 실행 불가(인증서 없음). 스크립트 경로는 준비됨 |

이번에 고친 배포 관련 문제:
- **네이티브 라이브러리(D46)**: Homebrew 정적 라이브러리(macOS 27용)를 버리고, 고정 버전 소스(SHA-256 검증)로 macOS 26용 동적 라이브러리를 빌드해 앱에 넣는다(`scripts/build-native-deps.sh`). LGPL 준수와 macOS 26 지원을 함께 해결.
- **Intel 아키텍처**: Release 아카이브가 x86_64까지 빌드하다 실패 → `ARCHS = arm64`(Apple Silicon 전용 목표).
- **iCloud 동기화 폴더**: 저장소가 `~/Documents`(iCloud Drive)에 있어 내보낸 번들에 Finder 메타데이터가 붙고 엄격한 서명 검증이 실패 → 릴리스 산출물은 `~/Library/Developer/PhoneBridge/release`에 만든다.

## 2. 자동화 테스트
| 실행 | 결과 |
|---|---|
| 전체(Swift Testing, 앱 호스트) | ✅ **231개 / 31개 묶음 통과** (보완 7건 후, V17) |
| Address Sanitizer + UB Sanitizer | ✅ 230개 통과(V17). 처음 실행에서 테스트 코드의 `#expect`(Optional UInt64 비교)가 Swift Testing 변환에서 스택 경계 위반으로 보고됨 → 테스트 작성 방식을 바꿔 회피(앱 코드 아님, K36) |
| Thread Sanitizer | ✅ 230개 통과. 경고 5건은 모두 직렬 큐 실행기 액터의 TSan 오탐(최소 재현 프로그램으로 확인, K39) |
| 현지화 검사(`check-localization.py`, 카탈로그 완전성) | ✅ 368개 키 모두 ko/en 번역됨, 소스의 리터럴 키 304개 모두 존재 |

새 테스트: 안정성(USB 100회 연결·분리, 빠른 반복 40회, 전송 큐 36개 작업 + 취소), 로컬 임시 파일 복구, 성능 측정, 진단 내보내기, Android→Finder 드래그.

## 3. 안정성
| 요구 | 결과 | 근거 |
|---|---|---|
| USB 연결/해제 반복 | ✅ 모의 100회: 세션 100개 모두 닫힘, 세대 100개 고유, 메인 스레드 MTP 호출 0. 빠른 반복 40회 후 열린 세션 정확히 1개 | `StabilityTests` |
| 〃 (실기기) | ⚠️ 수동 분리·재연결 수 회(F8/F9, W8). 반복 자동화 불가(케이블 조작) | V7-8, V11 |
| MTP 연결 실패 대응 | ✅ 열기 실패 재시도·수동 재시도, 일시적 "장치 없음" 재시도, 잠김, 다른 앱 점유 | `DeviceBrokerTests` |
| 앱·Finder 동시 접근 | ✅ 실기기 W12(동시 사용 오류 없음), 업로드 중 탐색 대기 최대 1.9초(D40) | V11, V12 |
| 작업 큐 | ✅ 36개 작업(다운로드·업로드·기기 내 복사) + 무작위 취소: 실패 0, 기기·Mac 임시 파일 0 | `StabilityTests` |
| 비정상 종료 복구 | ✅ 기기 쪽(일지, W3/W8 실기기 복원), Finder 쓰기 버퍼(복구 목록), **신규: Mac 쪽 다운로드 임시 파일**(`LocalStagingJournal`, 다음 실행 때 삭제) | `LocalStagingJournalTests`, V11 |
| 종료 | ✅ **수정**: 종료 처리 중 한 단계가 멈추면 앱이 영원히 종료되지 않을 수 있었음 → 5초 뒤 무조건 종료(D48). 진단 실행에서 재현된 교착(주 액터 안에서 `terminate`)도 수정. 재측정: 종료 1초 이내 | `leaks` 실행, 설치본 |
| 캐시 정리 | ✅ 미리보기 캐시 최대 2 GB(오래된 것부터 삭제, 신규), 시작·종료 시 삭제. 드래그 사본 30분/다음 실행. 썸네일 메모리 캐시 300개 상한 | `PerformanceTests` |
| 메모리 누수 | ✅ `leaks`(실제 앱, 한/영 × 라이트/다크 × 두 창 크기 화면 순회 40장 후 종료 시점): 28 KB, **모두 시스템 프레임워크**(App Intents XPC 연결 순환 3개, AppKit 창 닫기 애니메이션 1개). PhoneBridge·libmtp 코드 0 | §6 |
| 네이티브 포인터·버퍼 | ✅ 검토: 모든 `pb_*` 할당에 `defer` 해제, 진행 콜백 컨텍스트 `withExtendedLifetime`, 세션은 액터로 직렬화. **수정 3건**: 썸네일 실패 시 버퍼 누수, 업로드 이름 `strdup` 실패 미확인, 이름 변경 NULL 인자 | `PBMTPBridge.c` |
| 장시간 전송 | ⚠️ 모의 1 GiB 스트리밍(메모리 증가 ≤10 MiB), 모의 4.5 GiB 업로드. 실기기 1 GiB × 수 회. 수십 GB·수 시간 연속은 미검증 | |
| 절전·잠금 | ⚠️ 기기 잠금·해제는 실기기 확인. Mac 잠자기 중 전송·연결 유지는 미검증 | |
| 대량 선택 드래그 | ✅ **수정**: 1만 개 선택 드래그가 수 분간 멈춤(행마다 전체 선택 페이로드를 새로 만듦, O(n²)) → 캐시로 11–24 ms | `PerformanceTests` |

## 4. 성능 (측정한 것만)
측정 환경: 이 Mac(Apple Silicon, macOS 27.0.1), Debug 빌드 테스트 호스트. 모의 기기 수치는 **PhoneBridge 자체 처리 비용**이며 USB·휴대전화 속도가 아니다.

| 항목 | 측정값 | 출처 |
|---|---|---|
| 1만 개 폴더 목록+정렬(모의) | 27–32 ms | `PerformanceTests` 3회 |
| 1만 개 재정렬(크기 / 이름) | 18–19 ms / 11 ms | 〃 |
| 1만 개 이름 필터 | 8 ms | 〃 |
| 1만 개 선택 드래그 항목 생성 | 11–24 ms (수정 전: 3분 넘게 멈춤) | 〃 |
| 다운로드 처리 경로(모의 1 GiB, 스테이징·크기 검증 포함) | 188–2,832 MiB/s(실행마다 큰 편차, 디스크 캐시 영향). **최저값도 실기기 USB 속도의 5배 이상** → 앱 쪽 병목 아님 | 〃 |
| 1 GiB 다운로드 중 메모리 증가 | ≤10 MiB(스트리밍) | 〃 |
| 실기기 폴더 목록 | DCIM 3,428개 8초(Finder 볼륨 경유) | V7-8 F2 |
| 실기기 읽기 | 565 MB 동영상 21.6 MB/s | V7-8 F7 |
| 실기기 쓰기 | 1 GiB 업로드 약 33 MiB/s(조각 업로드 전후 속도 차이 없음) | V11, V12 |
| 업로드 중 다른 폴더 탐색 대기 | 27.5초 → 최대 1.9초 | D40, V12 |
| 실행 중 앱 메모리 | 물리 사용량 약 346 MB, 최대 409 MB(Debug, 화면 순회 직후) | `leaks` |

미측정: 실기기 썸네일 로딩 시간, 앱 다운로드 버튼 경로의 실기기 속도, UI 프레임 지연(Instruments), Release 빌드 메모리, 수천 개 실기기 폴더의 앱 탐색 시간.

## 5. 호환성
`DEVICE_MATRIX.md`. 검증: Galaxy S25 Edge(SM-S937N) 1대. Galaxy Tab, Pixel, 기타 기기, SD 카드: 미검증.

## 6. 배포 항목
| 항목 | 상태 | 문서·파일 |
|---|---|---|
| App Sandbox·권한 검토 | ✅ 아래 표 | — |
| FSKit 확장 활성화 절차 | ✅ 문서화(앱 안내 + 시스템 설정 경로), 다시 켠 뒤 마운트 확인(V16). ⚠️ 재설치 후 꺼짐(K38) | `INSTALL.md` |
| 서명·공증 준비 | ⚠️ 스크립트 준비, 인증서 없음 | `scripts/release.sh` |
| DMG | ✅ 생성(배포 불가 표시) | `scripts/release.sh` |
| 설치·제거 가이드 | ✅ 한/영 | `INSTALL.md` |
| 오픈소스 라이선스·NOTICE | ✅ 앱 안(도움말 › 오픈소스 라이선스), DMG, 문서 | `LICENSES.md`, `Resources/Licenses` |
| 개인정보 처리 | ✅ 한/영, 로그의 이름·경로를 비공개로 바꿈(D47) | `PRIVACY.md` |
| 사용자 가이드 | ✅ 한/영 | `USER_GUIDE.ko.md`, `USER_GUIDE.en.md` |
| 장애 진단 로그 내보내기 | ✅ 도움말 › 진단 정보 내보내기…(D49) | — |

### 권한(entitlement) 검토
| 실행 파일 | 샌드박스 | 권한 | 판단 |
|---|---|---|---|
| PhoneBridge.app | 예 | USB, 사용자 선택 파일 읽기/쓰기, 다운로드 폴더, 앱 범위 북마크, App Group, FSKit 마운트 | 모두 사용 중. 네트워크 권한 없음(외부 통신 없음) |
| PhoneBridgeFinder.appex | 예 | FSKit 모듈, App Group | 최소 |
| PhoneBridgeUnmounter.xpc | **아니오** | 없음 | 샌드박스 앱이 root 소유 FSKit 볼륨을 해제할 수 없어 필요(D32). 요청 경로를 다시 검사해 PhoneBridge 볼륨만 해제, 같은 팀 서명의 앱만 연결 허용. Mac App Store 불가의 원인 |
- 보안 수준을 낮추는 설정 없음: Hardened Runtime 예외(JIT, 라이브러리 검증 해제 등) 없음.

## 7. 한국어/영어
- 카탈로그 368개 키 모두 두 언어, 리터럴 키 누락 0. 이번 추가 문구 9개(진단 내보내기, 라이선스 메뉴, 드래그 전송 행) 포함.
- 화면 번역 확인은 4차(V13)의 렌더·창 캡처 이후 새 문구는 테스트(키 존재)로만 확인. 운영체제가 만드는 문구의 한계는 `LOCALIZATION.md`.

## 8. 남은 일(배포 전 필수 → 권장 순)
1. Developer ID Application 인증서 발급 → `scripts/release.sh <TEAM> <notary 프로필>`로 공증·스테이플 → 깨끗한 Mac(또는 새 사용자 계정)에서 DMG 설치·Gatekeeper 확인.
2. Developer ID 프로필의 FSKit 권한 확인, 공증 빌드에서 Finder 마운트 확인.
3. 다음 업데이트 설치 때 Finder 확장이 켜진 채로 남는지 확인(꺼진다면 업데이트 안내에 추가). 실기기 Finder 마운트를 새 빌드(동적 라이브러리)로 재확인.
4. 기기 매트릭스 확대: Pixel, Galaxy Tab, SD 카드 기기, macOS 26 Mac.
5. 실기기 장시간(수십 GB) 전송, Mac 잠자기 중 전송, 앱 다운로드 버튼 경로 실측.
6. 법무: LGPL 준수 방식, PhoneBridge 라이선스·저작권 표기(`NSHumanReadableCopyright`).
7. 버전 번호: `MARKETING_VERSION` 0.4.0 → 출시 번호 결정.

## 9. 보완 반영 (2026-10-23 13시, D51–D57, V17)
한글 이름 NFC, 큰 다운로드 조각 읽기, Finder 다중 끌어 놓기 한 작업, 실기기 Finder 쓰기 설정(기본 꺼짐), 원본 보호 쓰기 공통화, 확장 상태 파일(진단), 썸네일 LRU. 업데이트 두 번 모두 Finder 확장 켜짐 유지(K38). 실기기 확인은 남음.

## 10. 지원 범위와 설치 경로 (D58, D59, V18)
최소 macOS 15(Sequoia), Apple Silicon 전 모델. Finder 연결은 macOS 26 이상. 설치: DMG, `install.sh`(터미널, 직접 서명·공증 검사), Homebrew Cask. 절차: `DISTRIBUTION.md`. 장애물은 그대로 Developer ID 인증서(K35)와 macOS 15·26 실행 미검증(K41).

## 11. 첫 공증 빌드 (V19)
Developer ID 서명·공증·스테이플 성공(앱, DMG), Gatekeeper "Notarized Developer ID", FSKit 권한이 배포용 프로필에 포함됨, 설치 스크립트로 실제 설치 후 Finder 마운트 확인. 배포를 막던 기술적 장애물은 없어졌고, 남은 것은 배포 저장소·버전 결정과 업로드, macOS 15·26 실행 확인이다.
