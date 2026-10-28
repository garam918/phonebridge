#!/bin/zsh
# Release build → (Developer ID signing → notarization) → DMG.
#
# Usage: scripts/release.sh <TEAM_ID> [notarytool keychain profile]
#
# Distribution outside the Mac App Store needs a "Developer ID Application"
# certificate (created by the team's Account Holder) and notarization. PhoneBridge
# cannot use the Mac App Store: its unmount helper runs outside the sandbox (D32).
#
# Without a Developer ID certificate the script still builds a Release DMG
# signed with "Apple Development" so the packaging can be tested on this Mac,
# names it "-NOT-FOR-DISTRIBUTION" and stops before notarization. Such a DMG
# does not open on other Macs (Gatekeeper); nothing here weakens that.
#
# Notarization credentials are never passed on the command line: create a
# keychain profile once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAM_ID>
# and pass the profile name.
set -euo pipefail
TEAM="${1:?usage: $0 <TEAM_ID> [notary profile]}"
PROFILE="${2:-}"
cd "$(dirname "$0")/.."

MIN_MACOS=15.0
VERSION=$(grep -m1 "MARKETING_VERSION" PhoneBridge.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
# Outside the repository: when it sits in an iCloud-synced folder (Documents),
# the File Provider adds Finder metadata to the bundle and strict code-signature
# verification (and notarization) fails.
OUT="${PB_RELEASE_DIR:-$HOME/Library/Developer/PhoneBridge/release}/$VERSION-$BUILD_NUMBER"
ARCHIVE="$OUT/PhoneBridge.xcarchive"
mkdir -p "$OUT"

DEVELOPER_ID=$(security find-identity -v -p codesigning | grep -c "Developer ID Application: .*($TEAM)" || true)
if [[ "$DEVELOPER_ID" -gt 0 ]]; then
  METHOD=developer-id
  echo "Developer ID Application certificate found: building for distribution."
else
  METHOD=debugging
  echo "No 'Developer ID Application' certificate for team $TEAM in the keychain."
  echo "Building a Release DMG for local packaging tests only (not distributable)."
fi

echo "== source checks"
python3 scripts/check-localization.py
python3 scripts/check-log-privacy.py

# Always rebuilt from the pinned, SHA-256-verified sources: Vendor/native is
# local, unversioned state, and whatever is there gets signed with Developer ID
# and notarized (audit 2026-10-23, M14).
echo "== native libraries (rebuilt from verified sources)"
scripts/build-native-deps.sh --force

echo "== archive (Release)"
xcodebuild -project PhoneBridge.xcodeproj -scheme PhoneBridge -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  PB_APP_ENTITLEMENTS=Config/PhoneBridge.entitlements \
  PB_FINDER_ENTITLEMENTS=Config/PhoneBridgeFinder.entitlements \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  PB_BUNDLE_SUFFIX= PB_DISPLAY_NAME=PhoneBridge PB_FS_SHORT_NAME=phonebridge \
  archive >"$OUT/archive.log" 2>&1 || { grep -E "error:" "$OUT/archive.log" | head -20; echo "archive failed ($OUT/archive.log)"; exit 1; }

echo "== export ($METHOD)"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>$METHOD</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates >"$OUT/export.log" 2>&1 \
  || { grep -E "error:" "$OUT/export.log" | head -20; echo "export failed ($OUT/export.log)"; exit 1; }
APP="$OUT/export/PhoneBridge.app"

echo "== verify"
codesign --verify --deep --strict "$APP" || { echo "strict signature verification failed"; exit 1; }
echo "signature: valid (strict)"
LAUNCHER="$APP/Contents/Library/LoginItems/PhoneBridgeLauncher.app"
[[ -d "$LAUNCHER" ]] || { echo "  ERROR: login-item launcher missing (D73)"; exit 1; }
for bundle in "$APP" "$APP/Contents/Extensions/PhoneBridgeFinder.appex" "$APP/Contents/XPCServices/PhoneBridgeUnmounter.xpc" \
              "$LAUNCHER" "$APP/Contents/Frameworks/libmtp.9.dylib" "$APP/Contents/Frameworks/libusb-1.0.0.dylib"; do
  flags=$(codesign -dv "$bundle" 2>&1 | grep -o "flags=[^ ]*" || true)
  authority=$(codesign -dvv "$bundle" 2>&1 | grep -m1 "Authority=" | sed 's/Authority=//' || true)
  echo "  ${bundle#$APP/}: $flags, $authority"
done
for bundle in "$APP" "$APP/Contents/Extensions/PhoneBridgeFinder.appex" "$APP/Contents/XPCServices/PhoneBridgeUnmounter.xpc" "$LAUNCHER"; do
  if codesign -d --entitlements - "$bundle" 2>/dev/null | grep -q "get-task-allow"; then
    echo "  ERROR: get-task-allow (debug entitlement) in ${bundle#$APP/}; notarization would reject it."
    exit 1
  fi
done
# Minimum macOS: the app, its libraries and the helper run on 15; the Finder
# extension needs 26 (FSKit URL resources) and is simply not used before that.
check_minos() {  # <binary> <expected>
  local actual; actual=$(vtool -show-build "$1" | awk '/minos/ {print $2; exit}')
  echo "  ${1#$APP/}: minos $actual"
  [[ "$actual" == "$2" ]] || { echo "  ERROR: expected minos $2"; exit 1; }
}
check_minos "$APP/Contents/MacOS/PhoneBridge" "$MIN_MACOS"
check_minos "$APP/Contents/XPCServices/PhoneBridgeUnmounter.xpc/Contents/MacOS/PhoneBridgeUnmounter" "$MIN_MACOS"
check_minos "$LAUNCHER/Contents/MacOS/PhoneBridgeLauncher" "$MIN_MACOS"
for lib in "$APP/Contents/Frameworks/"*.dylib; do check_minos "$lib" "$MIN_MACOS"; done
check_minos "$APP/Contents/Extensions/PhoneBridgeFinder.appex/Contents/MacOS/PhoneBridgeFinder" 26.0
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == "$MIN_MACOS" ]] \
  || { echo "  ERROR: LSMinimumSystemVersion is not $MIN_MACOS"; exit 1; }
