#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/script/version.sh"
CONFIGURATION="${1:-debug}"
[[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || { echo 'Expected debug or release' >&2; exit 2; }
APP="${2:-$ROOT/dist/$CANONSCAN_APP_NAME.app}"
IDENTITY="${CODE_SIGN_IDENTITY:--}"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.cache/swift"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
./script/bootstrap_backend.sh
swift build -c "$CONFIGURATION" --disable-sandbox --cache-path "$ROOT/.cache/swiftpm"
BIN="$(swift build -c "$CONFIGURATION" --disable-sandbox --cache-path "$ROOT/.cache/swiftpm" --show-bin-path)/$CANONSCAN_EXECUTABLE"
[[ -f Resources/AppIcon.icns ]] || ./script/build_icon.sh
mkdir -p "$(dirname "$APP")"
STAGING="$(mktemp -d "$(dirname "$APP")/.canonscan-bundle.XXXXXX")/$CANONSCAN_APP_NAME.app"
trap 'rm -rf "$(dirname "$STAGING")"' EXIT
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources/sane.d" "$STAGING/Contents/Resources/Licenses"
cp "$BIN" "$STAGING/Contents/MacOS/$CANONSCAN_EXECUTABLE"
cp .dependencies/scanner-runtime/bin/{scanimage,scanbutton} "$STAGING/Contents/Resources/"
cp .dependencies/scanner-runtime/etc/sane.d/*.conf "$STAGING/Contents/Resources/sane.d/"
cp .dependencies/scanner-runtime/licenses/* "$STAGING/Contents/Resources/Licenses/"
cp Resources/AppIcon.icns "$STAGING/Contents/Resources/"
cp .dependencies/scanner-runtime/build-fingerprint "$STAGING/Contents/Resources/backend-fingerprint.txt"
cp LICENSE "$STAGING/Contents/Resources/Licenses/CanonScan-GPL-3.0.txt"
cp THIRD_PARTY_NOTICES.md "$STAGING/Contents/Resources/Licenses/"
cat > "$STAGING/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$CANONSCAN_EXECUTABLE</string>
<key>CFBundleIdentifier</key><string>$CANONSCAN_BUNDLE_ID</string>
<key>CFBundleName</key><string>$CANONSCAN_APP_NAME</string>
<key>CFBundleDisplayName</key><string>$CANONSCAN_APP_NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>de</string>
<key>CFBundleLocalizations</key><array><string>de</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$CANONSCAN_VERSION</string>
<key>CFBundleVersion</key><string>$CANONSCAN_BUILD</string>
<key>LSMinimumSystemVersion</key><string>$CANONSCAN_MIN_MACOS</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 R3D. GPL-3.0-or-later.</string>
</dict></plist>
PLIST
if [[ "$IDENTITY" == - ]]; then
  codesign --force --sign - "$STAGING/Contents/Resources/scanimage"
  codesign --force --sign - "$STAGING/Contents/Resources/scanbutton"
  codesign --force --sign - "$STAGING"
else
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$STAGING/Contents/Resources/scanimage"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$STAGING/Contents/Resources/scanbutton"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$STAGING"
fi
codesign --verify --deep --strict "$STAGING"
rm -rf "$APP"
mv "$STAGING" "$APP"
echo "$APP"
