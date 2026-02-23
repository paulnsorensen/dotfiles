#!/bin/bash
# post-compact.sh — Re-prime MCP tools after context compaction
# Runs as a SessionStart hook with matcher "compact".
# Injects imperative Serena re-activation directive + saved session context.

CONTEXT_FILE="$HOME/.claude/.compaction-context"
SAVED_CONTEXT=""
SAVED_PROJECT=""

if [[ -f "$CONTEXT_FILE" ]]; then
  SAVED_CONTEXT=$(cat "$CONTEXT_FILE")
  # Extract the saved working directory (second line after "## Working directory")
  SAVED_PROJECT=$(echo "$SAVED_CONTEXT" | grep -A1 "## Working directory" | tail -1)
  rm -f "$CONTEXT_FILE"
fi

REMINDER="COMPACTION COMPLETE — execute these steps NOW as your first action before responding:
1. mcp__serena__activate_project (project: ${SAVED_PROJECT:-infer from working directory})
2. mcp__serena__list_memories
3. mcp__serena__read_memory for session-context and any arch-* or gotcha-* memories
4. Report: 'Serena active, N memories loaded' then proceed to user's request

Execute the tools. Do not summarize. Do not skip."

if [[ -n "$SAVED_CONTEXT" ]]; then
  # Include saved context but skip the working directory line (already in step 1)
  CONTEXT_SUMMARY=$(echo "$SAVED_CONTEXT" | grep -v "## Working directory" | tail -n +2)
  FULL_CONTEXT="$REMINDER

SAVED CONTEXT:
$CONTEXT_SUMMARY"
else
  FULL_CONTEXT="$REMINDER"
fi

jq -n --arg ctx "$FULL_CONTEXT" '{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $ctx
  }
}'
