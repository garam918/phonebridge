#!/bin/bash
# PhoneBridge installer for Terminal (macOS 15+, Apple Silicon).
#
#   curl -fsSL <PHONEBRIDGE_BASE_URL>/install.sh | bash
#   bash install.sh                      # latest release
#   bash install.sh --dmg PhoneBridge-1.0.0.dmg   # a DMG you already have
#   bash install.sh --check              # verify only, install nothing
#   bash install.sh --uninstall [--zap]  # remove (--zap: settings and caches too)
#
# Safety: a file downloaded with curl carries no quarantine flag, so macOS
# Gatekeeper would not check it at first launch. This script therefore does
# the same checks itself and refuses to install unless
#   - the disk image is signed with the PhoneBridge team's Developer ID and
#     notarized by Apple (checked before it is mounted),
#   - the app inside is signed with a valid Developer ID certificate of the
#     PhoneBridge team and notarized by Apple (spctl assessment, stapled ticket),
#   - and the DMG matches its published SHA-256 (downloads; detects corruption).
# It never disables Gatekeeper, never removes quarantine flags and never uses
# sudo by itself. Written for macOS's bash 3.2.
set -euo pipefail

BASE_URL="${PHONEBRIDGE_BASE_URL:-https://github.com/garam918/phonebridge/releases/latest/download}"
DMG_NAME="PhoneBridge.dmg"
TEAM_ID="KB2PLX99H6"
BUNDLE_ID="com.phonebridge.PhoneBridge"
MIN_MACOS="15.0"
APP_NAME="PhoneBridge.app"
# A Developer ID Application certificate issued by Apple to the PhoneBridge
# team: the Developer ID CA intermediate and the Developer ID leaf OIDs plus
# the team. Checked on the disk image and on the app inside it.
DEVELOPER_ID_REQUIREMENT="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$TEAM_ID\""
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

dmg=""
mode="install"
zap=0
dest_dir="/Applications"

search_dirs="/Applications $HOME/Applications"

usage() {
  say "PhoneBridge installer (macOS $MIN_MACOS+, Apple Silicon)"
  say "  install.sh                      install or update the latest release"
  say "  install.sh --dmg <file|URL>     install from a given DMG"
  say "  install.sh --check              verify the download only, install nothing"
  say "  install.sh --user               install into ~/Applications (no admin rights)"
  say "  install.sh --uninstall [--zap]  remove PhoneBridge (--zap: settings and caches too)"
}
say() { printf '%s\n' "$*"; }
die() { printf 'PhoneBridge 설치 중단 / install stopped: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dmg) dmg="${2:?--dmg needs a file or URL}"; shift 2 ;;
    --check) mode="check"; shift ;;
    --uninstall) mode="uninstall"; shift ;;
    --zap) zap=1; shift ;;
    --user) dest_dir="$HOME/Applications"; shift ;;
    --dir) dest_dir="${2:?--dir needs a folder}"; search_dirs="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

# --- requirements ---------------------------------------------------------

version_at_least() {  # <have> <need>, dotted numbers
  awk -v have="$1" -v need="$2" 'BEGIN {
    n = split(have, h, "."); m = split(need, w, ".");
    for (i = 1; i <= (n > m ? n : m); i++) { a = h[i] + 0; b = w[i] + 0;
      if (a > b) exit 0; if (a < b) exit 1 }
    exit 0 }'
}

check_mac() {
  [ "$(uname -s)" = "Darwin" ] || die "macOS가 아닙니다 / not macOS"
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]; then
    die "Apple Silicon(M1 이상) Mac이 필요합니다 / needs an Apple Silicon Mac (M1 or later)"
  fi
  local os; os="$(sw_vers -productVersion)"
  version_at_least "$os" "$MIN_MACOS" \
    || die "macOS $MIN_MACOS 이상이 필요합니다(현재 $os) / needs macOS $MIN_MACOS or later (this Mac: $os)"
  say "Mac: Apple Silicon, macOS $os"
}

# --- verification ---------------------------------------------------------

