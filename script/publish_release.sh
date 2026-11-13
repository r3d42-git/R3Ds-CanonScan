#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source script/version.sh
DRY_RUN=false
if [[ "${1:-}" == --dry-run ]]; then DRY_RUN=true; shift; fi
[[ $# -eq 1 && "$1" == "$CANONSCAN_VERSION" ]] || { echo 'Usage: publish_release.sh [--dry-run] VERSION' >&2; exit 2; }
VERSION="$1"
TAG="v$VERSION"
[[ "$(git branch --show-current)" == main && -z "$(git status --porcelain)" ]]
[[ "$(gh repo view --json nameWithOwner --jq .nameWithOwner)" == "$CANONSCAN_REPOSITORY" ]]
OUT="$ROOT/dist/release/$VERSION"
[[ "$(cat "$OUT/source-commit.txt")" == "$(git rev-parse HEAD)" ]]
ZIP="$OUT/R3Ds-CanonScan-$VERSION-macOS-arm64.zip"
SOURCE="$OUT/R3Ds-CanonScan-$VERSION-backend-sources.tar.gz"
./script/verify_release.sh "$VERSION" "$ZIP"
if git rev-parse --verify "$TAG" >/dev/null 2>&1; then
  [[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]]
fi
if gh release view "$TAG" --repo "$CANONSCAN_REPOSITORY" >/dev/null 2>&1; then
  echo 'Release already exists; refusing to replace published assets.' >&2; exit 1
fi
if $DRY_RUN; then echo "Ready to publish $CANONSCAN_REPOSITORY $TAG"; exit 0; fi
git push --set-upstream origin main
if ! git rev-parse --verify "$TAG" >/dev/null 2>&1; then git tag -a "$TAG" -m "R3Ds CanonScan $VERSION"; fi
git push origin "$TAG"
gh release create "$TAG" --repo "$CANONSCAN_REPOSITORY" --verify-tag --title "R3Ds CanonScan $VERSION" --notes-file "docs/releases/$TAG.md" "$ZIP" "$ZIP.sha256" "$SOURCE" "$SOURCE.sha256"
DOWNLOAD="$(mktemp -d /private/tmp/canonscan-public-download.XXXXXX)"
echo "Independent download retained at $DOWNLOAD"
gh release download "$TAG" --repo "$CANONSCAN_REPOSITORY" --dir "$DOWNLOAD" --pattern "$(basename "$ZIP")*" --pattern "$(basename "$SOURCE")*"
for ASSET in "$ZIP" "$ZIP.sha256" "$SOURCE" "$SOURCE.sha256"; do cmp "$ASSET" "$DOWNLOAD/$(basename "$ASSET")"; done
gh api "repos/$CANONSCAN_REPOSITORY/releases/tags/$TAG" > "$DOWNLOAD/release.json"
python3 - "$DOWNLOAD" <<'PY'
import hashlib, json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
release = json.loads((directory / 'release.json').read_text())
assert not release['draft'] and not release['prerelease']
for asset in release['assets']:
    path = directory / asset['name']
    assert path.is_file(), asset['name']
    digest = asset.get('digest')
    assert digest == 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest(), asset['name']
print(release['html_url'])
PY
./script/verify_release.sh "$VERSION" "$DOWNLOAD/$(basename "$ZIP")"
