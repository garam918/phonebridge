
너는 10년 이상 경력의 macOS 네이티브 앱 개발자이자
시스템 프로그래밍 및 소프트웨어 아키텍트야.

프로젝트 루트의 CLAUDE.md를 반드시 읽고
그 지침에 따라 PhoneBridge 개발을 시작해줘.

[프로젝트 목표]

Android 스마트폰이나 태블릿을 Mac에 USB로 연결하면
기기 내부 파일을 탐색하고 관리할 수 있는
macOS 네이티브 프로그램을 개발한다.

최종적으로 두 가지 인터페이스를 제공한다.

1. 전용 macOS 파일 탐색기
2. Finder에 Android 저장소를 마운트하는 기능

한국 사용자를 우선 대상으로 하며,
한국어를 기본 언어로 하고 영어도 지원한다.

설정에서 한국어와 영어를 선택할 수 있어야 하며
일반 앱 UI는 재실행 없이 언어가 전환되어야 한다.

[개발 환경]

- Swift + SwiftUI
- C + libmtp + libusb
- IOKit
- FSKit
- Apple Silicon 우선
- macOS 26 이상 우선
- Xcode 프로젝트 사용

[이번 작업]

이번 단계에서는 전체 기능을 한 번에 개발하지 말고
개발 기반과 검증 가능한 최초 MVP를 구축해줘.

1. 현재 개발 환경 조사
   - macOS 버전
   - Xcode 및 Swift 버전
   - 사용 가능한 SDK
   - Homebrew 설치 여부
   - libmtp / libusb 설치 가능 여부
   - FSKit API 및 entitlement 지원 여부

2. 프로젝트 문서 작성
   - PRD.md
   - ARCHITECTURE.md
   - TASKS.md
   - DECISIONS.md
   - TEST_PLAN.md
   - KNOWN_ISSUES.md

3. 프로젝트 아키텍처 구축
   - SwiftUI Application
   - Core interfaces
   - DeviceFileSystem protocol
   - MockDeviceFileSystem
   - Device state model
   - Dependency injection
   - Basic logging

4. 기본 UI 구현
   - 메인 탐색기
   - 연결된 기기 목록 사이드바
   - 파일 및 폴더 목록
   - 전송 상태 표시 영역
   - 설정 화면
   - 연결되지 않은 상태의 안내 화면

5. 한국어 / 영어 지원
   - Localizable.xcstrings 생성
   - LocalizationManager 작성
   - 설정에서 언어 선택
   - UserDefaults에 설정 저장
   - UI 재실행 없는 언어 변경
   - 메뉴, 알림 및 오류 문구 현지화 구조 마련

6. Mock 기반의 파일 탐색 구현
   - 테스트용 가상 Android 기기
   - 테스트 폴더 및 파일
   - 디렉터리 탐색
   - 파일 목록 정렬
   - 선택 및 파일 정보 표시

7. 기본 테스트 구성
   - 프로젝트 빌드
   - 주요 ViewModel 테스트
   - 한국어 / 영어 전환 테스트
   - Mock 파일 목록 테스트

[UI 디자인 방향]

macOS Finder와 비슷한 학습 부담을 갖도록
Apple Human Interface Guidelines를 참고한다.

- 네이티브 macOS 디자인
- 깔끔한 툴바와 사이드바
- 기기 및 저장소 탐색
- 리스트 / 그리드 보기
- 파일 정보 Inspector
- macOS 라이트 모드 / 다크 모드
- SF Symbols 활용
- 불필요한 애니메이션 배제
- 한국어 기준 자연스러운 용어 사용

[중요 제약]

- 아직 실제 MTP 연결을 성공한 것처럼 구현하지 마.
- 실제 Android 기기 작업과 Mock 작업을 구분해.
- Finder 통합은 추후 단계로 남겨둬.
- 불필요한 외부 의존성을 추가하지 마.
- 코드가 아닌 설명만 작성하고 종료하지 마.
- 필요한 실제 파일을 생성하고 빌드해.
- Xcode가 없다면 빌드 성공을 주장하지 마.
- 임의의 macOS 보안 설정 변경을 금지한다.

[작업 방식]

먼저 환경을 확인하고 간단한 구현 계획을 세워.
그다음 실제 프로젝트 파일을 생성하고 구현해.

작업 종료 시 다음 내용을 정리해줘.

1. 생성된 프로젝트 구조
2. 구현 완료 기능
3. 실제 실행한 빌드 / 테스트와 결과
4. 미구현 항목
5. 확인된 기술적 문제
6. 다음 작업에서 사용할 개발 단계
