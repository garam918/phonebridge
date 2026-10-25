#!/bin/zsh
# Finder write check (W5) on a mounted PhoneBridge volume.
#
# Usage: scripts/finder-write-check.sh <volume path> <test folder name> [big file MiB]
#
# Writes ONLY inside "<volume>/<test folder>" (created if missing) and reads
# back only what it wrote. Prints hashes, sizes and timings; never lists any
# other folder. The app must run with Finder writes allowed for this device
# (see docs/TEST_PLAN.md 4-2); the app itself refuses writes elsewhere when
# started with -diagnostics.finderWriteScope "<test folder>".
set -u
VOL="${1:?volume path}"; NAME="${2:?test folder name}"; BIG_MIB="${3:-1024}"
[[ -d "$VOL" ]] || { echo "no volume at $VOL"; exit 2; }
[[ "$NAME" != */* && "$NAME" != "." && "$NAME" != ".." ]] || { echo "bad folder name"; exit 2; }
T="$VOL/$NAME"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pbw5.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hash() { shasum -a 256 "$1" | cut -c1-16; }
now()  { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
finder() { osascript -e 'with timeout of 1800 seconds' -e "tell application \"Finder\" to $1" -e 'end timeout' >/dev/null 2>"$WORK/finder.err"; }

echo "== Finder write check: $T  ($(date '+%Y-%m-%d %H:%M:%S'))"
mkdir -p "$T" 2>"$WORK/err" || { echo "cannot create the test folder: $(cat "$WORK/err")"; exit 1; }
check "test folder exists" '[[ -d "$T" ]]'

# W1 small files (Korean / emoji names), cp and Finder
for f in "메모 1.txt" "사진 😀.dat" "plain.bin"; do head -c $((RANDOM * 7 + 1000)) /dev/urandom > "$WORK/$f"; done
cp "$WORK/메모 1.txt" "$T/" && cp "$WORK/plain.bin" "$T/"
finder "duplicate (POSIX file \"$WORK/사진 😀.dat\" as alias) to (POSIX file \"$T\" as alias)"
for f in "메모 1.txt" "사진 😀.dat" "plain.bin"; do
  check "W1 copy $f (hash)" '[[ "$(hash "$WORK/$f")" == "$(hash "$T/$f" 2>/dev/null)" ]]'
done

# W3 folder tree with an empty folder
mkdir -p "$WORK/트리/빈 폴더" "$WORK/트리/하위/깊은"; echo a > "$WORK/트리/a.txt"; echo b > "$WORK/트리/하위/깊은/b.txt"
finder "duplicate (POSIX file \"$WORK/트리\" as alias) to (POSIX file \"$T\" as alias)"
check "W3 tree structure" '[[ "$(cd "$T/트리" 2>/dev/null && find . | sort | tr "\n" " ")" == "$(cd "$WORK/트리" && find . | sort | tr "\n" " ")" ]]'
check "W3 nested content" '[[ "$(cat "$T/트리/하위/깊은/b.txt" 2>/dev/null)" == "b" ]]'

# W4 new folder and rename
mkdir "$T/새 폴더" && mv "$T/새 폴더" "$T/이름 바꾼 폴더"
check "W4 mkdir + rename" '[[ -d "$T/이름 바꾼 폴더" && ! -e "$T/새 폴더" ]]'

# W5 replace: Finder "Replace", cp over, append, atomic save (temp + rename over)
head -c 50000 /dev/urandom > "$WORK/v2"; mkdir -p "$WORK/replace"; cp "$WORK/v2" "$WORK/replace/메모 1.txt"
finder "duplicate (POSIX file \"$WORK/replace/메모 1.txt\" as alias) to (POSIX file \"$T\" as alias) with replacing"
check "W5 Finder replace" '[[ "$(hash "$T/메모 1.txt")" == "$(hash "$WORK/v2")" ]]'
head -c 3000 /dev/urandom > "$WORK/v3"; cp "$WORK/v3" "$T/plain.bin"
check "W5 cp over existing" '[[ "$(hash "$T/plain.bin")" == "$(hash "$WORK/v3")" ]]'
printf 'APPEND' >> "$T/plain.bin"; cat "$WORK/v3" > "$WORK/v3a"; printf 'APPEND' >> "$WORK/v3a"
check "W5 append" '[[ "$(hash "$T/plain.bin")" == "$(hash "$WORK/v3a")" ]]'
python3 - "$T/plain.bin" <<'EOF'
import os, sys
target = sys.argv[1]; tmp = target + ".sb-w5"
with open(tmp, "wb") as f: f.write(b"atomic save\n")
os.replace(tmp, target)
EOF
check "W5 atomic save" '[[ "$(cat "$T/plain.bin")" == "atomic save" ]]'
touch "$T/빈 파일.txt"; sleep 3
check "empty file created" '[[ -f "$T/빈 파일.txt" && $(stat -f %z "$T/빈 파일.txt") -eq 0 ]]'

# W7 move inside the volume
mv "$T/사진 😀.dat" "$T/이름 바꾼 폴더/"
check "W7 move" '[[ -f "$T/이름 바꾼 폴더/사진 😀.dat" && ! -e "$T/사진 😀.dat" ]]'
check "W7 moved content" '[[ "$(hash "$T/이름 바꾼 폴더/사진 😀.dat")" == "$(hash "$WORK/사진 😀.dat")" ]]'

# W2 + W12: big file through Finder; browse the test folder meanwhile
head -c $((BIG_MIB * 1048576)) /dev/urandom > "$WORK/big.bin"
start=$(now)
finder "duplicate (POSIX file \"$WORK/big.bin\" as alias) to (POSIX file \"$T\" as alias)" &
FP=$!
sleep 5
worst=0
while kill -0 $FP 2>/dev/null; do
  a=$(now); ls "$T/트리" >/dev/null 2>&1; b=$(now)
  worst=$(echo "if ($b - $a > $worst) $b - $a else $worst" | bc); sleep 5
done
wait $FP; rc=$?; end=$(now)
secs=$(echo "$end - $start" | bc)
echo "INFO  W2 ${BIG_MIB} MiB Finder copy: ${secs}s ($(echo "scale=1; $BIG_MIB / $secs" | bc) MiB/s), slowest listing during upload ${worst}s"
check "W2 big copy finished" '[[ $rc -eq 0 ]]'
check "W2 big file hash" '[[ "$(hash "$T/big.bin")" == "$(hash "$WORK/big.bin")" ]]'

# W10 not enough space on the device: refused at close, nothing uploaded
python3 - "$T/too-big.bin" "$VOL" <<'EOF' > "$WORK/nospace"
import os, sys
path, vol = sys.argv[1], sys.argv[2]
st = os.statvfs(vol); free = st.f_bavail * st.f_frsize
f = open(path, "wb"); f.truncate(free + (10 << 30))
try:
    f.close(); print("closed")
except OSError as e:
    print(e.errno)
EOF
check "W10 no space → ENOSPC at close" '[[ "$(cat "$WORK/nospace")" == "28" ]]'
rm -f "$T/too-big.bin"

# W6 deletes (file, folder tree)
rm "$T/빈 파일.txt" && rm -r "$T/트리"
check "W6 delete file and tree" '[[ ! -e "$T/빈 파일.txt" && ! -e "$T/트리" ]]'

echo "INFO  waiting 35 s for delayed deletes (D33) before the leftover check"
sleep 35
echo "== $pass passed, $fail failed"
echo "Next: remount and run the leftover check (TEST_PLAN 4-2 step 5)."
exit $(( fail > 0 ))
