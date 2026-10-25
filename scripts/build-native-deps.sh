#!/bin/zsh
# Builds libusb and libmtp from pinned upstream sources as dynamic libraries
# for Apple Silicon, macOS 15 and later, into Vendor/native.
#
# Why not Homebrew's copies: Homebrew bottles are built for the Mac they are
# installed on (here macOS 27), and PhoneBridge supports macOS 15. Dynamic
# libraries are embedded in PhoneBridge.app/Contents/Frameworks so they can be
# replaced, as the LGPL-2.1 asks (docs/LICENSES.md).
#
# Sources are verified with the SHA-256 Homebrew pins for the same versions.
# A copy already in Homebrew's download cache is used when present.
#
# Usage: scripts/build-native-deps.sh [--force]
set -euo pipefail
cd "$(dirname "$0")/.."

LIBUSB_VERSION=1.0.30
LIBUSB_URL="https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2"
LIBUSB_SHA256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
LIBMTP_VERSION=1.1.23
LIBMTP_URL="https://downloads.sourceforge.net/project/libmtp/libmtp/$LIBMTP_VERSION/libmtp-$LIBMTP_VERSION.tar.gz"
LIBMTP_SHA256=74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed
DEPLOYMENT_TARGET=15.0  # keep in step with MACOSX_DEPLOYMENT_TARGET (app)

PREFIX="$PWD/Vendor/native"
WORK="$PWD/Vendor/build"
SOURCES="$PWD/Vendor/sources"

if [[ "${1:-}" != "--force" && -f "$PREFIX/lib/libmtp.9.dylib" && -f "$PREFIX/lib/libusb-1.0.0.dylib" ]]; then
  echo "Vendor/native is already built (use --force to rebuild)."
  exit 0
fi
command -v pkg-config >/dev/null || { echo "pkg-config is needed: brew install pkgconf"; exit 1; }

# fetch <url> <sha256> <file name>: Homebrew cache first, then the URL.
fetch() {
  local url="$1" sum="$2" name="$3" target="$SOURCES/$3"
  mkdir -p "$SOURCES"
  if [[ ! -f "$target" ]]; then
    local cached=( "$HOME"/Library/Caches/Homebrew/downloads/*--"$name"(N) )
    if (( ${#cached} )); then cp "${cached[1]}" "$target"; else curl -fL --retry 2 -o "$target" "$url"; fi
  fi
  local actual; actual=$(shasum -a 256 "$target" | cut -d' ' -f1)
  [[ "$actual" == "$sum" ]] || { echo "SHA-256 mismatch for $name: $actual"; rm -f "$target"; exit 1; }
  echo "verified $name"
}

fetch "$LIBUSB_URL" "$LIBUSB_SHA256" "libusb-$LIBUSB_VERSION.tar.bz2"
fetch "$LIBMTP_URL" "$LIBMTP_SHA256" "libmtp-$LIBMTP_VERSION.tar.gz"

rm -rf "$WORK" "$PREFIX"
mkdir -p "$WORK" "$PREFIX"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export CFLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -O2"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -Wl,-headerpad_max_install_names"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
JOBS=$(sysctl -n hw.ncpu)

echo "building libusb $LIBUSB_VERSION"
tar -xjf "$SOURCES/libusb-$LIBUSB_VERSION.tar.bz2" -C "$WORK"
( cd "$WORK/libusb-$LIBUSB_VERSION" &&
  ./configure --prefix="$PREFIX" --disable-dependency-tracking --enable-shared --disable-static >"$WORK/libusb-configure.log" &&
  make -j"$JOBS" >"$WORK/libusb-make.log" && make install >"$WORK/libusb-install.log" )

echo "building libmtp $LIBMTP_VERSION"
tar -xzf "$SOURCES/libmtp-$LIBMTP_VERSION.tar.gz" -C "$WORK"
( cd "$WORK/libmtp-$LIBMTP_VERSION" &&
  ./configure --prefix="$PREFIX" --disable-dependency-tracking --disable-mtpz --disable-silent-rules \
    --with-udev="$WORK/udev" --enable-shared --disable-static >"$WORK/libmtp-configure.log" &&
  make -j"$JOBS" >"$WORK/libmtp-make.log" && make install >"$WORK/libmtp-install.log" )

# Embedded in the app: load through the app's rpath (Contents/Frameworks).
LIB="$PREFIX/lib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$LIB/libusb-1.0.0.dylib"
install_name_tool -id @rpath/libmtp.9.dylib "$LIB/libmtp.9.dylib"
install_name_tool -change "$LIB/libusb-1.0.0.dylib" @rpath/libusb-1.0.0.dylib "$LIB/libmtp.9.dylib"
codesign --force --sign - "$LIB/libusb-1.0.0.dylib" "$LIB/libmtp.9.dylib" 2>/dev/null

# License texts and authors travel with the libraries (app bundle, DMG).
mkdir -p "$PREFIX/licenses"
for pkg in "libusb-$LIBUSB_VERSION" "libmtp-$LIBMTP_VERSION"; do
  name=${pkg%%-*}
  iconv -f latin1 -t utf-8 "$WORK/$pkg/COPYING" > "$PREFIX/licenses/$name-COPYING.txt"
  cp "$WORK/$pkg/AUTHORS" "$PREFIX/licenses/$name-AUTHORS.txt"
done

# Keep only what the app needs; remove example binaries and docs.
rm -rf "$PREFIX/bin" "$PREFIX/share" "$LIB"/*.la(N)

cat > "$PREFIX/SOURCES.txt" <<EOF
libusb $LIBUSB_VERSION  LGPL-2.1-or-later
  source: $LIBUSB_URL
  sha256: $LIBUSB_SHA256
  configure: --enable-shared --disable-static
libmtp $LIBMTP_VERSION  LGPL-2.1-or-later
  source: $LIBMTP_URL
  sha256: $LIBMTP_SHA256
  configure: --disable-mtpz --enable-shared --disable-static
built for: arm64, macOS $DEPLOYMENT_TARGET+, by scripts/build-native-deps.sh
EOF

for lib in libusb-1.0.0.dylib libmtp.9.dylib; do
  echo "$lib: $(vtool -show-build "$LIB/$lib" | awk '/minos/ {print "minos " $2} /platform/ {print $2}' | tr '\n' ' ')"
  otool -L "$LIB/$lib" | tail -n +2 | sed 's/^/    /'
done
echo "Done: $PREFIX"
