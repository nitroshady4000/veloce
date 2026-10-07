#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-module-cache"
SWIFT_OPTIONS=(--cache-path "$ROOT/.build/cache" --config-path "$ROOT/.build/config" --security-path "$ROOT/.build/security" --disable-sandbox -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
xcrun swift build -c release "${SWIFT_OPTIONS[@]}"
BIN="$(xcrun swift build -c release --show-bin-path "${SWIFT_OPTIONS[@]}")"
OUTPUT="${VELOCE_APP_OUTPUT:-$ROOT/build/Veloce.app}"
[[ "$OUTPUT" = /* ]] || OUTPUT="$ROOT/$OUTPUT"
[[ "$OUTPUT" == *.app ]] || { echo "VELOCE_APP_OUTPUT must end in .app" >&2; exit 2; }
mkdir -p "$ROOT/build" "$(dirname "$OUTPUT")"
STAGING="$(mktemp -d "$ROOT/build/.app-stage.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Veloce.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Engine" "$APP/Contents/Frameworks"
cp "$BIN/Veloce" "$APP/Contents/MacOS/Veloce"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Source travels with every update; Python environments and model caches live
# outside the signed bundle and are managed by Engine/bootstrap.sh.
rsync -a --exclude='.*' --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='test_*' --exclude='smoke.py' --exclude='README.md' \
    "$ROOT/Engine/" "$APP/Contents/Resources/Engine/"
UV_BIN="${VELOCE_UV_BIN:-$(command -v uv || true)}"
[[ -n "$UV_BIN" && -x "$UV_BIN" ]] || { echo "uv is required to package the local engine (set VELOCE_UV_BIN)." >&2; exit 1; }
cp -L "$UV_BIN" "$APP/Contents/Resources/uv"
chmod 755 "$APP/Contents/Resources/uv"
UV_LICENSE_DIR="${VELOCE_UV_LICENSE_DIR:-$(dirname "$(dirname "$(realpath "$UV_BIN")")")}"
mkdir -p "$APP/Contents/Resources/Licenses"
for license in LICENSE-MIT LICENSE-APACHE; do
    [[ -f "$UV_LICENSE_DIR/$license" ]] || { echo "Missing uv $license; set VELOCE_UV_LICENSE_DIR to its license directory." >&2; exit 1; }
    cp "$UV_LICENSE_DIR/$license" "$APP/Contents/Resources/Licenses/uv-$license"
done
# A copied uv must be standalone, rather than depending on this Mac's Homebrew.
if otool -L "$APP/Contents/Resources/uv" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/|$)' >/dev/null; then
    echo "uv links non-system libraries; supply a standalone macOS uv binary." >&2
    exit 1
fi
SPARKLE_FRAMEWORK="${VELOCE_SPARKLE_FRAMEWORK:-}"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    SPARKLE_FRAMEWORK="$(find "$ROOT/.build/artifacts" -type d -name Sparkle.framework -path '*/macos-*/*' -print -quit)"
fi
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Sparkle.framework was not resolved by SwiftPM." >&2; exit 1; }
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_FRAMEWORK/../../../LICENSE" "$APP/Contents/Resources/Licenses/Sparkle-LICENSE"
if [[ -n "${VELOCE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VELOCE_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${VELOCE_BUILD_NUMBER:-}" ]]; then
    [[ "$VELOCE_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Use an increasing numeric build number." >&2; exit 2; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VELOCE_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi
SIGN_IDENTITY="${VELOCE_SIGN_IDENTITY:--}"
SIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY")
HARDENED_RUNTIME="${VELOCE_HARDENED_RUNTIME:-0}"
if [[ "$SIGN_IDENTITY" == 'Developer ID Application:'* ]]; then HARDENED_RUNTIME=1; fi
if [[ "$SIGN_IDENTITY" != '-' && "$HARDENED_RUNTIME" == 1 ]]; then
    SIGN_OPTIONS+=(--options runtime --timestamp)
fi
# Sign from the inside out. --deep is for verification, never for signing.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK"
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Resources/uv"
codesign "${SIGN_OPTIONS[@]}" --identifier com.veloce.dictation "$APP"
codesign --verify --deep --strict "$APP"
# Replace only after a complete, verified bundle is available.
if [[ -e "$OUTPUT" ]]; then
    mv "$OUTPUT" "$STAGING/previous.app"
fi
mv "$APP" "$OUTPUT"
printf 'Built %s\n' "$OUTPUT"
if [ "${1:-}" = "--open" ]; then open "$OUTPUT"; fi
