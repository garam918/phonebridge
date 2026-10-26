# 배포 절차 (D58, D59)

## 지원 범위
| 항목 | 기준 |
|---|---|
| Mac | Apple Silicon(M1 이상) 전 모델. arm64 단일 바이너리(Intel 미지원) |
| macOS | **15.0(Sequoia) 이상** |
| Finder 연결 | macOS 26 이상(26: 터미널 `mount -F`로 연결, 27 이상: 앱이 자동 연결). macOS 15에서는 Finder 항목이 숨겨지고 앱 창으로 모두 사용 |

이유: FSKit은 15.4부터 있지만 PhoneBridge 볼륨에 필요한 URL 자원(`FSGenericURLResource`)은 26.0, 앱에서 바로 마운트하는 `FSClient.mountSingleVolume`은 27.0부터다. 앱은 FSKit을 약하게 연결해 FSKit이 없는 15.0–15.3에서도 실행된다. Finder 확장만 최소 26.0이다(그 아래에서는 등록되지 않음).

## 설치 방법 (사용자)
1. **DMG**: `PhoneBridge-<버전>.dmg`를 열고 응용 프로그램 폴더로 끌어 놓기.
2. **터미널 — 설치 스크립트**:
   ```
   curl -fsSL https://github.com/garam918/phonebridge/releases/latest/download/install.sh | bash
   ```
   옵션: `--user`(~/Applications, 관리자 권한 없이), `--check`(검증만), `--dmg <파일|URL>`, `--uninstall [--zap]`.
3. **터미널 — Homebrew**:
   ```
   brew trust --cask garam918/phonebridge/phonebridge   # Homebrew 7+ (외부 탭 허용)
   brew install --cask garam918/phonebridge/phonebridge
   brew uninstall --zap --cask phonebridge
   ```

스크립트와 Homebrew 모두 공증된 같은 DMG를 쓴다. 설치 스크립트는 curl로 받은 파일에 격리(quarantine) 표시가 없어 Gatekeeper가 첫 실행 때 검사하지 않으므로, 설치 전에 직접 확인한다: SHA-256, Developer ID 서명, 팀 ID `KB2PLX99H6`, Apple 공증(`spctl`), 번들 ID. 하나라도 실패하면 설치하지 않는다. Gatekeeper를 끄거나 격리 표시를 지우는 명령은 쓰지 않는다.

## 릴리스 절차 (개발자)
1. **(한 번) Developer ID Application 인증서**: 팀 Account Holder가 Apple Developer › Certificates에서 발급 → 이 Mac 키체인에 설치.
2. **(한 번) 공증 자격 증명**: `xcrun notarytool store-credentials <프로필> --apple-id <Apple ID> --team-id KB2PLX99H6` (앱 암호는 appleid.apple.com에서 발급, 키체인에만 저장).
3. **(한 번) 배포 저장소**: GitHub 저장소(예: `garam918/phonebridge`)와 Homebrew 탭 저장소 `garam918/homebrew-phonebridge`(폴더 `Casks/`).
4. **버전 올리기**: `MARKETING_VERSION`(Xcode 프로젝트) 변경.
5. **빌드·공증·DMG**: `scripts/release.sh KB2PLX99H6 <프로필>`
   - 산출물: `~/Library/Developer/PhoneBridge/release/<버전-빌드>/` (iCloud 동기화 폴더 밖, K37)
   - 자동 검사: 엄격 서명 검증, Hardened Runtime, `get-task-allow` 없음, arm64 단일, 앱·헬퍼·라이브러리 minos 15.0, 확장 26.0, `LSMinimumSystemVersion` 15.0, FSKit 약한 연결, 앱·DMG 공증·스테이플
   - 파일: `PhoneBridge-<버전>.dmg`(+`.sha256`), `PhoneBridge.dmg`(+`.sha256`, "latest" 주소용 고정 이름), `install.sh`
