#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$REPO_DIR/.frameworks/dotdrop/config.yaml"

if ! command -v dotdrop >/dev/null 2>&1; then
  printf 'dotdrop is not on PATH. Install it first, then re-run.
' >&2
  exit 1
fi

cd "$REPO_DIR"
exec dotdrop -c "$CONFIG" "$@"
