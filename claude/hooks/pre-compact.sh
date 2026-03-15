#!/bin/bash
# pre-compact.sh — Save session context before compaction
# Extracts recent file paths and commands from the transcript
# so post-compact can re-inject working context.
# Uses per-line jq parsing for robustness with malformed JSON.

set -euo pipefail

INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty') || true
CONTEXT_FILE="$HOME/.claude/.compaction-context"

if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  exit 0
fi

# Extract recent file paths: cap bytes first to prevent choking on huge lines
FILES=$(tail -c 100000 "$TRANSCRIPT" | tail -200 | while IFS= read -r line; do
  echo "$line" | jq -r '.tool_input.file_path // empty' 2>/dev/null
done | grep -v '^$' | sort -u | tail -20 || true)

# Extract recent bash commands: cap bytes first to prevent choking on huge lines
COMMANDS=$(tail -c 100000 "$TRANSCRIPT" | tail -200 | while IFS= read -r line; do
  echo "$line" | jq -r 'select(.tool_input.command) | .tool_input.command' 2>/dev/null
done | grep -v '^$' | tail -10 || true)

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
