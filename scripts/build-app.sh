#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-module-cache"
SWIFT_OPTIONS=(--cache-path "$ROOT/.build/cache" --config-path "$ROOT/.build/config" --security-path "$ROOT/.build/security" --disable-sandbox)
xcrun swift build -c release "${SWIFT_OPTIONS[@]}"
BIN="$(xcrun swift build -c release --show-bin-path "${SWIFT_OPTIONS[@]}")"
APP="$ROOT/build/Veloce.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Veloce" "$APP/Contents/MacOS/Veloce"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Development build: reuse the persistent, managed environment in the checkout.
# This path is intentionally explicit; release packaging will ship a signed runtime.
/usr/libexec/PlistBuddy -c "Add :VeloceEngineDirectory string $ROOT/Engine" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi
codesign --force --sign - --identifier com.veloce.dictation "$APP"
printf 'Built %s\n' "$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
