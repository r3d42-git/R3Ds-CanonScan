#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source script/version.sh
[[ $# -eq 1 && "$1" == "$CANONSCAN_VERSION" ]] || { echo 'Usage: release.sh VERSION (must match script/version.sh)' >&2; exit 2; }
VERSION="$1"
./script/test_release_guards.sh
[[ "$(git branch --show-current)" == main ]] || { echo 'Release assertion failed (release.sh:8)' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit the reviewed source before releasing.' >&2; exit 1; }
IDENTITY="${CODE_SIGN_IDENTITY:-D548540E7FE1BD9B3C4518CC02D8786E1BFEB885}"
PROFILE="${MACOS_NOTARY_PROFILE:-ToolBoxS}"
IDENTITIES="$(security find-identity -v -p codesigning)"
[[ "$IDENTITIES" == *"$IDENTITY"* ]] || { echo 'Developer ID identity unavailable.' >&2; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null
OUT="$ROOT/dist/release/$VERSION"
[[ ! -e "$OUT" ]] || { echo "Inspect existing release output before retrying: $OUT" >&2; exit 1; }
export CLANG_MODULE_CACHE_PATH="$ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.cache/swift"
swift test -c release --disable-sandbox
mkdir -p "$OUT"
git rev-parse HEAD > "$OUT/source-commit.txt"
APP="$OUT/$CANONSCAN_APP_NAME.app"
CODE_SIGN_IDENTITY="$IDENTITY" ./script/build_app.sh release "$APP"
codesign --verify --deep --strict -R "=anchor apple generic and certificate leaf[subject.OU] = \"$CANONSCAN_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$APP"
./script/package_backend_sources.sh "$VERSION"
SOURCE="R3Ds-CanonScan-$VERSION-backend-sources.tar.gz"
mv "$ROOT/dist/release/$SOURCE" "$OUT/$SOURCE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/submission.zip"
xcrun notarytool submit "$OUT/submission.zip" --keychain-profile "$PROFILE" --wait --timeout 30m --output-format json > "$OUT/notary-result.json" || { cat "$OUT/notary-result.json"; exit 1; }
cat "$OUT/notary-result.json"
ID="$(plutil -extract id raw -o - "$OUT/notary-result.json")"
xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "$OUT/notary-log.json"
[[ "$(plutil -extract status raw -o - "$OUT/notary-result.json")" == Accepted ]] || { echo 'Release assertion failed (release.sh:33)' >&2; exit 1; }
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ZIP="$OUT/R3Ds-CanonScan-$VERSION-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
for ASSET in "$ZIP" "$OUT/$SOURCE"; do
  (cd "$OUT" && shasum -a 256 "$(basename "$ASSET")") > "$ASSET.sha256"
done
./script/verify_release.sh "$VERSION" "$ZIP"
