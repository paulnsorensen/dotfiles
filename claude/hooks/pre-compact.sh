#!/bin/bash
# pre-compact.sh — Save session context before compaction
# Extracts recent file paths and commands from the transcript
# so post-compact can re-inject working context.

INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CONTEXT_FILE="$HOME/.claude/.compaction-context"

if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  exit 0
fi

# Extract recent file paths from tool calls (last 200 lines of transcript)
FILES=$(tail -200 "$TRANSCRIPT" | jq -r '
  .tool_input.file_path // empty
' 2>/dev/null | grep -v '^$' | sort -u | tail -20)

# Extract recent bash commands
COMMANDS=$(tail -200 "$TRANSCRIPT" | jq -r '
  select(.tool_input.command) | .tool_input.command
' 2>/dev/null | grep -v '^$' | tail -10)

{
  echo "# Session context saved before compaction"
  if [[ -n "$FILES" ]]; then
    echo "## Files recently touched"
    echo "$FILES"
  fi
  if [[ -n "$COMMANDS" ]]; then
    echo "## Recent commands"
    echo "$COMMANDS"
  fi
} > "$CONTEXT_FILE"

exit 0