otool -L "$APP/Contents/MacOS/PhoneBridge" | grep -q "FSKit.framework.*weak" \
  || { echo "  ERROR: FSKit must be weak-linked (absent before macOS 15.4)"; exit 1; }
[[ "$(lipo -archs "$APP/Contents/MacOS/PhoneBridge")" == arm64 ]] || { echo "  ERROR: expected arm64 only"; exit 1; }
echo "  minimum macOS $MIN_MACOS, Apple Silicon (arm64): OK"

NAME="PhoneBridge-$VERSION"
if [[ "$METHOD" == developer-id ]]; then
  [[ -n "$PROFILE" ]] || { echo "Pass a notarytool keychain profile to notarize (see the header)."; exit 1; }
  echo "== notarize app"
  ditto -c -k --keepParent "$APP" "$OUT/PhoneBridge.zip"
  xcrun notarytool submit "$OUT/PhoneBridge.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
else
  NAME="$NAME-NOT-FOR-DISTRIBUTION"
fi

echo "== DMG"
STAGE="$OUT/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PhoneBridge.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.md "$STAGE/설치 및 제거 (Install).md"
cp docs/LICENSES.md "$STAGE/Licenses.md"
DMG="$OUT/$NAME.dmg"
hdiutil create -volname "PhoneBridge $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
if [[ "$METHOD" == developer-id ]]; then
  codesign --sign "Developer ID Application" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "DMG: $DMG"
if [[ "$METHOD" == developer-id ]]; then
  # Fixed names for ".../releases/latest/download/PhoneBridge.dmg" (install.sh).
  cp "$DMG" "$OUT/PhoneBridge.dmg"
  (cd "$OUT" && shasum -a 256 PhoneBridge.dmg > PhoneBridge.dmg.sha256)
  cp scripts/install.sh "$OUT/install.sh"
  echo "Upload: $(basename "$DMG"), $(basename "$DMG").sha256, PhoneBridge.dmg, PhoneBridge.dmg.sha256, install.sh"
  echo "Then:   scripts/publish-metadata.sh --repo <owner/name> --release-dir \"$OUT\""
else
  echo "Not distributable: no Developer ID certificate, not notarized."
fi