verify_app() {  # <path to PhoneBridge.app>
  local app="$1" info team auth
  [ -d "$app" ] || die "$APP_NAME not found in the disk image"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] \
    || die "unexpected bundle identifier"
  codesign --verify --deep --strict "$app" 2>/dev/null || die "서명이 올바르지 않습니다 / invalid code signature"
  info="$(codesign -dv --verbose=2 "$app" 2>&1)"
  team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p')"
  [ "$team" = "$TEAM_ID" ] || die "다른 개발자의 서명입니다($team) / signed by another team ($team)"
  auth="$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)"
  case "$auth" in
    "Developer ID Application:"*) ;;
    *) die "배포용(Developer ID) 서명이 아닙니다: $auth / not a Developer ID signature" ;;
  esac
  # The certificate chain itself, not only the text above: a Developer ID
  # Application leaf issued by Apple for this team.
  codesign --verify --deep --strict -R="$DEVELOPER_ID_REQUIREMENT" "$app" 2>/dev/null \
    || die "배포용(Developer ID) 서명이 아닙니다 / not a Developer ID signature from team $TEAM_ID"
  spctl --assess --type execute "$app" 2>/dev/null \
    || die "Apple 공증(notarization)을 확인할 수 없습니다 / not notarized by Apple"
  xcrun stapler validate -q "$app" 2>/dev/null || say "note: no stapled ticket (Gatekeeper checked online)"
  say "verified: Developer ID ($TEAM_ID), notarized"
}

# --- LaunchServices -------------------------------------------------------

# Copies outside the install location (the opened disk image, the old app in
# the Trash) must not stay registered with LaunchServices: macOS may pick
# their Finder extension instead of the installed one, and mounting then fails
# (docs/KNOWN_ISSUES.md K44). Only the registration goes; files are untouched.
forget_copy() {  # <path to PhoneBridge.app>
  [ -x "$LSREGISTER" ] || return 0
  "$LSREGISTER" -u "$1/Contents/Extensions/PhoneBridgeFinder.appex" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$1/Contents/Library/LoginItems/PhoneBridgeLauncher.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$1" >/dev/null 2>&1 || true
}

# "휴대전화를 연결하면 PhoneBridge 열기" (D73): its login item keeps running from
# the removed copy until logout. On uninstall it is stopped; after an update
# the new app registers its own launcher when it first opens (D79).
stop_launcher() {
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID.Launcher" >/dev/null 2>&1 || true
}

# The disk image itself, before it is handed to the kernel: release.sh signs
# and notarizes the DMG with the same Developer ID, and the checksum alone
# cannot tell a substituted image from the real one (it is served from the
# same place). Only an image that passes is mounted (audit 2026-10-28, M3).
verify_dmg() {  # <path to .dmg>
  codesign --verify -R="$DEVELOPER_ID_REQUIREMENT" "$1" 2>/dev/null \
    || die "디스크 이미지의 서명이 올바르지 않습니다(PhoneBridge 팀의 Developer ID 서명이 아님) / the disk image is not signed with the PhoneBridge team's Developer ID"
  spctl --assess --type open --context context:primary-signature "$1" 2>/dev/null \
    || die "디스크 이미지의 Apple 공증(notarization)을 확인할 수 없습니다 / the disk image is not notarized by Apple"
  say "disk image verified: Developer ID ($TEAM_ID), notarized"
}

# --- download / mount -----------------------------------------------------

work="$(mktemp -d "${TMPDIR:-/tmp}/phonebridge-install.XXXXXX")"
mount_point=""
cleanup() {
  if [ -n "$mount_point" ]; then
    forget_copy "$mount_point/$APP_NAME"
    hdiutil detach -quiet "$mount_point" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

fetch_dmg() {
  local source="$dmg"
  if [ -z "$source" ]; then source="$BASE_URL/$DMG_NAME"; fi
  case "$source" in
    https://*)
      say "downloading $source"
      curl -fL --proto '=https' --tlsv1.2 --retry 2 -o "$work/$DMG_NAME" "$source" || die "download failed"
      curl -fsSL --proto '=https' --tlsv1.2 -o "$work/$DMG_NAME.sha256" "$source.sha256" \
        || die "체크섬 파일을 받을 수 없습니다 / no checksum at $source.sha256"
      local want have
      want="$(awk '{print $1; exit}' "$work/$DMG_NAME.sha256")"
      have="$(shasum -a 256 "$work/$DMG_NAME" | awk '{print $1}')"
      [ -n "$want" ] && [ "$want" = "$have" ] || die "체크섬 불일치 / SHA-256 mismatch"
      say "checksum OK ($have)"
      dmg="$work/$DMG_NAME" ;;
    http://*) die "https only" ;;
    *)
      [ -f "$source" ] || die "no such file: $source"
      if [ -f "$source.sha256" ]; then
        [ "$(awk '{print $1; exit}' "$source.sha256")" = "$(shasum -a 256 "$source" | awk '{print $1}')" ] \
          || die "체크섬 불일치 / SHA-256 mismatch"
        say "checksum OK"
      fi
      dmg="$source" ;;
  esac
}

