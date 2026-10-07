#!/bin/bash
set -euo pipefail
ENGINE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ENGINE_DIR"
# The bundle is immutable. Development still defaults to its checkout environment.
if [[ -n "${VELOCE_ENGINE_RUNTIME_DIR:-}" ]]; then
  RUNTIME_DIR="$VELOCE_ENGINE_RUNTIME_DIR"
elif [[ "$ENGINE_DIR" == */Contents/Resources/Engine ]]; then
  RUNTIME_DIR="$HOME/Library/Application Support/Veloce/Engine"
else
  RUNTIME_DIR="$ENGINE_DIR"
fi
if [[ "$(uname -m)" != "arm64" || "$(uname -s)" != "Darwin" ]]; then
  echo "Véloce requires an Apple Silicon Mac." >&2
  exit 1
fi
UV_BIN="${VELOCE_UV_BIN:-}"
if [[ -z "$UV_BIN" && -x "$ENGINE_DIR/../uv" ]]; then
  UV_BIN="$ENGINE_DIR/../uv"
fi
if [[ -z "$UV_BIN" ]]; then
  UV_BIN="$(command -v uv || true)"
fi
if [[ -z "$UV_BIN" && -x /opt/homebrew/bin/uv ]]; then
  UV_BIN=/opt/homebrew/bin/uv
fi
if [[ -z "$UV_BIN" ]]; then
  echo "Install uv (https://docs.astral.sh/uv/getting-started/installation/) and run this script again." >&2
  exit 1
fi
export UV_CACHE_DIR="${UV_CACHE_DIR:-$RUNTIME_DIR/.uv-cache}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$RUNTIME_DIR/.python}"
export UV_PROJECT_ENVIRONMENT="$RUNTIME_DIR/.venv"
# Keep previously selected optional backends when installing another feature.
ARGS=(sync --frozen --inexact --python 3.12)
PARAKEET=false
MEETINGS=false
for option in "$@"; do
  case "$option" in
    --parakeet) PARAKEET=true ;;
    --meetings) MEETINGS=true ;;
    *) echo "Usage: bootstrap.sh [--parakeet] [--meetings]" >&2; exit 2 ;;
  esac
done
mkdir -p "$RUNTIME_DIR"
if [[ "$RUNTIME_DIR" != "$ENGINE_DIR" ]]; then
  # Never make an installed app depend on a Homebrew Python or a checkout path.
  ARGS+=(--managed-python)
fi
if $PARAKEET || [[ -f "$RUNTIME_DIR/.extra-parakeet" ]]; then
  PARAKEET=true
  ARGS+=(--extra parakeet)
fi
if $MEETINGS || [[ -f "$RUNTIME_DIR/.extra-meetings" ]]; then
  MEETINGS=true
  ARGS+=(--extra meetings)
fi
# Forward cancellation now that this wrapper must remain to write ready markers.
UV_PID=""
trap 'if [[ -n "$UV_PID" ]]; then kill -TERM "$UV_PID" 2>/dev/null || true; fi; exit 130' INT TERM
"$UV_BIN" "${ARGS[@]}" &
UV_PID=$!
wait "$UV_PID"
UV_PID=""
# Only declare this dependency set ready after a successful synchronization.
cp "$ENGINE_DIR/uv.lock" "$RUNTIME_DIR/.installed-uv.lock"
cp "$ENGINE_DIR/pyproject.toml" "$RUNTIME_DIR/.installed-pyproject.toml"
if $PARAKEET; then touch "$RUNTIME_DIR/.extra-parakeet"; fi
if $MEETINGS; then touch "$RUNTIME_DIR/.extra-meetings"; fi
