#!/usr/bin/env bash
# Exercises actual release gates with intentionally invalid input; no Apple/GitHub writes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/script/version.sh"
TEMP="$(mktemp -d /private/tmp/canonscan-release-guards.XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT
if "$ROOT/script/release.sh" invalid-version > "$TEMP/version.log" 2>&1; then
  echo 'Invalid version was accepted.' >&2; exit 1
fi
if ! grep -q 'Usage: release.sh' "$TEMP/version.log"; then cat "$TEMP/version.log"; exit 1; fi
ZIP="$TEMP/R3Ds-CanonScan-$CANONSCAN_VERSION-macOS-arm64.zip"
printf 'invalid archive, intentionally wrong checksum\n' > "$ZIP"
printf '%064d  %s\n' 0 "$(basename "$ZIP")" > "$ZIP.sha256"
if "$ROOT/script/verify_release.sh" "$CANONSCAN_VERSION" "$ZIP" > "$TEMP/checksum.log" 2>&1; then
  echo 'Invalid checksum was accepted.' >&2; exit 1
fi
if ! grep -q 'SHA-256 mismatch:' "$TEMP/checksum.log"; then cat "$TEMP/checksum.log"; exit 1; fi
echo 'Release guards reject invalid version and SHA-256 before packaging or notarization.'
