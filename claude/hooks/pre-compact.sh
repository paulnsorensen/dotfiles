#!/bin/bash
# pre-compact.sh — Save session context before compaction
# Extracts recent file paths and commands from the transcript
# so post-compact can re-inject working context.
# Uses per-line jq parsing for robustness with malformed JSON.

INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CONTEXT_FILE="$HOME/.claude/.compaction-context"

if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  exit 0
fi

# Extract recent file paths: per-line jq to skip malformed lines
FILES=$(tail -200 "$TRANSCRIPT" | while IFS= read -r line; do
  echo "$line" | jq -r '.tool_input.file_path // empty' 2>/dev/null
done | grep -v '^$' | sort -u | tail -20)

# Extract recent bash commands: per-line jq to skip malformed lines
COMMANDS=$(tail -200 "$TRANSCRIPT" | while IFS= read -r line; do
  echo "$line" | jq -r 'select(.tool_input.command) | .tool_input.command' 2>/dev/null
done | grep -v '^$' | tail -10)

{
  echo "# Session context saved before compaction"
  echo ""
  echo "## Working directory"
  echo "$PWD"
  if [[ -n "$FILES" ]]; then
    echo ""
    echo "## Files recently touched"
    echo "$FILES"
  fi
  if [[ -n "$COMMANDS" ]]; then
    echo ""
    echo "## Recent commands"
    echo "$COMMANDS"
  fi
} > "$CONTEXT_FILE"

exit 0
