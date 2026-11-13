# Release workflow

The public release branch is `main`. `script/version.sh` is the production
version/build/identity source. Never move an existing public version tag.

1. Review the explicit source changes, run the appropriate tests and commit.
   Keep real scans, user paths, credentials and build products out of Git.
2. On an Apple Silicon Mac with a Developer ID Application identity and a valid
   local notarytool profile, run:

   ```sh
   MACOS_NOTARY_PROFILE=ToolBoxS ./script/release.sh 0.4.0
   ./script/publish_release.sh --dry-run 0.4.0
   ./script/publish_release.sh 0.4.0
   ```

The signing identity may be supplied via `CODE_SIGN_IDENTITY`. The notarization
profile defaults to `ToolBoxS`; only its name is stored here, never credentials.
Creating certificates, profiles or global tools is outside these scripts.

`release.sh` requires a clean `main`, runs release tests, builds the arm64 Swift
app and the source-built scanner helper, signs both with Hardened Runtime and
timestamp, and submits the app in a temporary ZIP to Apple. Only `Accepted`
permits stapling. The final ZIP is made from the stapled app. It also supplies
the full backend sources as a separate archive. Each delivered asset has a
SHA-256 sidecar. Tests never start the scanner feeder.

`verify_release.sh VERSION ZIP` independently extracts the archive, checks
identity/version/build/minimum OS/arm64, verifies signatures and empty
entitlements on the app and helper, rejects non-system dynamic libraries,
checks the attached app ticket and Gatekeeper, verifies scanner configuration,
and checks source archive hashes and recipe fingerprint against the app.

`publish_release.sh` checks the clean source commit, release/tag agreement and
repository, then pushes `main` and an annotated tag and publishes exactly four
assets. It refuses to overwrite an existing release. It downloads all assets
into a fresh directory, compares exact bytes and GitHub digests, then reruns
the same verifier. Signing/notarization and the local/public Gatekeeper checks
must run in a permitted macOS execution context; a restricted sandbox may hide
the existing keychain identities and can make `iconutil` report Invalid Iconset.
No security setting or keychain change is required to use that context.
The scripts use explicit failure branches for `[[ … ]]` assertions because the
system Bash 3.2 can continue after a false compound assertion despite `set -e`.
`script/test_release_guards.sh` checks the real invalid-version and wrong-hash
paths without accessing Apple or GitHub; it also runs before every release.

Stop on a failed check. Preserve its logs, submission ID and bytes. If Apple
submission times out, query that ID instead of submitting again. An existing
output directory is deliberately not erased by `release.sh`. Inspect and retain
failed output before preparing a new attempt. A successful verifier is not a
clean-machine launch test; report that boundary separately.
