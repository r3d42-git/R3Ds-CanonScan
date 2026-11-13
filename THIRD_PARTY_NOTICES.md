# Third-party scanner components

R3Ds CanonScan bundles a project-built `scanimage` helper. Only SANE's
`canon_dr` backend is compiled in; this app supports the Canon imageFORMULA
P-208II (USB 1083:165f). General SANE device support is not an app feature.

| Component | Version | License | Upstream |
| --- | --- | --- | --- |
| SANE backends / scanimage | 1.4.0 | GPL-2.0-or-later; individual library files carry the SANE linking exception | https://sane-project.org/ |
| libusb | 1.0.30 | LGPL-2.1-or-later | https://libusb.info/ |
| libpng | 1.6.59 | libpng-2.0 | https://www.libpng.org/pub/png/libpng.html |
| libjpeg-turbo | 3.2.1 | IJG, BSD-3-Clause and Zlib; see upstream LICENSE.md and source notices | https://libjpeg-turbo.org/ |

The helper statically links the three libraries above. Apple system libraries,
including system zlib, are linked dynamically and supplied by macOS. No
Homebrew libraries are required at runtime or used to produce release helpers.
The app's GPL-3.0-or-later license does not replace these components' notices.

The release asset `R3Ds-CanonScan-VERSION-backend-sources.tar.gz` supplies the
exact, unmodified upstream archives, their SHA-256 checksums and URLs, license
texts, and the project build recipe for all bundled scanner components. The
recipe permits rebuilding and relinking the helper with modified libraries.
Corresponding Swift app sources are provided by the same release's Git tag and
GitHub source archives. No additional proprietary scanner driver is included.

The app bundle's `Contents/Resources/Licenses` directory contains
upstream notices. The source bundle retains all individual source-file notices.
libjpeg-turbo's IJG attribution: This software is based in part on the work of
the Independent JPEG Group.

CMake 4.1.3 (BSD-3-Clause, https://cmake.org/) is downloaded to the local build
cache solely as a build tool. It is not distributed in the app, not linked into
the helper, and not part of its runtime. Apple command line tools and macOS SDK
are build prerequisites. See `docs/backend.md` for exact reproduction steps.
