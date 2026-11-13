#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/backend-versions.sh"
TASK_DEPS="$ROOT_DIR/.dependencies"
TASK_PREFIX="$TASK_DEPS/scanner-runtime"
TASK_FINGERPRINT="$(cat "$ROOT_DIR/script/backend-versions.sh" "$ROOT_DIR/script/bootstrap_backend.sh" | shasum -a 256 | awk '{print $1}')"
# Never reuse the former Homebrew-linked build, or a build from a different recipe.
if [[ -x "$TASK_PREFIX/bin/scanimage" && -f "$TASK_PREFIX/build-fingerprint" && "${1:-}" != --rebuild ]] && [[ "$(cat "$TASK_PREFIX/build-fingerprint")" == "$TASK_FINGERPRINT" ]]; then
  exit 0
fi
if [[ "$(uname -m)" != arm64 || "$(uname -s)" != Darwin ]]; then
  echo 'The scanner build requires an Apple Silicon Mac with macOS 27 and Xcode command line tools.' >&2
  exit 1
fi
mkdir -p "$TASK_DEPS/downloads"
fetch() {
  local task_archive="$TASK_DEPS/downloads/$1" task_sha="$2" task_url="$3"
  if [[ ! -f "$task_archive" ]]; then
    curl --fail --location --retry 2 --show-error --output "$task_archive.part" "$task_url"
    printf '%s  %s\n' "$task_sha" "$task_archive.part" | shasum -a 256 -c -
    mv "$task_archive.part" "$task_archive"
  fi
  printf '%s  %s\n' "$task_sha" "$task_archive" | shasum -a 256 -c -
}
fetch "$SANE_ARCHIVE" "$SANE_SHA256" "$SANE_URL"
fetch "$LIBUSB_ARCHIVE" "$LIBUSB_SHA256" "$LIBUSB_URL"
fetch "$LIBPNG_ARCHIVE" "$LIBPNG_SHA256" "$LIBPNG_URL"
fetch "$JPEG_ARCHIVE" "$JPEG_SHA256" "$JPEG_URL"
fetch "$CMAKE_ARCHIVE" "$CMAKE_SHA256" "$CMAKE_URL"
TASK_BUILD="$TASK_DEPS/backend-build-$TASK_FINGERPRINT"
# All generated sources, configuration caches and libraries come from this recipe.
rm -rf "$TASK_BUILD"
mkdir -p "$TASK_BUILD/sources" "$TASK_BUILD/prefix"
for task_archive in "$SANE_ARCHIVE" "$LIBUSB_ARCHIVE" "$LIBPNG_ARCHIVE" "$JPEG_ARCHIVE" "$CMAKE_ARCHIVE"; do
  tar -xf "$TASK_DEPS/downloads/$task_archive" -C "$TASK_BUILD/sources"
done
TASK_LIBS="$TASK_BUILD/prefix"
TASK_CMAKE="$TASK_BUILD/sources/cmake-$CMAKE_VERSION-macos-universal/CMake.app/Contents/bin/cmake"
TASK_JOBS="${BACKEND_BUILD_JOBS:-6}"
export MACOSX_DEPLOYMENT_TARGET="$BACKEND_DEPLOYMENT_TARGET"
export CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CFLAGS="-arch arm64 -mmacosx-version-min=$BACKEND_DEPLOYMENT_TARGET -O2"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$TASK_LIBS/include"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$BACKEND_DEPLOYMENT_TARGET -L$TASK_LIBS/lib"
# Do not discover globally installed optional libraries through pkg-config.
export PKG_CONFIG=/usr/bin/false PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH DYLD_LIBRARY_PATH CMAKE_PREFIX_PATH || true
(
  cd "$TASK_BUILD/sources/libusb-$LIBUSB_VERSION"
  ./configure --prefix="$TASK_LIBS" --disable-shared --enable-static > "$TASK_BUILD/libusb-configure.log" 2>&1
  make -j"$TASK_JOBS" > "$TASK_BUILD/libusb-build.log" 2>&1
  make install >> "$TASK_BUILD/libusb-build.log" 2>&1
)
(
  cd "$TASK_BUILD/sources/libpng-$LIBPNG_VERSION"
  ./configure --prefix="$TASK_LIBS" --disable-shared --enable-static > "$TASK_BUILD/libpng-configure.log" 2>&1
  make -j"$TASK_JOBS" > "$TASK_BUILD/libpng-build.log" 2>&1
  make install >> "$TASK_BUILD/libpng-build.log" 2>&1
)
"$TASK_CMAKE" -S "$TASK_BUILD/sources/libjpeg-turbo-$JPEG_VERSION" -B "$TASK_BUILD/jpeg-build" \
  -DCMAKE_INSTALL_PREFIX="$TASK_LIBS" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$BACKEND_DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_SYSROOT="$SDKROOT" -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
  -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF > "$TASK_BUILD/jpeg-configure.log" 2>&1
"$TASK_CMAKE" --build "$TASK_BUILD/jpeg-build" --parallel "$TASK_JOBS" > "$TASK_BUILD/jpeg-build.log" 2>&1
"$TASK_CMAKE" --install "$TASK_BUILD/jpeg-build" >> "$TASK_BUILD/jpeg-build.log" 2>&1
mkdir -p "$TASK_BUILD/sane-build"
cd "$TASK_BUILD/sane-build"
export BACKENDS=canon_dr PRELOADABLE_BACKENDS=canon_dr
export USB_CFLAGS="-I$TASK_LIBS/include/libusb-1.0"
export USB_LIBS="-L$TASK_LIBS/lib -lusb-1.0 -framework IOKit -framework CoreFoundation -framework Security -lobjc"
export CFLAGS="$CFLAGS -Wno-error=incompatible-function-pointer-types"
"$TASK_BUILD/sources/sane-backends-$SANE_VERSION/configure" --prefix="$TASK_PREFIX" \
  --disable-shared --enable-static --disable-dynamic --disable-nls \
  --without-avahi --without-snmp --without-libcurl --without-poppler-glib \
  --without-v4l --without-gphoto2 --without-systemd --with-usb > configure-output.log 2>&1