6. **설치 정보 채우기**: `scripts/publish-metadata.sh --repo garam918/phonebridge --release-dir <산출물 폴더>` → Cask(버전·SHA-256·주소), `install.sh`(기본 주소) 갱신. 공증되지 않은 DMG면 거부한다.
7. **업로드**: GitHub Releases에 태그 `v<버전>`으로 위 5개 파일 첨부. `packaging/homebrew/Casks/phonebridge.rb`를 탭 저장소에 푸시.
8. **설치 확인**(아래 매트릭스) 후 공개.

## 설치 확인 매트릭스 (릴리스마다)
| 환경 | DMG | install.sh | Homebrew | 확인 내용 |
|---|---|---|---|---|
| macOS 15.x (가상 머신 가능) | ✓ | ✓ | ✓ | 실행, 가상 기기 탐색, Finder 항목 숨김 안내, 제거 |
| macOS 26.x | ✓ | ✓ | ✓ | + Finder 확장 켜기, `mount -F` 연결 |
| macOS 27.x | ✓ | ✓ | ✓ | + 자동 Finder 연결, 업데이트 후 확장 켜짐 유지(K38) |
| Apple Silicon 실기(M1 포함 권장) | ✓ | | | 실기기 USB 연결·전송(가상 머신은 USB 연결 불가) |
| 새 사용자 계정 또는 깨끗한 Mac | ✓ | ✓ | | Gatekeeper 첫 실행 경고 없음 |

## 현재 상태 (2026-10-23)
- 준비됨: 최소 버전 15 빌드, 릴리스·설치 스크립트, Cask, 검증 테스트(아래 V18).
- 공증 빌드 성공(V19): 앱·DMG Accepted, Gatekeeper 통과, FSKit 권한 포함 확인, `install.sh` 실제 설치·Finder 마운트 확인.
- 남음: 배포 저장소(`OWNER` 자리)·출시 버전 결정, 업로드.
- 미검증: macOS 15·26 실제 실행(이 Mac은 27, 가상 머신 도구 없음).

## 1.0.0 (2026-10-23)
- 릴리스: https://github.com/garam918/phonebridge/releases/tag/v1.0.0
- Homebrew 탭: https://github.com/garam918/homebrew-phonebridge
- 공개 저장소의 문서는 이 프로젝트 `docs/`의 INSTALL·PRIVACY·USER_GUIDE 사본이다. 문서를 고치면 공개 저장소에도 반영한다(작업용 사본: 커밋 작성자 noreply 주소 설정).
- 다음 릴리스: 버전 올리기 → `release.sh` → `publish-metadata.sh` → `gh release create v<버전> …` → 탭의 Cask 갱신.


## 1.0.1 빌드 (2026-10-23) — 사용하지 않음
- 2026-10-24 사용자 결정: 버전은 1.0.0으로 유지. 아래 1.0.1 산출물은 앱 안 버전이 1.0.1이라 배포하지 않는다. Cask는 공개된 1.0.0(SHA-256 `12bff234…0dd6106a`)으로 되돌림.
- 점검 수정 릴리스(D61–D66, V21). 노트: `docs/RELEASE_NOTES.md`.
- 산출물: `~/Library/Developer/PhoneBridge/release/1.0.1-202610231627/` — 공증·스테이플 완료, `install.sh --check` 통과.
- 남은 단계: `gh release create v1.0.1` (5개 파일), 탭 저장소 `Casks/phonebridge.rb` 갱신, 설치 확인 매트릭스.

## 1.0.0 수정 빌드 (2026-10-25, 공개됨)
- 빌드 202610251403, SHA-256 `1faeffdf…ae64622d`. v1.0.0 릴리스 파일 교체, Homebrew Cask 갱신(V23).
- 소스 공개: https://github.com/garam918/phonebridge (MIT, D69).
- 같은 버전으로 파일을 바꿀 때는 **파일 교체와 탭 갱신을 바로 이어서** 한다(사이에는 `brew install`이 체크섬 불일치로 실패).
