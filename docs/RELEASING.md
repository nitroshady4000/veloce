# Releases and automatic updates

Véloce uses Sparkle 2.10.0. The app reads the signed feed at
`https://github.com/nitroshady4000/veloce/releases/latest/download/appcast.xml`.
GitHub's latest release must contain both `appcast.xml` and the exact ZIP it
references. Releases must be stable releases, because the latest URL excludes
drafts and prereleases. Uploaded update assets must never be changed in place.

## Build a portable app

```sh
scripts/build-app.sh
open build/Veloce.app
```

The bundle includes Sparkle with its helper apps and XPC services, the engine
source and dependency lockfile, and a standalone `uv` binary. It does not embed
the checkout path, Python environment, model downloads, or caches. Engine setup
uses the persistent environment under `~/Library/Application Support/Veloce/Engine`
and model storage under `~/Library/Caches/Veloce/models`.

`uv` is found on PATH or through `VELOCE_UV_BIN`. Set `VELOCE_UV_LICENSE_DIR` if
its `LICENSE-MIT` and `LICENSE-APACHE` files are not in the parent directory of
its `bin` directory. The build rejects a uv binary linked to non-system libraries.

`VELOCE_APP_OUTPUT` changes the destination; `VELOCE_VERSION` and
`VELOCE_BUILD_NUMBER` override the bundled version without editing source files.
Every published build needs a strictly increasing numeric `CFBundleVersion`.

## Signing keys

Code signing and Sparkle update signing serve separate purposes. For a local
build, `VELOCE_SIGN_IDENTITY` may select an existing local development certificate;
without it, signing is ad hoc. Use the same persistent identity for successive
local builds. Such builds are not Apple-notarized and downloads may require
Gatekeeper approval. Sparkle still authenticates updates using the embedded
Ed25519 public key.

For public distribution use a **Developer ID Application** certificate and
notarization. Named Developer ID identities automatically enable hardened runtime;
when selecting a Developer ID identity by fingerprint, also set
`VELOCE_HARDENED_RUNTIME=1`. Ad-hoc and local development builds leave hardened
runtime off because its library validation can reject locally signed frameworks.

Create the Sparkle key once, after resolving the package:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account veloce-sparkle
```

Copy the displayed public key to `SUPublicEDKey` in `Resources/Info.plist`. Keep
the private key in Keychain and maintain a secure backup outside this repository.
Do not regenerate the key between releases. `VELOCE_SPARKLE_KEY_ACCOUNT` can
select another account. CI can instead supply a protected private key file with
`VELOCE_SPARKLE_KEY_FILE`; never commit that file or print its contents.

## Prepare and publish

```sh
# Example versions only: choose an unused version and increasing build number.
VELOCE_SIGN_IDENTITY='Famulus Dev' scripts/package-release.sh 0.3.0 4 release-notes.md
```

The optional third argument is a Markdown release notes file. Outputs are under
`build/releases/v0.3.0-build.4/`: a verified app and an `assets` directory with
the ZIP, signed appcast, optional signed notes, and checksums. The packaging
script never publishes. It verifies the ZIP signature against the public key in
the app and verifies the signed feed using Sparkle's official tool.

For notarized distribution, first store credentials with Apple's `notarytool`,
then set `VELOCE_NOTARY_PROFILE` to that Keychain profile and
`VELOCE_SIGN_IDENTITY` to the Developer ID certificate. Packaging notarizes and
staples the app before creating and signing the final update ZIP.

Review and test the prepared app, commit the corresponding source, then create
and push its tag. Publish only when the release is ready:

```sh
git tag v0.3.0-build.4
git push origin v0.3.0-build.4
scripts/publish-release.sh v0.3.0-build.4
```

Publishing uses `gh`, requires a pre-existing remote tag, verifies checksums, and
makes the release the latest stable release. It does not silently overwrite an
existing release. Before publishing, confirm the build number is greater than
the current production feed's `sparkle:version`; do not publish an old build as
latest. Never hand-edit an appcast or signed release notes after packaging.

After publication, download the public feed and ZIP, confirm the checksum, and
check for updates from an older installed app. Test automatic download and
installation with that app's automatic-update preference enabled, including
quitting and relaunching. Retain the same Ed25519 key for future updates.

Implementation references: [Sparkle setup](https://sparkle-project.org/documentation/),
[manual nested code signing](https://sparkle-project.org/documentation/sandboxing/#code-signing),
and [publishing updates](https://sparkle-project.org/documentation/publishing/).
