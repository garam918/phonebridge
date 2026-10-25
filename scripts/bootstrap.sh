#!/bin/zsh
# Prepares the native dependencies PhoneBridge links against: libusb and
# libmtp, built from pinned sources into Vendor/native (macOS 26+, arm64,
# dynamic, embedded in the app). Needs Xcode's command line tools and
# pkg-config (brew install pkgconf); installs nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-native-deps.sh "$@"
echo "Build: xcodebuild -project PhoneBridge.xcodeproj -scheme PhoneBridge -destination 'platform=macOS,arch=arm64' build"