make -C lib -j"$TASK_JOBS" > build-output.log 2>&1
make -C sanei -j"$TASK_JOBS" >> build-output.log 2>&1
# Generate the preload table before the targeted library build (not all).
make -C backend dll-preload.h >> build-output.log 2>&1
make -C backend -j"$TASK_JOBS" libsane.la >> build-output.log 2>&1
make -C frontend -j"$TASK_JOBS" scanimage.o jpegtopdf.o sicc.o stiff.o >> build-output.log 2>&1
mkdir -p "$TASK_BUILD/runtime/bin" "$TASK_BUILD/runtime/etc/sane.d" "$TASK_BUILD/runtime/licenses"
"$CC" -arch arm64 -mmacosx-version-min="$BACKEND_DEPLOYMENT_TARGET" -O2 -o "$TASK_BUILD/runtime/bin/scanimage" \
  frontend/scanimage.o frontend/jpegtopdf.o frontend/sicc.o frontend/stiff.o \
  backend/.libs/libsane.a sanei/.libs/libsanei.a lib/.libs/liblib.a \
  "$TASK_LIBS/lib/libusb-1.0.a" "$TASK_LIBS/lib/libpng.a" "$TASK_LIBS/lib/libjpeg.a" \
  -lz -lm -lpthread -lobjc -framework Security -framework IOKit -framework CoreFoundation
# Validated P-208II sensor offset: 260 units at 1200 dpi (5.5 mm).
printf 'option duplex-offset 260\nusb 0x1083 0x165f\n' > "$TASK_BUILD/runtime/etc/sane.d/canon_dr.conf"
printf 'canon_dr\n' > "$TASK_BUILD/runtime/etc/sane.d/dll.conf"
cp "$TASK_BUILD/sources/sane-backends-$SANE_VERSION/COPYING" "$TASK_BUILD/runtime/licenses/SANE-COPYING.txt"
cp "$TASK_BUILD/sources/sane-backends-$SANE_VERSION/LICENSE" "$TASK_BUILD/runtime/licenses/SANE-LICENSE.txt"
cp "$TASK_BUILD/sources/sane-backends-$SANE_VERSION/AUTHORS" "$TASK_BUILD/runtime/licenses/SANE-AUTHORS.txt"
cp "$TASK_BUILD/sources/libusb-$LIBUSB_VERSION/COPYING" "$TASK_BUILD/runtime/licenses/libusb-COPYING.txt"
cp "$TASK_BUILD/sources/libusb-$LIBUSB_VERSION/AUTHORS" "$TASK_BUILD/runtime/licenses/libusb-AUTHORS.txt"
cp "$TASK_BUILD/sources/libpng-$LIBPNG_VERSION/LICENSE" "$TASK_BUILD/runtime/licenses/libpng-LICENSE.txt"
cp "$TASK_BUILD/sources/libjpeg-turbo-$JPEG_VERSION/LICENSE.md" "$TASK_BUILD/runtime/licenses/jpeg-turbo-LICENSE.md"
cp "$TASK_BUILD/sources/libjpeg-turbo-$JPEG_VERSION/README.ijg" "$TASK_BUILD/runtime/licenses/jpeg-turbo-README.ijg"
cp "$TASK_BUILD/sources/libjpeg-turbo-$JPEG_VERSION/simd/arm/jccolor-neon.c" "$TASK_BUILD/runtime/licenses/jpeg-turbo-SIMD-notice.c"
cp "$ROOT_DIR/script/backend-versions.sh" "$TASK_BUILD/runtime/backend-versions.sh"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$TASK_BUILD/runtime/licenses/THIRD_PARTY_NOTICES.md"
otool -L "$TASK_BUILD/runtime/bin/scanimage" > "$TASK_BUILD/runtime/linkage.txt"
if ! awk 'NR > 1 { if ($1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\//) exit 1 }' "$TASK_BUILD/runtime/linkage.txt"; then
  echo 'Scanner binary has a non-system runtime dependency.' >&2; exit 1
fi
[[ "$(lipo -archs "$TASK_BUILD/runtime/bin/scanimage")" == arm64 ]] || { echo 'Release assertion failed (bootstrap_backend.sh:111)' >&2; exit 1; }
otool -l "$TASK_BUILD/runtime/bin/scanimage" | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/{if ($2 != "27.0") exit 1; found=1; exit} END{if (!found) exit 1}'
"$TASK_BUILD/runtime/bin/scanimage" --version
printf '%s\n' "$TASK_FINGERPRINT" > "$TASK_BUILD/runtime/build-fingerprint"
# Promote only a fully verified build; keep the preceding runtime until then.
rm -rf "$TASK_PREFIX.previous"
if [[ -d "$TASK_PREFIX" ]]; then mv "$TASK_PREFIX" "$TASK_PREFIX.previous"; fi
mv "$TASK_BUILD/runtime" "$TASK_PREFIX"
echo 'Scanner backend ready (SANE 1.4.0 / canon_dr / P-208II / arm64 / macOS 27).'
