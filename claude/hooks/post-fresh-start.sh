#!/bin/bash
# post-fresh-start.sh — Prime Serena on fresh session start
# Skips if this is a post-compact session (handled by post-compact.sh)
# IMPORTANT: Must be listed BEFORE the compact hook in settings.json SessionStart array
# so it can detect the compaction context file before post-compact.sh deletes it.

CONTEXT_FILE="$HOME/.claude/.compaction-context"

# If the compaction context file exists, this is a post-compact session.
# Let post-compact.sh handle it — exit silently.
if [[ -f "$CONTEXT_FILE" ]]; then
  exit 0
fi

jq -n '{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Fresh session started. Run /go (or: activate_project → list_memories → read_memory) to prime Serena and load project context before starting work."
  }
}'
