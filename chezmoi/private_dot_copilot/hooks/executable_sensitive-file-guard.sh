#!/usr/bin/env bash
# Copilot CLI preToolUse adapter: block reads/writes of .env files, private
# keys, and credential stores. Parallel to the Cursor adapter and the opencode
# deny-list — Copilot has its own hook protocol, so it gets its own thin shim.
#
# Detection is NOT re-implemented here: this shim translates Copilot's
# preToolUse protocol to/from the shared Node logic in lib/sensitive-file-guard.js
# (the same module the Claude/Codex hook drives), so all harnesses share one
# source of truth for what counts as sensitive.
#
# Copilot protocol (verified: docs.github.com/en/copilot/reference/hooks-configuration):
#   stdin  : {sessionId, timestamp, cwd, toolName, toolArgs}
#            toolArgs may be a JSON object OR a JSON-encoded string — handle both.
#   deny   : print {"permissionDecision":"deny","permissionDecisionReason":"..."}
#            to stdout and exit 0. Allow = exit 0 with no stdout.
#   exit   : non-zero (other than the permissionRequest-only 2) is logged and
#            execution CONTINUES — so we fail-open on every internal error.
#
# Tool-name map (Copilot -> shared-logic shape):
#   bash, powershell         -> Bash  (tool_input.command)
#   view, edit, create       -> Read  (tool_input.path) — Read/Edit sets in the
#                                       shared logic both resolve a single path.
#
# Opt-out / allow-list (parity with the other adapters; consumed by the JS):
#   CLAUDE_SENSITIVE_GUARD=0|false|off|no        -> disable
#   CLAUDE_SENSITIVE_GUARD_ALLOW=substr,/abs,...  -> allow matching paths

set -u

case "$(printf '%s' "${CLAUDE_SENSITIVE_GUARD:-}" | tr '[:upper:]' '[:lower:]')" in
    0|false|off|no) exit 0 ;;
esac

command -v jq   >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGIC="$SCRIPT_DIR/lib/sensitive-file-guard.js"
[[ -f "$LOGIC" ]] || exit 0

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.toolName // ""' 2>/dev/null)" || exit 0
[[ -n "$tool" ]] || exit 0

# toolArgs is documented as `unknown` and may arrive as an object or a
# JSON-encoded string. Normalize to an object; bail open if it won't parse.
args="$(printf '%s' "$payload" | jq -c '
    if (.toolArgs | type) == "string" then (.toolArgs | fromjson)
    else .toolArgs end
' 2>/dev/null)" || exit 0
[[ -n "$args" && "$args" != "null" ]] || exit 0

# Build the shared-logic PreToolUse event for the mapped tool.
case "$tool" in
    bash|powershell)
        event="$(jq -nc --argjson a "$args" \
            '{tool_name:"Bash", tool_input:{command:($a.command // "")}}' 2>/dev/null)" || exit 0
        ;;
    view|edit|create)
        event="$(jq -nc --argjson a "$args" \
            '{tool_name:"Read", tool_input:{path:($a.path // $a.file_path // "")}}' 2>/dev/null)" || exit 0
        ;;
    *)
        exit 0 ;;  # not a file/shell tool — nothing to guard
esac

# Run the shared logic. It emits a Claude-shaped deny on stdout, or nothing.
decision="$(printf '%s' "$event" | node "$LOGIC" 2>/dev/null)" || exit 0
[[ -n "$decision" ]] || exit 0  # allow

reason="$(printf '%s' "$decision" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
[[ -n "$reason" ]] || reason="Blocked: tool touches a sensitive file (.env, private key, or credential store)."

jq -nc --arg r "$reason" '{permissionDecision:"deny", permissionDecisionReason:$r}'
exit 0
