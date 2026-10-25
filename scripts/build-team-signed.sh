#!/bin/zsh
# Builds PhoneBridge with a real development team, installs it to
# /Applications (or ~/Applications) and registers it, so FSKit sees the
# team-signed Finder module instead of an ad-hoc development build.
#
# Prerequisites (done by you, not by this script):
#   1. Xcode › Settings › Accounts: your team is signed in and has an
#      "Apple Development" certificate (Manage Certificates › +).
#   2. "com.phonebridge.PhoneBridge" (+ ".FinderVolume") and the App Group
#      "group.com.phonebridge.shared" can be registered under your team.
#
# Usage: scripts/build-team-signed.sh <TEAM_ID>
#
# -allowProvisioningUpdates lets Xcode create the App IDs, the App Group and
# development profiles in your Apple Developer account.
# -allowProvisioningDeviceRegistration registers this Mac (its provisioning
# UDID) in the account; development profiles only run on registered devices.
set -euo pipefail
TEAM="${1:?usage: $0 <TEAM_ID>}"
cd "$(dirname "$0")/.."

DERIVED="$HOME/Library/Developer/Xcode/DerivedData/PhoneBridge-TeamSigned"
APP_ID="com.phonebridge.PhoneBridge"
EXT_ID="$APP_ID.FinderVolume"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Higher than development builds, so this copy wins when both are registered.
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

xcodebuild -project PhoneBridge.xcodeproj -scheme PhoneBridge -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  PB_APP_ENTITLEMENTS=Config/PhoneBridge.entitlements \
  PB_FINDER_ENTITLEMENTS=Config/PhoneBridgeFinder.entitlements \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  PB_BUNDLE_SUFFIX= PB_DISPLAY_NAME=PhoneBridge PB_FS_SHORT_NAME=phonebridge \
  build | grep -E "error:|warning: .*provision|BUILD (SUCCEEDED|FAILED)" || true

BUILT="$DERIVED/Build/Products/Debug/PhoneBridge.app"
[[ -d "$BUILT" ]] || { echo "Build failed (no app produced)."; exit 1; }

DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST/PhoneBridge.app"
ditto "$BUILT" "$DEST/PhoneBridge.app"
INSTALLED="$DEST/PhoneBridge.app"

# Development builds use "<id>.dev" IDs and cannot clash, but older builds
# from before that change may still be registered: forget them.
for stale in "$HOME"/Library/Developer/Xcode/DerivedData/PhoneBridge-*/Build/Products/*/PhoneBridge.app(N); do
  [[ "$stale" == "$BUILT" ]] && continue
  "$LSREGISTER" -u "$stale" 2>/dev/null || true
done
"$LSREGISTER" -u "$BUILT" 2>/dev/null || true
rm -rf "$BUILT"   # the installed copy is the only one users should see
"$LSREGISTER" -f -R -trusted "$INSTALLED"

echo
echo "Installed: $INSTALLED (build $BUILD_NUMBER)"
for bundle in "$INSTALLED" "$INSTALLED/Contents/Extensions/PhoneBridgeFinder.appex"; do
  profile="$bundle/Contents/embedded.provisionprofile"
  if [[ -f "$profile" ]]; then
    groups=$(security cms -D -i "$profile" 2>/dev/null | grep -A3 "com.apple.security.application-groups" | grep -o "group\.[^<]*" | tr '\n' ' ' || true)
    groups="${groups:-none}"
    echo "  $(basename "$bundle"): profile OK, App Groups in profile: $groups"
  else
    echo "  $(basename "$bundle"): NO provisioning profile embedded"
  fi
done
codesign --verify --deep --strict "$INSTALLED" && echo "  signature: valid"
if ! security cms -D -i "$INSTALLED/Contents/embedded.provisionprofile" 2>/dev/null | grep -q "group.com.phonebridge.shared"; then
  echo "  WARNING: the App Group is not in the app's profile; macOS may refuse the app and the Finder module."
fi
echo
echo "Next: open $INSTALLED once, then enable 'PhoneBridge Finder' in"
echo "System Settings › General › Login Items & Extensions › File System Extensions,"
echo "and turn on Settings › Finder in PhoneBridge."
