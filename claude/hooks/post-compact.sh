#!/bin/bash
# post-compact.sh — Re-prime MCP tools after context compaction
# Runs as a SessionStart hook with matcher "compact".
# Injects Serena re-activation reminder + saved session context.

CONTEXT_FILE="$HOME/.claude/.compaction-context"
SAVED_CONTEXT=""

if [[ -f "$CONTEXT_FILE" ]]; then
  SAVED_CONTEXT=$(cat "$CONTEXT_FILE")
  rm -f "$CONTEXT_FILE"
fi

REMINDER="IMPORTANT: Context was just compacted. To restore MCP capabilities:
1. Activate Serena (activate_project) for the current project
2. Read relevant Serena memories (list_memories, read_memory)
3. Use Serena tools (find_symbol, get_symbols_overview) for code navigation instead of grep"

if [[ -n "$SAVED_CONTEXT" ]]; then
  FULL_CONTEXT="$REMINDER

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
