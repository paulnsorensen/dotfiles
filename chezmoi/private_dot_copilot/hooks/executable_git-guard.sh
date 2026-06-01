#!/usr/bin/env bash
# Copilot CLI preToolUse hook: block destructive git ops that discard
# uncommitted work — `git checkout -- <path>` / `git checkout .` / `-f`,
# `git restore`, `git reset --hard`, `git clean -f` — but ONLY when the
# targeted paths have uncommitted changes (clean tree → allowed, never nags).
#
# Copilot's preToolUse contract (verified: docs.github.com → cli-hooks-
# reference + copilot-cli-hooks tutorial):
#   • stdin JSON: { timestamp, cwd, toolName, toolArgs } where toolArgs is a
#     JSON *string* that must be parsed; for the shell tool it carries
#     `.command`. The CLI names the shell tool `bash`; the matcher in
#     git-guard.json also targets `shell` for SDK parity.
#   • Deny: write {"permissionDecision":"deny","permissionDecisionReason":...}
#     to stdout and exit 0. Allow: empty stdout, exit 0.
#   • Fail-open on any internal error (the guard hardens; it must never become
#     a denial-of-service) — covered by an early exit 0 on missing deps.
#
# Detection is the shared Node classifier (agents/lib/git-guard.js, the
# source-of-truth used by the Claude/Codex/Cursor guards) — this hook does
# NOT re-implement it, so the Copilot adapter can never drift. We resolve the
# dotfiles clone via $DOTFILES_DIR (exported by zsh/core.zsh), falling back to
# ~/Dev/dotfiles, rather than shipping a second copy of the JS through chezmoi.
#
# Opt-out (parity with the other adapters):
#   CLAUDE_GIT_GUARD=0|false|off|no   → disable entirely

set -u

case "$(printf '%s' "${CLAUDE_GIT_GUARD:-}" | tr '[:upper:]' '[:lower:]')" in
    0|false|off|no) exit 0 ;;
esac

command -v node >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

LOGIC="${DOTFILES_DIR:-$HOME/Dev/dotfiles}/agents/lib/git-guard.js"
[[ -f "$LOGIC" ]] || exit 0

payload="$(cat)"

tool="$(printf '%s' "$payload" | jq -r '.toolName // ""' 2>/dev/null)" || exit 0
case "$tool" in bash|shell) ;; *) exit 0 ;; esac

# toolArgs is a JSON string — parse it, then read .command. Bail (allow) if it
# isn't valid JSON.
command_line="$(printf '%s' "$payload" \
    | jq -r '.toolArgs // ""' 2>/dev/null \
    | jq -r '.command // ""' 2>/dev/null)" || exit 0
[[ -n "$command_line" ]] || exit 0

cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"
[[ -n "$cwd" ]] || cwd="$PWD"

# Call the shared classifier. It prints the deny reason and exits 7 on a
# block, exits 0 (no output) on allow, any other code on internal error.
reason="$(GIT_GUARD_COMMAND="$command_line" GIT_GUARD_CWD="$cwd" node -e 'require(process.argv[1]).cliCheck()' "$LOGIC" 2>/dev/null)"
rc=$?

if (( rc == 7 )); then
    jq -nc --arg r "$reason" \
        '{permissionDecision:"deny", permissionDecisionReason:$r}'
    exit 0
fi

# rc==0 → allow (empty stdout). Any other rc → node/lib error → fail-open.
exit 0
