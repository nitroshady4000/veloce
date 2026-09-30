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
ARGS=(sync --frozen --python 3.12)
if [[ "${1:-}" == "--parakeet" ]]; then
  ARGS+=(--extra parakeet)
elif [[ $# -gt 0 ]]; then
  echo "Usage: bootstrap.sh [--parakeet]" >&2
  exit 2
fi
"$UV_BIN" "${ARGS[@]}"
echo "Véloce engine ready: $ENGINE_DIR/.venv/bin/python" >&2
