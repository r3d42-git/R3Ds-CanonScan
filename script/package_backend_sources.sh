#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/backend-versions.sh"
TASK_VERSION="${1:?Usage: package_backend_sources.sh VERSION}"
if [[ ! "$TASK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo 'Expected a numeric release version.' >&2; exit 1; fi
TASK_NAME="R3Ds-CanonScan-$TASK_VERSION-backend-sources"
TASK_OUT="$ROOT_DIR/dist/release"
TASK_STAGE="$(mktemp -d "$ROOT_DIR/.dependencies/backend-source-package.XXXXXX")"
trap 'rm -rf "$TASK_STAGE"' EXIT
TASK_PACKAGE="$TASK_STAGE/$TASK_NAME"
mkdir -p "$TASK_PACKAGE/.dependencies/downloads" "$TASK_PACKAGE/script" "$TASK_PACKAGE/docs" "$TASK_PACKAGE/licenses" "$TASK_OUT"
# A successful runtime must match this precise recipe before its sources ship.
TASK_FINGERPRINT="$(cat "$ROOT_DIR/script/backend-versions.sh" "$ROOT_DIR/script/bootstrap_backend.sh" | shasum -a 256 | awk '{print $1}')"
if [[ ! -f "$ROOT_DIR/.dependencies/scanner-runtime/build-fingerprint" ]] || [[ "$(cat "$ROOT_DIR/.dependencies/scanner-runtime/build-fingerprint")" != "$TASK_FINGERPRINT" ]]; then
  echo 'Build the current backend recipe before packaging its corresponding sources.' >&2; exit 1
fi
add_source() {
  local task_archive="$1" task_sha="$2" task_url="$3"
  printf '%s  %s\n' "$task_sha" "$ROOT_DIR/.dependencies/downloads/$task_archive" | shasum -a 256 -c -
  cp "$ROOT_DIR/.dependencies/downloads/$task_archive" "$TASK_PACKAGE/.dependencies/downloads/"
  printf '%s  .dependencies/downloads/%s\n' "$task_sha" "$task_archive" >> "$TASK_PACKAGE/SHA256SUMS"
  printf '%s\n%s\n\n' "$task_archive" "$task_url" >> "$TASK_PACKAGE/UPSTREAM_URLS.txt"
}
add_source "$SANE_ARCHIVE" "$SANE_SHA256" "$SANE_URL"
add_source "$LIBUSB_ARCHIVE" "$LIBUSB_SHA256" "$LIBUSB_URL"
add_source "$LIBPNG_ARCHIVE" "$LIBPNG_SHA256" "$LIBPNG_URL"
add_source "$JPEG_ARCHIVE" "$JPEG_SHA256" "$JPEG_URL"
cp "$ROOT_DIR/script/bootstrap_backend.sh" "$ROOT_DIR/script/backend-versions.sh" "$ROOT_DIR/script/package_backend_sources.sh" "$TASK_PACKAGE/script/"
cp "$ROOT_DIR/docs/backend.md" "$TASK_PACKAGE/docs/"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$ROOT_DIR/LICENSE" "$TASK_PACKAGE/"
cp "$ROOT_DIR/.dependencies/scanner-runtime/licenses/"* "$TASK_PACKAGE/licenses/"
cp "$ROOT_DIR/.dependencies/scanner-runtime/build-fingerprint" "$TASK_PACKAGE/"
cat > "$TASK_PACKAGE/README.txt" <<'TXT'
Exact corresponding sources for the bundled SANE scanimage helper.
See docs/backend.md for build and relinking instructions.
All four source archives are unmodified upstream releases. SHA256SUMS verifies
those archives. script/backend-versions.sh pins the build-only CMake download.
CMake is not linked into the scanner helper and is not bundled here.
Apple command line tools/macOS SDK are required; no Homebrew libraries are used.
The Swift app and app packaging sources accompany the same release's Git tag.
TXT
(cd "$TASK_PACKAGE" && shasum -a 256 -c SHA256SUMS)
COPYFILE_DISABLE=1 tar -czf "$TASK_OUT/$TASK_NAME.tar.gz" -C "$TASK_STAGE" "$TASK_NAME"
shasum -a 256 "$TASK_OUT/$TASK_NAME.tar.gz"
echo "$TASK_OUT/$TASK_NAME.tar.gz"
