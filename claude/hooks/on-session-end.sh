#!/bin/bash
# on-session-end.sh — Detect session-end intent and remind to /park
# Runs as a UserPromptSubmit hook on every message; exits silently if no match.

set -euo pipefail

INPUT=$(cat)

# Extract the user's prompt — try common field names
PROMPT=$(echo "$INPUT" | jq -r '
  .prompt //
  .message //
  .content //
  .userMessage //
  empty
' 2>/dev/null) || true

if [[ -z "$PROMPT" ]]; then
  exit 0
fi

# Match common session-end phrases
if echo "$PROMPT" | grep -qiE \
  "\b(bye|goodbye|good night|goodnight|done for (the )?day|that'?s all|see you|signing off|wrapping up|ciao|all done|i'?m done|i'?m out|heading out|logging off|let'?s stop|stopping here)\b|^/park$"; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "UserPromptSubmit",
      "additionalContext": "The user is ending the session. Wrap up cleanly."
    }
  }'
else
  exit 0
fi
