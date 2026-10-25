#!/bin/zsh
# Fills in the release details for the Terminal installers after
# scripts/release.sh built a notarized DMG:
#   - packaging/homebrew/Casks/phonebridge.rb: version, sha256, repository
#   - scripts/install.sh: default download location (repository)
#
# Usage: scripts/publish-metadata.sh --repo <owner/name> --release-dir <dir>
#
# Uploading is left to you (GitHub Releases: tag v<version>, attach the files
# release.sh listed). Then push the cask to your tap repository
# (<owner>/homebrew-phonebridge, folder Casks/), so users can run
#   brew install --cask <owner>/phonebridge/phonebridge
set -euo pipefail
cd "$(dirname "$0")/.."

repo=""; dir=""
while (( $# )); do
  case "$1" in
    --repo) repo="${2:?}"; shift 2 ;;
    --release-dir) dir="${2:?}"; shift 2 ;;
    *) echo "usage: $0 --repo <owner/name> --release-dir <dir>"; exit 2 ;;
  esac
done
[[ "$repo" == */* && "$repo" != */*/* ]] || { echo "--repo must look like owner/name"; exit 2; }
[[ -d "$dir" ]] || { echo "no release folder: $dir"; exit 2; }

dmg=( "$dir"/PhoneBridge-*.dmg(N) )
(( ${#dmg} == 1 )) || { echo "expected one PhoneBridge-<version>.dmg in $dir"; exit 1; }
dmg=${dmg[1]}
[[ "$dmg" != *NOT-FOR-DISTRIBUTION* ]] || { echo "refusing: $dmg is not a distributable (notarized) build"; exit 1; }
version=${${dmg:t}#PhoneBridge-}; version=${version%.dmg}
sum=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null \
  || { echo "refusing: $dmg does not pass Gatekeeper (not notarized?)"; exit 1; }

cask=packaging/homebrew/Casks/phonebridge.rb
sed -i '' -E \
  -e "s|^  version \".*\"|  version \"$version\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$sum\"|" \
  -e "s|github.com/[^/]+/[^/]+/releases|github.com/$repo/releases|" \
  -e "s|homepage \"https://github.com/[^\"]+\"|homepage \"https://github.com/$repo\"|" \
  "$cask"
sed -i '' -E "s|^BASE_URL=\"\\\$\\{PHONEBRIDGE_BASE_URL:-[^}]*\\}\"|BASE_URL=\"\${PHONEBRIDGE_BASE_URL:-https://github.com/$repo/releases/latest/download}\"|" scripts/install.sh
cp scripts/install.sh "$dir/install.sh"

echo "version $version, sha256 $sum"
grep -nE '^  (version|sha256|url)|homepage' "$cask"
grep -n '^BASE_URL=' scripts/install.sh
echo "Terminal install after upload:"
echo "  curl -fsSL https://github.com/$repo/releases/latest/download/install.sh | bash"
echo "  brew install --cask ${repo%%/*}/phonebridge/phonebridge   (after pushing $cask to ${repo%%/*}/homebrew-phonebridge)"
