#!/bin/bash
# Build and sign release assets locally. This script never uploads a release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 VERSION BUILD_NUMBER [RELEASE_NOTES.md]" >&2
    exit 2
fi
VERSION="$1"
BUILD_NUMBER="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be numeric major.minor.patch." >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Build number must be numeric and increase for every release." >&2; exit 2; }
REPOSITORY="${VELOCE_RELEASE_REPOSITORY:-nitroshady4000/veloce}"
TAG="v$VERSION-build.$BUILD_NUMBER"
OUTPUT="$ROOT/build/releases/$TAG"
[[ ! -e "$OUTPUT" ]] || { echo "$OUTPUT already exists; use a new version/build or move it aside." >&2; exit 1; }
mkdir -p "$OUTPUT/assets"
APP="$OUTPUT/Veloce.app"
VELOCE_APP_OUTPUT="$APP" VELOCE_VERSION="$VERSION" VELOCE_BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/build-app.sh"
PLIST="$APP/Contents/Info.plist"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
[[ -n "$PUBLIC_KEY" ]] || { echo "Missing SUPublicEDKey; generate a persistent Sparkle key first." >&2; exit 1; }
EXPECTED_FEED="https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"
ACTUAL_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")"
[[ "$ACTUAL_FEED" == "$EXPECTED_FEED" ]] || { echo "SUFeedURL differs from the release repository: $ACTUAL_FEED" >&2; exit 1; }
SPARKLE_BIN="${VELOCE_SPARKLE_BIN:-}"
if [[ -z "$SPARKLE_BIN" ]]; then
    GENERATOR="$(find "$ROOT/.build/artifacts" -type f -path '*/bin/generate_appcast' -print -quit)"
    SPARKLE_BIN="$(dirname "$GENERATOR")"
fi
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "Missing Sparkle release tools; set VELOCE_SPARKLE_BIN." >&2; exit 1; }

# Notarization must precede the final ZIP and its Sparkle signature.
if [[ -n "${VELOCE_NOTARY_PROFILE:-}" ]]; then
    [[ "${VELOCE_SIGN_IDENTITY:--}" != '-' ]] || { echo "Notarization needs VELOCE_SIGN_IDENTITY (Developer ID Application)." >&2; exit 1; }
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/notarization.zip"
    xcrun notarytool submit "$OUTPUT/notarization.zip" --keychain-profile "$VELOCE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm "$OUTPUT/notarization.zip"
else
    echo "Building without notarization; downloaded apps may require Gatekeeper approval." >&2
fi

ARCHIVE_NAME="Veloce-$VERSION-$BUILD_NUMBER.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/assets/$ARCHIVE_NAME"
if [[ $# == 3 ]]; then
    cp "$3" "$OUTPUT/assets/${ARCHIVE_NAME%.zip}.md"
fi
KEY_OPTIONS=(--account "${VELOCE_SPARKLE_KEY_ACCOUNT:-veloce-sparkle}")
# CI may use a protected file; its contents never appear in command arguments.
if [[ -n "${VELOCE_SPARKLE_KEY_FILE:-}" ]]; then
    KEY_OPTIONS=(--ed-key-file "$VELOCE_SPARKLE_KEY_FILE")
fi
"$SPARKLE_BIN/generate_appcast" "${KEY_OPTIONS[@]}" \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
    --release-notes-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
    --maximum-deltas 0 "$OUTPUT/assets"
[[ -s "$OUTPUT/assets/appcast.xml" ]] || { echo "Sparkle did not generate appcast.xml." >&2; exit 1; }
# Verify the archive with the exact public key embedded in this app. This catches
# selecting the wrong Keychain account before a broken update is published.
SIGNATURE="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$OUTPUT/assets/appcast.xml")"
mkdir -p "$ROOT/.build/release-verifier-cache"
xcrun swift -module-cache-path "$ROOT/.build/release-verifier-cache" "$ROOT/scripts/verify-update.swift" \
    "$OUTPUT/assets/$ARCHIVE_NAME" "$SIGNATURE" "$PUBLIC_KEY"
"$SPARKLE_BIN/sign_update" "${KEY_OPTIONS[@]}" --verify "$OUTPUT/assets/appcast.xml"
(
    cd "$OUTPUT/assets"
    shasum -a 256 "$ARCHIVE_NAME" appcast.xml > SHA256SUMS
)
printf 'Prepared %s\nTag: %s\n' "$OUTPUT/assets" "$TAG"
printf 'Publish after review: scripts/publish-release.sh %s\n' "$TAG"
