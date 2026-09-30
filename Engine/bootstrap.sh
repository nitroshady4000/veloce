#!/bin/bash
set -euo pipefail
ENGINE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ENGINE_DIR"
if [[ "$(uname -m)" != "arm64" || "$(uname -s)" != "Darwin" ]]; then
  echo "Véloce requires an Apple Silicon Mac." >&2
  exit 1
fi
UV_BIN="${VELOCE_UV_BIN:-}"
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
export UV_CACHE_DIR="${UV_CACHE_DIR:-$ENGINE_DIR/.uv-cache}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$ENGINE_DIR/.python}"
# Keep previously selected optional backends when installing another feature.
ARGS=(sync --frozen --inexact --python 3.12)
for option in "$@"; do
  case "$option" in
    --parakeet) ARGS+=(--extra parakeet) ;;
    --meetings) ARGS+=(--extra meetings) ;;
    *) echo "Usage: bootstrap.sh [--parakeet] [--meetings]" >&2; exit 2 ;;
  esac
done
exec "$UV_BIN" "${ARGS[@]}"
