#!/usr/bin/env bash
# Read-only verification of the exact distributable and its extracted contents.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/script/version.sh"
[[ $# -eq 2 && "$1" == "$CANONSCAN_VERSION" ]] || { echo 'Usage: verify_release.sh VERSION ZIP' >&2; exit 2; }
VERSION="$1"
ZIP="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
[[ "$(basename "$ZIP")" == "R3Ds-CanonScan-$VERSION-macOS-arm64.zip" ]] || { echo 'Release assertion failed (verify_release.sh:9)' >&2; exit 1; }
SOURCE="$ROOT/dist/release/$VERSION/R3Ds-CanonScan-$VERSION-backend-sources.tar.gz"
# Prefer the sources beside the supplied archive, including fresh downloads.
SOURCE="$(dirname "$ZIP")/$(basename "$SOURCE")"
for ASSET in "$ZIP" "$SOURCE"; do
  EXPECTED="$(awk 'NR==1 {print $1}' "$ASSET.sha256")"
  [[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || { echo 'Release assertion failed (verify_release.sh:15)' >&2; exit 1; }
  [[ "$(cat "$ASSET.sha256")" == "$EXPECTED  $(basename "$ASSET")" ]] || { echo 'Release assertion failed (verify_release.sh:16)' >&2; exit 1; }
  [[ "$(shasum -a 256 "$ASSET" | awk '{print $1}')" == "$EXPECTED" ]] || { echo "SHA-256 mismatch: $ASSET" >&2; exit 1; }
done
unzip -t "$ZIP" >/dev/null
VERIFY="$(mktemp -d /private/tmp/canonscan-release-verify.XXXXXX)"
trap 'rm -rf "$VERIFY"' EXIT
ditto -x -k "$ZIP" "$VERIFY"
APP="$VERIFY/$CANONSCAN_APP_NAME.app"
PLIST="$APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")" == "$CANONSCAN_BUNDLE_ID" ]] || { echo 'Release assertion failed (verify_release.sh:25)' >&2; exit 1; }
[[ "$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")" == "$CANONSCAN_APP_NAME" ]] || { echo 'Release assertion failed (verify_release.sh:26)' >&2; exit 1; }
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")" == "$VERSION" ]] || { echo 'Release assertion failed (verify_release.sh:27)' >&2; exit 1; }
[[ "$(plutil -extract CFBundleVersion raw -o - "$PLIST")" == "$CANONSCAN_BUILD" ]] || { echo 'Release assertion failed (verify_release.sh:28)' >&2; exit 1; }
[[ "$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" == "$CANONSCAN_MIN_MACOS" ]] || { echo 'Release assertion failed (verify_release.sh:29)' >&2; exit 1; }
REQUIREMENT="=anchor apple generic and certificate leaf[subject.OU] = \"$CANONSCAN_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
for BINARY in "$APP/Contents/MacOS/$CANONSCAN_EXECUTABLE" "$APP/Contents/Resources/scanimage" "$APP/Contents/Resources/scanbutton"; do
  [[ "$(lipo -archs "$BINARY")" == arm64 ]] || { echo 'Release assertion failed (verify_release.sh:32)' >&2; exit 1; }
  codesign --verify --strict -R "$REQUIREMENT" "$BINARY"
  SIGNATURE="$(codesign -dv --verbose=4 "$BINARY" 2>&1)"
  [[ "$SIGNATURE" == *'(runtime)'* && "$SIGNATURE" == *'Timestamp='* ]] || { echo 'Release assertion failed (verify_release.sh:35)' >&2; exit 1; }
  ENTITLEMENTS="$(codesign -d --entitlements :- "$BINARY" 2>/dev/null)"
  [[ -z "$ENTITLEMENTS" ]] || { echo 'Release assertion failed (verify_release.sh:37)' >&2; exit 1; }
  otool -L "$BINARY" > "$VERIFY/linkage.txt"
  awk 'NR>1 {if ($1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\//) exit 1}' "$VERIFY/linkage.txt"
done
codesign --verify --deep --strict -R "$REQUIREMENT" "$APP"
codesign -dv --verbose=4 "$APP" 2>&1
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
[[ "$(cat "$APP/Contents/Resources/sane.d/canon_dr.conf")" == $'option duplex-offset 260\nusb 0x1083 0x165f' ]] || { echo 'Release assertion failed (verify_release.sh:45)' >&2; exit 1; }
[[ "$(cat "$APP/Contents/Resources/sane.d/dll.conf")" == canon_dr ]] || { echo 'Release assertion failed (verify_release.sh:46)' >&2; exit 1; }
[[ -s "$APP/Contents/Resources/AppIcon.icns" ]] || { echo 'Release assertion failed (verify_release.sh:47)' >&2; exit 1; }
[[ -s "$APP/Contents/Resources/Licenses/CanonScan-GPL-3.0.txt" ]] || { echo 'Release assertion failed (verify_release.sh:48)' >&2; exit 1; }
"$APP/Contents/Resources/scanimage" --format=png --version
[[ "$("$APP/Contents/Resources/scanbutton" --version)" == 'scanbutton 1 (SANE start-button watcher)' ]] || { echo 'Invalid scanbutton helper.' >&2; exit 1; }
tar -xzf "$SOURCE" -C "$VERIFY"
SOURCES="$VERIFY/R3Ds-CanonScan-$VERSION-backend-sources"
(cd "$SOURCES" && shasum -a 256 -c SHA256SUMS)
FINGERPRINT="$(cat "$SOURCES/script/backend-versions.sh" "$SOURCES/script/bootstrap_backend.sh" "$SOURCES/Backend/scanbutton.c" | shasum -a 256 | awk '{print $1}')"
[[ "$(cat "$APP/Contents/Resources/backend-fingerprint.txt")" == "$FINGERPRINT" ]] || { echo 'Release assertion failed (verify_release.sh:54)' >&2; exit 1; }
[[ "$(cat "$SOURCES/build-fingerprint")" == "$FINGERPRINT" ]] || { echo 'Release assertion failed (verify_release.sh:55)' >&2; exit 1; }
python3 - "$SOURCES" <<'PY'
import hashlib, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
values = dict(re.findall(r'^([A-Z_0-9]+)=([^\s]+)$', (root / 'script/backend-versions.sh').read_text(), re.M))
for name in ['SANE', 'LIBUSB', 'LIBPNG', 'JPEG']:
    archive = values[name + '_ARCHIVE']
    assert pathlib.Path(archive).name == archive
    actual = hashlib.sha256((root / '.dependencies/downloads' / archive).read_bytes()).hexdigest()
    assert actual == values[name + '_SHA256'], archive
PY
echo "Verified app, helper, tickets and corresponding sources: $ZIP"
