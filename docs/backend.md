# Scanner backend build and corresponding source

The supported scanner is Canon imageFORMULA P-208II, USB `1083:165f`.
The statically linked SANE 1.4.0 helpers include only `canon_dr`. Their configuration
must retain `option duplex-offset 260` and `usb 0x1083 0x165f`; the offset was
validated for this scanner's approximately 5.5 mm sensor displacement. This
release targets Apple Silicon and macOS 27.0 or later.

`scanimage` acquires pages. The local `Backend/scanbutton.c` helper, `scanbutton`,
opens the same backend and polls its readable `start` boolean every 200 ms.
It never starts the feeder. It consumes the opening state, waits for a fresh
press, closes SANE/USB, then emits `START`. The app joins this process before
opening `scanimage`. SIGTERM/SIGINT stop the listener and release the device.
Only the foreground document listens; changing settings, opening dialogs,
starting other operations or closing the window cancels the listener.
`./script/test_scanbutton.sh` tests the protocol, startup latch and cleanup
against a mock SANE implementation without accessing hardware.

## Rebuild

On an Apple Silicon Mac with macOS 27 and Xcode command line tools installed:

```sh
./script/bootstrap_backend.sh --rebuild
.dependencies/scanner-runtime/bin/scanimage --version
.dependencies/scanner-runtime/bin/scanbutton --version
./script/bootstrap_backend.sh --verify-helper .dependencies/scanner-runtime/bin/scanimage
otool -L .dependencies/scanner-runtime/bin/scanimage
```

The script downloads the unmodified release archives pinned in
`script/backend-versions.sh`, checks SHA-256 before extracting, and builds
libusb 1.0.30, libpng 1.6.59, libjpeg-turbo 3.2.1 and SANE 1.4.0 from source.
Kitware CMake 4.1.3 is fetched and hash-verified as a local build tool. No global
package installation is performed. Initial downloads require internet access;
with all five archives in `.dependencies/downloads`, the build is offline.
`BACKEND_BUILD_JOBS=4` can limit parallelism.

`MACOSX_DEPLOYMENT_TARGET=27.0`, arm64 architecture, Apple clang and the current
macOS SDK are explicit. Homebrew paths are excluded from the build environment;
pkg-config discovery is disabled. libpng uses Apple's system zlib, which is
passed to SANE's configure link checks through `LIBS=-lz`:
SANE 1.4.0 probes `png_init_io` with `-lpng`, and static libpng requires zlib
to resolve its symbols. Header and library paths point at the local build
prefix. Configuration must define `HAVE_LIBPNG` before compilation proceeds;
linking libpng into the final helper alone does not enable PNG code paths.
Only Apple system dylibs/frameworks may remain in `otool -L`. The script verifies arm64 and
Mach-O minimum macOS 27.0 and PNG format acceptance before promoting the helper.
The same executable PNG check also runs before accepting a cached runtime.
Build logs, sources and
static libraries are retained under `.dependencies/backend-build-FINGERPRINT`.
The manifest, local `scanbutton.c` source and complete build recipe determine the fingerprint, so an older
Homebrew build or changed recipe cannot silently reuse an existing helper.

The standalone `--verify-helper PATH` command never builds or scans. It runs
`scanimage --format=png --version` in that order: in SANE 1.4.0 the format is
validated first, then the version option exits before device discovery. A
helper compiled without PNG support must fail this check with
`PNG support not compiled in`; a PNG-enabled helper must exit successfully
and print its scanimage version. `--help` is not a hardware-free substitute,
because it discovers and opens devices. This checks compiled format support,
not PNG encoding quality or physical scanning.

This is a reproducible source/build-input recipe, not a promise of bit-identical
binaries across Xcode or SDK releases. Record `xcodebuild -version`,
`xcrun clang --version` and `xcrun --sdk macosx --show-sdk-version` when comparing
builds.

## Release source asset

```sh
./script/package_backend_sources.sh 0.5.0
```

This verifies and packages all four upstream archives, a checksum list,
version/URL manifest, notices, extracted license texts, local `scanbutton.c` source and the build script into
`dist/release/R3Ds-CanonScan-0.5.0-backend-sources.tar.gz`. It does not package
Homebrew binaries or the CMake binary. To rebuild from that asset:

```sh
tar -xzf R3Ds-CanonScan-0.5.0-backend-sources.tar.gz
cd R3Ds-CanonScan-0.5.0-backend-sources
./script/bootstrap_backend.sh --rebuild
```

The included upstream archives already occupy the expected download cache.
Only the hash-pinned build tool is downloaded on the first build. Full sources
allow changing/rebuilding/relinking SANE and libusb, including static-library
modifications; no object-only relinking kit is needed. App Swift sources and
installation/package recipes are separately available in the release Git tag.
The app licenses directory and source bundle retain third-party notices.

The configuration intentionally does not enable network scanners or other
SANE backends. Build verification and device discovery do not perform a scan;
physical simplex/duplex tests remain separate user checks.
