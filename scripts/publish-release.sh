#!/bin/bash
# Explicit publishing command: creates a stable release and makes it latest.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 1 && "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-build\.[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Usage: $0 vVERSION-build.BUILD_NUMBER" >&2; exit 2; }
TAG="$1"
REPOSITORY="${VELOCE_RELEASE_REPOSITORY:-nitroshady4000/veloce}"
ASSETS="$ROOT/build/releases/$TAG/assets"
[[ -s "$ASSETS/appcast.xml" && -s "$ASSETS/SHA256SUMS" ]] || { echo "Run package-release.sh first." >&2; exit 1; }
(cd "$ASSETS" && shasum -a 256 -c SHA256SUMS)
# --verify-tag requires the caller to commit and push the reviewed source first.
# Stable (not prerelease) is necessary for GitHub's /releases/latest/ feed URL.
gh release create "$TAG" "$ASSETS"/* --repo "$REPOSITORY" --verify-tag \
    --title "Véloce ${TAG#v}" --generate-notes --latest
