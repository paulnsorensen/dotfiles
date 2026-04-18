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

REMINDER="COMPACTION COMPLETE — context restored. Use tilth MCP (tilth_search/read/files/deps/edit) for code intelligence. Host Read/Grep/Glob/Edit are fallbacks only."

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
