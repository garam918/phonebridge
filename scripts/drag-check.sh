#!/bin/zsh
# Android → Finder drag check (D45) on a real device.
#
# Usage: scripts/drag-check.sh <drop folder> <volume path> <test folder name>
#
# Compares what was dragged from PhoneBridge into <drop folder> with the same
# items read through the mounted PhoneBridge volume ("<volume>/<test folder>"),
# an independent read path. Only items that also exist in the test folder are
# named; anything else in the drop folder is only counted. Reads only.
set -u
DROP="${1:?drop folder}"; VOL="${2:?volume path}"; NAME="${3:?test folder name}"
[[ -d "$DROP" ]] || { echo "no drop folder at $DROP"; exit 2; }
[[ -d "$VOL" ]] || { echo "no volume at $VOL (start the app with Finder integration, see docs/TEST_PLAN.md 6-1)"; exit 2; }
[[ "$NAME" != */* && "$NAME" != "." && "$NAME" != ".." ]] || { echo "bad folder name"; exit 2; }
T="$VOL/$NAME"
[[ -d "$T" ]] || { echo "no test folder at $T"; exit 2; }
pass=0; fail=0; other=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }
hash() { shasum -a 256 "$1" | cut -c1-16; }
size() { stat -f %z "$1"; }

compare_file() {  # <relative path>
  local d="$DROP/$1" s="$T/$1"
  if [[ ! -f "$s" ]]; then bad "$1: missing on the device side"; return; fi
  if [[ "$(size "$d")" != "$(size "$s")" ]]; then bad "$1: size $(size "$d") ≠ $(size "$s")"; return; fi
  local hd hs; hd=$(hash "$d"); hs=$(hash "$s")
  if [[ "$hd" == "$hs" ]]; then ok "$1 ($(size "$d") bytes, $hd)"; else bad "$1: hash $hd ≠ $hs"; fi
}

echo "== Drag check: $DROP  vs  $T  ($(date '+%Y-%m-%d %H:%M:%S'))"
for top in "$DROP"/*(N) "$DROP"/.*(N); do
  rel="${top#$DROP/}"
  [[ "$rel" == ".DS_Store" ]] && continue
  if [[ ! -e "$T/$rel" ]]; then other=$((other+1)); continue; fi
  if [[ -d "$top" ]]; then
    [[ -d "$T/$rel" ]] || { bad "$rel: folder here, file on the device"; continue; }
    want=$(cd "$T" && find "$rel" -not -name '.DS_Store' -not -name '._*' | sort)
    have=$(cd "$DROP" && find "$rel" -not -name '.DS_Store' -not -name '._*' | sort)
    if [[ "$want" == "$have" ]]; then ok "$rel/ tree ($(echo "$have" | wc -l | tr -d ' ') entries)"; else bad "$rel/ tree differs"; fi
    while IFS= read -r f; do compare_file "$f"; done < <(cd "$DROP" && find "$rel" -type f -not -name '.DS_Store' -not -name '._*' | sort)
  else
    compare_file "$rel"
  fi
done

clippings=$(find "$DROP" -name '*.textClipping' | wc -l | tr -d ' ')
[[ "$clippings" == 0 ]] && ok "no text clippings (Finder took the file, not the in-app text)" || bad "$clippings text clipping(s): Finder took the text payload"
partial=$(find "$DROP" -name '.phonebridge-*' -o -name '*.download' | wc -l | tr -d ' ')
[[ "$partial" == 0 ]] && ok "no partial files" || bad "$partial partial file(s)"
[[ $other -gt 0 ]] && echo "note  $other item(s) not from the test folder (not inspected)"
echo "== $pass passed, $fail failed"
[[ $fail == 0 ]]
