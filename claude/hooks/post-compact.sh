#!/usr/bin/env bash
# post-compact.sh — Restore working context after compaction
# Runs as a SessionStart hook with matcher "compact".
# Re-injects saved file paths and commands so the agent can resume.

set -euo pipefail

CONTEXT_FILE="$HOME/.claude/.compaction-context"
SAVED_CONTEXT=""

if [[ -f "$CONTEXT_FILE" ]]; then
  SAVED_CONTEXT=$(<"$CONTEXT_FILE")
  rm -f "$CONTEXT_FILE"
fi

REMINDER="COMPACTION COMPLETE — context restored. Use cheese-flow:cheez-search for AST-aware code/content search. Use cheese-flow:cheez-read for code reading and cheese-flow:cheez-write for hash-anchored edits."

if [[ -n "$SAVED_CONTEXT" ]]; then
  FULL_CONTEXT="$REMINDER

SAVED CONTEXT:
$SAVED_CONTEXT"
else
  FULL_CONTEXT="$REMINDER"
fi

jq -n --arg ctx "$FULL_CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $ctx
  }
}'
