# 보안 정책 / Security Policy

## 지원 버전 / Supported versions
보안 수정은 [최신 릴리스](https://github.com/garam918/phonebridge/releases/latest)에만 적용합니다.
Security fixes go into the [latest release](https://github.com/garam918/phonebridge/releases/latest) only.

## 신고 방법 / Reporting a vulnerability

**자세한 내용을 공개 Issue에 쓰지 마세요.** 공개된 약점은 수정이 배포되기 전에 악용될 수 있습니다.

1. [새 Issue](https://github.com/garam918/phonebridge/issues/new)를 제목 **"Security contact"** 로 엽니다. 본문에는 **영향을 받는 부분만**(예: 앱, Finder 확장, 설치 스크립트) 적고, 재현 방법·코드·로그는 적지 않습니다.
2. 관리자가 그 Issue에 비공개로 자세한 내용을 받을 방법을 답합니다.
3. 수정이 배포되면 Issue를 닫고, 원하시면 릴리스 설명에 신고자를 밝힙니다.

**Do not post details in a public issue.** A disclosed weakness can be exploited before a fix ships.

1. Open a [new issue](https://github.com/garam918/phonebridge/issues/new) titled **"Security contact"**. Name only the affected part (e.g. the app, the Finder extension, the install script); leave out steps, code and logs.
2. The maintainer replies there with a private way to send the details.
3. Once a fix ships, the issue is closed and, if you wish, you are credited in the release notes.

## 범위 / Scope
- PhoneBridge 앱, Finder 확장(FSKit), 볼륨 해제 헬퍼, 설치 스크립트(`scripts/install.sh`), Homebrew Cask
- 포함된 libmtp·libusb 자체의 문제는 각 프로젝트에도 알려 주세요 / for libmtp and libusb themselves, please also tell those projects.

이 프로젝트는 개인이 관리하므로 답변·수정 일정을 약속할 수는 없지만, 받은 신고는 다음 릴리스보다 먼저 확인합니다.
This is a one-person project, so no response times are promised, but reports are looked at before the next release.
