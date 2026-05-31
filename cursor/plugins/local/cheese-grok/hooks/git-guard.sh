#!/usr/bin/env bash
# Cursor hook (beforeShellExecution): block destructive git ops that discard
# uncommitted work — `git checkout -- <path>` / `git checkout .` / `-f`,
# `git restore`, `git reset --hard`, `git clean -f` — but ONLY when the
# targeted paths have uncommitted changes (clean tree → allowed, never nags).
#
# Cursor's beforeShellExecution payload (stdin JSON) carries `.command` and
# `.cwd`. Cursor blocks on exit code 2 (parse-free deny); exit 0 allows.
# Fail-open on any internal error — a guard must never become a
# denial-of-service.
#
# Detection is the shared Node classifier — this hook does NOT re-implement
# it. It locates agents/lib/git-guard.js (the source-of-truth used by the
# Claude/Codex hook) and calls its `shouldBlock(command, cwd)` export, so the
# Cursor adapter and the PreToolUse hook can never drift.
#
# Locating the shared lib: chezmoi deploys this script to ~/.cursor/hooks/,
# which has no sibling copy of agents/lib. We resolve the dotfiles clone via
# $DOTFILES_DIR (exported by zsh/core.zsh), falling back to ~/Dev/dotfiles.
#
# Opt-out (parity with the Claude/Codex hook):
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
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null)" || exit 0
[[ "$event" == "beforeShellExecution" ]] || exit 0

command_line="$(printf '%s' "$payload" | jq -r '.command // ""' 2>/dev/null)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"
[[ -n "$command_line" ]] || exit 0
[[ -n "$cwd" ]] || cwd="$PWD"

# Call the shared classifier. The lib prints the deny reason on a block and
# nothing on allow; exit code drives Cursor's decision (2 = deny, 0 = allow).
reason="$(GIT_GUARD_COMMAND="$command_line" GIT_GUARD_CWD="$cwd" node -e '
  const g = require(process.argv[1]);
  const hit = g.shouldBlock(process.env.GIT_GUARD_COMMAND, process.env.GIT_GUARD_CWD);
  if (hit) { process.stdout.write(g.denyReason(process.env.GIT_GUARD_COMMAND, hit)); process.exit(7); }
  process.exit(0);
' "$LOGIC" 2>/dev/null)"
rc=$?

if (( rc == 7 )); then
    printf 'cheese-grok: %s\n' "$reason" >&2
    exit 2
fi

# rc==0 → allow. Any other rc → node/lib error → fail-open (allow).
exit 0
