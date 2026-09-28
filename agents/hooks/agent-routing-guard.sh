#!/usr/bin/env bash
# Self-locating PreToolUse bridge for the shared agent-routing guard.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"
LOGIC="$HARNESS_ROOT/lib/agent-routing-guard.js"

if [[ ! -f "$LOGIC" ]]; then
    printf '%s\n' "agent-routing-guard: missing logic file: $LOGIC" >&2
    exit 2
fi
if ! command -v node >/dev/null 2>&1; then
    printf '%s\n' 'agent-routing-guard: node is required' >&2
    exit 2
fi

exec node "$LOGIC"
