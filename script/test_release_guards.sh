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
cat > "$TEMP/png-helper" <<'SH'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = --format=png ] && [ "$2" = --version ] || exit 2
echo 'scanimage (sane-backends) 1.4.0; backend version 1.4.0'
SH
cat > "$TEMP/no-png-helper" <<'SH'
#!/bin/sh
echo 'PNG support not compiled in' >&2
exit 1
SH
cat > "$TEMP/empty-helper" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TEMP/png-helper" "$TEMP/no-png-helper" "$TEMP/empty-helper"
"$ROOT/script/bootstrap_backend.sh" --verify-helper "$TEMP/png-helper" > "$TEMP/png.log" 2>&1
for HELPER in no-png-helper empty-helper; do
  if "$ROOT/script/bootstrap_backend.sh" --verify-helper "$TEMP/$HELPER" > "$TEMP/$HELPER.log" 2>&1; then
    echo "Invalid scanner helper accepted: $HELPER" >&2; exit 1
  fi
done
grep -q 'PNG support not compiled in' "$TEMP/no-png-helper.log"
grep -q 'did not return its version' "$TEMP/empty-helper.log"
cat > "$TEMP/button-helper" <<'SH'
#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = --version ] || exit 2
echo 'scanbutton 1 (SANE start-button watcher)'
SH
chmod +x "$TEMP/button-helper"
"$ROOT/script/bootstrap_backend.sh" --verify-button-helper "$TEMP/button-helper"
if "$ROOT/script/bootstrap_backend.sh" --verify-button-helper "$TEMP/empty-helper" > "$TEMP/button.log" 2>&1; then
  echo 'Empty scanbutton helper was accepted.' >&2; exit 1
fi
echo 'Release guards reject invalid version, SHA-256, missing PNG support and invalid button helpers before packaging or notarization.'
