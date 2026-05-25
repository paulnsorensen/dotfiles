#!/usr/bin/env bash
# PreToolUse hook (Bash matcher): warn before destructive cargo calls.
# Exit 0 = allow; exit 2 (per Claude Code hook protocol) = block.

set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

case "$CMD" in
    *"cargo clean"*)
        echo "Blocking: 'cargo clean' wipes target/ — confirm with the user first." >&2
        exit 2 ;;
    *"cargo install"*"--force"*)
        echo "Blocking: 'cargo install --force' overwrites global binaries." >&2
        exit 2 ;;
esac

exit 0
