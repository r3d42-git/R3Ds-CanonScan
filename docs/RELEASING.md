# Releases

Use an Apple Silicon Mac with Xcode, a Developer ID Application certificate and
a valid local `notarytool` credential profile. Keep credentials outside Git.
`script/version.sh` defines the version, build number and product identity.

From a clean, committed `main` branch:

```sh
MACOS_NOTARY_PROFILE=ToolBoxS ./script/release.sh 0.4.1
./script/publish_release.sh --dry-run 0.4.1
./script/publish_release.sh 0.4.1
```

Set `CODE_SIGN_IDENTITY` to select another Developer ID certificate.
`MACOS_NOTARY_PROFILE` selects an existing credential profile.

The release script runs tests, builds and signs the app and scanner helper,
notarizes the app, attaches its ticket and packages the final ZIP. It also
creates the backend source archive required for redistribution. Each asset
has a SHA-256 sidecar.

To verify an existing ZIP and its accompanying source archive:

```sh
./script/verify_release.sh 0.4.1 path/to/R3Ds-CanonScan-0.4.1-macOS-arm64.zip
```

The publish script pushes the source and an annotated version tag, uploads the
assets, then downloads and verifies them independently. Existing releases are
not overwritten. Never move a published tag. If Apple submission is interrupted,
check the saved submission ID before submitting again.
