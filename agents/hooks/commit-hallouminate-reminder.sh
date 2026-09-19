#!/usr/bin/env bash
# Stop / turn-end hook: after a commit that leaves wiki or corpus changes
# uncommitted, remind the agent to include its hallouminate knowledge files
# so they are not left behind. One classifier, three harness adapters:
#
#   claude  — Stop hook, emits hookSpecificOutput.additionalContext (model-
#             visible "Stop hook feedback", the non-error guidance path).
#   codex   — Stop hook, emits {decision:"block", reason} — Codex has NO
#             additionalContext for Stop, so a block-continuation is the only
#             way to reach the model (verified: developers.openai.com/codex/hooks).
#   omp     — invoked as `bash <script> --omp <session_id>` by the native OMP
#             session_stop extension, which reads the bare reminder text off
#             stdout and wraps it into SessionStopEventResult.additionalContext.
#
# Harness identity comes from the renderer-set DOTFILES_HARNESS env (claude|
# codex; default claude) for the Claude/Codex Stop hook, and from the `--omp`
# argv flag for the OMP extension path — see wiki architecture/cross-harness-guards.
#
# "Only after a commit" is approximated by a recency window: the reminder fires
# only when HEAD was committed within HALLOUMINATE_COMMIT_REMINDER_WINDOW seconds
# (default 300) AND `hallouminate wiki status` finds unstaged or untracked
# knowledge files. The command resolves every configured wiki and corpus root.
#
# A per-session, per-HEAD state file fires the reminder at most once per commit,
# so Codex's block-continuation (and Claude's) cannot loop.
#
# Fail-open: missing git/jq/hallouminate, invalid stdin, a non-repo cwd, or any error
# exits 0 with no output — a reminder must never block or crash a turn. Opt out
# for a session with HALLOUMINATE_COMMIT_REMINDER=0.

set -u

[[ "${HALLOUMINATE_COMMIT_REMINDER:-1}" == "0" ]] && exit 0

command -v git >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v hallouminate >/dev/null 2>&1 || exit 0

# ── Harness + inputs ───────────────────────────────────────────────────────
# OMP path: `--omp <session_id>`, no stdin. Claude/Codex: DOTFILES_HARNESS env
# + a Stop payload on stdin (session_id, cwd, stop_hook_active).
session=""
cwd=""
if [[ "${1:-}" == "--omp" ]]; then
    harness=omp
    session="${2:-}"
else
    harness="${DOTFILES_HARNESS:-claude}"
    case "$harness" in claude | codex) ;; *) harness=claude ;; esac
    input="$(cat)"
    if [[ -n "$input" ]]; then
        # Loop guard: never re-fire while already continuing from a prior Stop run.
        [[ "$(jq -r '.stop_hook_active // empty' <<<"$input" 2>/dev/null)" == "true" ]] && exit 0
        session="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
        cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
    fi
fi
[[ -n "$cwd" ]] || cwd="$PWD"

# ── Repo + dirty-knowledge gate ─────────────────────────────────────────────
report="$(hallouminate wiki status --cwd "$cwd" --json 2>/dev/null)" || exit 0
root="$(jq -r '.git_root // empty' <<<"$report" 2>/dev/null)"
count="$(jq -r '.count // empty' <<<"$report" 2>/dev/null)"
[[ -n "$root" && "$count" =~ ^[0-9]+$ ]] || exit 0
(( count > 0 )) || exit 0

# ── "Committed this turn" gate (recency window) ────────────────────────────
head="$(git -C "$root" rev-parse HEAD 2>/dev/null)" || exit 0
[[ -n "$head" ]] || exit 0  # no commits yet → nothing was committed
ctime="$(git -C "$root" log -1 --format=%ct 2>/dev/null)" || exit 0
[[ "$ctime" =~ ^[0-9]+$ ]] || exit 0
now="$(date +%s)"
window="${HALLOUMINATE_COMMIT_REMINDER_WINDOW:-300}"
[[ "$window" =~ ^[0-9]+$ ]] || window=300
(( now - ctime <= window )) || exit 0  # last commit is old → not this turn

# ── Fire-once-per-commit-per-session guard (prevents continuation loops) ───
key="${session//[^A-Za-z0-9_-]/_}"
[[ -n "$key" ]] || key=default
state_dir="${TMPDIR:-/tmp}/hallouminate-commit-reminder"
state_file="$state_dir/$key"
if [[ -f "$state_file" ]] && [[ "$(cat "$state_file" 2>/dev/null)" == "$head" ]]; then
    exit 0
fi
mkdir -p "$state_dir" 2>/dev/null && printf '%s' "$head" >"$state_file" 2>/dev/null

# ── Emit the reminder in the harness-native shape ──────────────────────────
msg="A commit was just made, but hallouminate wiki or corpus files still have unstaged or untracked changes. If those changes belong with this work, stage and commit them so they are not left behind. Run 'hallouminate wiki status' to list them."

case "$harness" in
    claude)
        jq -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$c}}'
        ;;
    codex)
        jq -cn --arg r "$msg" '{decision:"block",reason:$r}'
        ;;
    omp)
        printf '%s\n' "$msg"
        ;;
esac
exit 0
