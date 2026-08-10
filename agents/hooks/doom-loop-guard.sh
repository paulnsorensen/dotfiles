#!/usr/bin/env bash
# PreToolUse bridge for the shared Node doom-loop detector. Fail open if the
# deployed logic or runtime is unavailable.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"
LOGIC="$HARNESS_ROOT/lib/doom-loop-guard.js"

[[ -f "$LOGIC" ]] || exit 0
command -v node >/dev/null 2>&1 || exit 0

exec node "$LOGIC"