mount_dmg() {
  mount_point="$work/mnt"
  mkdir -p "$mount_point"
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount_point" "$dmg" || {
    mount_point=""
    die "디스크 이미지를 열 수 없습니다 / cannot open the disk image"
  }
}

quit_app() {
  if pgrep -qx PhoneBridge; then
    say "quitting PhoneBridge (finishes or cancels transfers, unmounts its Finder volumes)"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    local i=0
    while pgrep -qx PhoneBridge && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
    pgrep -qx PhoneBridge && die "PhoneBridge가 종료되지 않았습니다. 직접 종료한 뒤 다시 실행하세요 / quit PhoneBridge and run again"
  fi
  return 0
}

move_to_trash() {  # <path>
  [ -e "$1" ] || return 0
  local target="$HOME/.Trash/$(basename "$1") $(date +%Y%m%d-%H%M%S)-$$"
  if [ ! -e "$target" ] && mv "$1" "$target" 2>/dev/null; then
    case "$target" in *.app*) forget_copy "$target" ;; esac
    say "moved to Trash: $1"
    return 0
  fi
  say "could not remove $1 — remove it in Finder (⇧⌘G, then move to Trash)"
}

# --- modes ----------------------------------------------------------------

install_app() {
  check_mac
  fetch_dmg
  verify_dmg "$dmg"
  mount_dmg
  verify_app "$mount_point/$APP_NAME"
  [ "$mode" = "check" ] && { say "check only: nothing installed"; return 0; }

  mkdir -p "$dest_dir"
  [ -w "$dest_dir" ] || die "$dest_dir에 쓸 수 없습니다. 관리자 계정으로 실행하거나 --user(~/Applications)를 쓰세요 / $dest_dir is not writable; use an admin account or --user"
  quit_app
  local staged="$dest_dir/.$APP_NAME.installing"
  rm -rf "$staged"
  ditto "$mount_point/$APP_NAME" "$staged"
  verify_app "$staged"
  if [ -d "$dest_dir/$APP_NAME" ]; then move_to_trash "$dest_dir/$APP_NAME"; fi
  # The staged path is not passed to forget_copy: LaunchServices follows the
  # moved bundle, so that would unregister the installed app itself. Its Finder
  # extension is registered when the app first runs.
  mv "$staged" "$dest_dir/$APP_NAME"
  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dest_dir/$APP_NAME/Contents/Info.plist")"
  say ""
  say "PhoneBridge $version 설치 완료 / installed: $dest_dir/$APP_NAME"
  say "열기 / open:  open -a \"$dest_dir/$APP_NAME\""
  if version_at_least "$(sw_vers -productVersion)" "26.0"; then
    say "Finder 연결: 설정 › Finder에서 켜고, 시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램 › 파일 시스템 확장에서 'PhoneBridge Finder'를 켜세요."
    say "Finder: turn it on in Settings › Finder and enable 'PhoneBridge Finder' in System Settings › General › Login Items & Extensions › File System Extensions."
  else
    say "Finder 연결은 macOS 26 이상에서 사용할 수 있습니다 / Finder integration needs macOS 26 or later."
  fi
}

uninstall_app() {
  quit_app
  stop_launcher
  local found=0 dir
  for dir in $search_dirs; do
    if [ -d "$dir/$APP_NAME" ]; then move_to_trash "$dir/$APP_NAME"; found=1; fi
  done
  [ $found -eq 1 ] || say "PhoneBridge.app not found in /Applications or ~/Applications"
  if [ $zap -eq 1 ]; then
    move_to_trash "$HOME/Library/Containers/$BUNDLE_ID"
    move_to_trash "$HOME/Library/Containers/$BUNDLE_ID.FinderVolume"
    move_to_trash "$HOME/Library/Containers/$BUNDLE_ID.Launcher"
    move_to_trash "$HOME/Library/Group Containers/group.com.phonebridge.shared"
  fi
  say "제거 완료 / removed. 휴대전화에는 설치된 것이 없습니다 / nothing was installed on the phone."
}

case "$mode" in
  install|check) install_app ;;
  uninstall) uninstall_app ;;
esac
