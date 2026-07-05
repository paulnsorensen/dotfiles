#!/usr/bin/env bash
# PreToolUse hook (Claude-only): when a reasoning-heavy skill — briesearch,
# culture, spec, or mold — is invoked at an effort BELOW `high`, inject an
# additionalContext nudge suggesting a checkpoint-and-relaunch on opus/xhigh for
# deeper synthesis. Hooks cannot change model/effort mid-session (model is read
# once at session start; effort only via the interactive /effort command), so a
# nudge is the ceiling of what is buildable. Gated to effort < high so an
# already-deep session is never nagged.
#
# Fail-silent: a missing jq, empty/garbage stdin, an unknowable effort, or a
# non-target skill must never block or noise a Skill call — the hook only
# suggests, it must not become a denial-of-service. Every non-firing path exits
# 0 with no stdout.
#
# The Skill tool's tool_input field that carries the skill name is undocumented,
# so the name is read defensively from .skill, .name, or the first token of
# .command (a leading slash is stripped). Effort is read from .effort.level,
# falling back to $CLAUDE_EFFORT.

set -u

DEEP_SKILLS_RE='^(briesearch|culture|spec|mold)$'

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
[[ -n "$input" ]] || exit 0

# Fire only for the Skill tool.
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
[[ "$tool" == "Skill" ]] || exit 0

# Skill name: .skill | .name | first token of .command, minus a leading slash.
raw="$(printf '%s' "$input" | jq -r '.tool_input.skill // .tool_input.name // .tool_input.command // empty' 2>/dev/null)" || exit 0
skill="${raw%%[[:space:]]*}"
skill="${skill#/}"
[[ "$skill" =~ $DEEP_SKILLS_RE ]] || exit 0

# Current effort: payload first, then the env var. Unknowable → stay silent.
effort="$(printf '%s' "$input" | jq -r '.effort.level // empty' 2>/dev/null)"
[[ -n "$effort" ]] || effort="${CLAUDE_EFFORT:-}"
case "$effort" in
    low | medium) ;;   # below high → nudge
    *) exit 0 ;;       # high | xhigh | max | unknown → silent
esac

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "This is a reasoning-heavy synthesis skill running below `high` effort. Before diving in, offer the user a deeper path: run /wheypoint to write a resumable checkpoint, then relaunch on Opus at xhigh effort (Opus is the default model; run /effort xhigh or relaunch the session) for the hardest synthesis. Hooks cannot switch model/effort mid-session, so this is a suggestion the user opts into — do not block or auto-switch."
  }
}
EOF
exit 0
