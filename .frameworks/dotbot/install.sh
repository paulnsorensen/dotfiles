#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$REPO_DIR/.frameworks/dotbot/install.conf.yaml"
DOTBOT_BIN="${DOTBOT_BIN:-}"

if [[ -z "$DOTBOT_BIN" || ! -x "$DOTBOT_BIN" ]]; then
  printf 'Set DOTBOT_BIN to the real Dotbot entry point, then re-run.\n' >&2
  printf "Example: DOTBOT_BIN=%s %s\n" "$REPO_DIR/.frameworks/dotbot/vendor/dotbot/bin/dotbot" "$0" >&2
  exit 1
fi

cd "$REPO_DIR"
exec "$DOTBOT_BIN" -d "$REPO_DIR" -c "$CONFIG" "$@"
