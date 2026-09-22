#!/usr/bin/env bats
# Tests for the commit-hallouminate-reminder Stop / turn-end hook.
#   agents/hooks/commit-hallouminate-reminder.sh — self-contained bash gate
#
# WHY: after a commit that leaves wiki or corpus changes uncommitted, the
# agent should be reminded to include its knowledge files. The hook fires
# ONLY when (a) `hallouminate wiki status` reports changes AND (b) HEAD was
# committed within the recency window ("committed this turn"), and at most once
# per commit per session (so Codex's block-continuation cannot loop). It emits a
# harness-native shape: additionalContext for claude, decision:block for codex,
# bare text for the omp extension. Everything else is fail-open silence.

load test_helper

HOOK="$REAL_DOTFILES_DIR/agents/hooks/commit-hallouminate-reminder.sh"

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v git >/dev/null 2>&1 || skip "git not installed"

    HALLOUMINATE_STUB_LOG="$TEST_HOME/hallouminate.log"
    export HALLOUMINATE_STUB_LOG
    mkdir -p "$TEST_HOME/bin"
    cat >"$TEST_HOME/bin/hallouminate" <<'BASH'
#!/usr/bin/env bash
[[ "${HALLOUMINATE_STUB_FAIL:-0}" == "0" ]] || exit 1
printf '%s\n' "$*" >>"$HALLOUMINATE_STUB_LOG"
[[ "$1 $2" == "wiki status" ]] || exit 2
shift 2
while (($#)); do
    case "$1" in
        --cwd) cwd="$2"; shift 2 ;;
        --json) shift ;;
        *) exit 2 ;;
    esac
done
root="$(git -C "$cwd" rev-parse --show-toplevel)" || exit 1
count=0
git -C "$root" diff --quiet -- .hallouminate/ || count=1
[[ -z "$(git -C "$root" ls-files --others --exclude-standard -- .hallouminate/)" ]] || count=1
jq -cn --arg root "$root" --argjson count "$count" '{git_root:$root,files:[],count:$count}'
BASH
    chmod +x "$TEST_HOME/bin/hallouminate"
    PATH="$TEST_HOME/bin:$PATH"
    export PATH

    # Keep the per-commit state file inside the sandbox so teardown removes it
    # and repeated suite runs never see stale guard state.
    export TMPDIR="$TEST_HOME"
    REPO="$TEST_HOME/repo"
}
teardown() { teardown_test_env; }

# Init a repo whose latest commit is recent and which has an uncommitted
# (untracked) file under .hallouminate/ — the canonical "committed but left the
# wiki out" state.
mk_repo_dirty() {
    mkdir -p "$REPO/.hallouminate/wiki"
    (
        cd "$REPO" || return 1
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo code >code.txt
        git add code.txt
        git commit -m "work" --quiet
        echo "new page" >.hallouminate/wiki/page.md
    )
}

# $1=session $2=cwd $3=stop_hook_active (default false)
stop_payload() {
    printf '{"session_id":"%s","cwd":"%s","stop_hook_active":%s}' "$1" "$2" "${3:-false}"
}

# ── Fires: recent commit + dirty knowledge file ─────────────────────────────

@test "claude: fires with additionalContext naming the status command" {
    mk_repo_dirty
    run bash "$HOOK" <<<"$(stop_payload s1 "$REPO")"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = "Stop" ]
    local ctx
    ctx="$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")"
    [[ "$ctx" == *"hallouminate wiki status"* ]]
    grep -Fxq "wiki status --cwd $REPO --json" "$HALLOUMINATE_STUB_LOG"
    # A passive reminder must never carry a block decision on claude.
    [ "$(jq -r '.decision // "none"' <<<"$output")" = "none" ]
}

@test "codex: fires with decision block + reason (its only model-reaching path)" {
    mk_repo_dirty
    run env DOTFILES_HARNESS=codex bash "$HOOK" <<<"$(stop_payload s1 "$REPO")"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" == *"hallouminate wiki status"* ]]
}

@test "omp: fires with bare reminder text (no JSON) for the session_stop extension" {
    mk_repo_dirty
    cd "$REPO"
    run bash "$HOOK" --omp s-omp
    [ "$status" -eq 0 ]
    [[ "$output" == *"hallouminate wiki status"* ]]
    # Bare text, not a JSON object.
    [[ "$output" != \{* ]]
}

# ── Silent: nothing to remind about ────────────────────────────────────────

@test "silent when knowledge changes were committed too" {
    mkdir -p "$REPO/.hallouminate/wiki"
    (
        cd "$REPO"
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo code >code.txt
        echo page >.hallouminate/wiki/page.md
        git add -A
        git commit -m "work + wiki" --quiet
    )
    run bash "$HOOK" <<<"$(stop_payload s1 "$REPO")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent when the knowledge change is staged" {
    mk_repo_dirty
    git -C "$REPO" add .hallouminate/wiki/page.md
    run bash "$HOOK" <<<"$(stop_payload s1 "$REPO")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent when the repo has no .hallouminate directory" {
    create_mock_repo "$REPO"
    run bash "$HOOK" <<<"$(stop_payload s1 "$REPO")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent when the last commit predates the recency window (not this turn)" {
    mkdir -p "$REPO/.hallouminate/wiki"
    (
        cd "$REPO"
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo code >code.txt
        git add code.txt
        GIT_COMMITTER_DATE="2020-01-01T00:00:00" git commit --date "2020-01-01T00:00:00" -m old --quiet
        echo page >.hallouminate/wiki/page.md
    )
    run bash "$HOOK" <<<"$(stop_payload s1 "$REPO")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent when already continuing from a prior stop hook (stop_hook_active)" {
    mk_repo_dirty
    run bash "$HOOK" <<<"$(stop_payload s1 "$REPO" true)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── Fire-once-per-commit guard ─────────────────────────────────────────────

@test "fires once per commit per session, then stays silent for the same HEAD" {
    mk_repo_dirty
    run bash "$HOOK" <<<"$(stop_payload dup "$REPO")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    # Same session, same HEAD, still dirty → suppressed (no continuation loop).
    run bash "$HOOK" <<<"$(stop_payload dup "$REPO")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fires again after a new commit (new HEAD) still omits .hallouminate" {
    mk_repo_dirty
    run bash "$HOOK" <<<"$(stop_payload rer "$REPO")"
    [ -n "$output" ]
    (
        cd "$REPO"
        echo more >>code.txt
        git add code.txt
        git commit -m "more work" --quiet
    )
    run bash "$HOOK" <<<"$(stop_payload rer "$REPO")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ── Opt-out + fail-open ────────────────────────────────────────────────────

@test "opt-out with HALLOUMINATE_COMMIT_REMINDER=0" {
    mk_repo_dirty
    run env HALLOUMINATE_COMMIT_REMINDER=0 bash "$HOOK" <<<"$(stop_payload s1 "$REPO")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fail-open: hallouminate wiki status fails" {
    mk_repo_dirty
    run env HALLOUMINATE_STUB_FAIL=1 bash "$HOOK" <<<"$(stop_payload s1 "$REPO")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fail-open: cwd is not a git repo" {
    mkdir -p "$TEST_HOME/plain"
    run bash "$HOOK" <<<"$(stop_payload s1 "$TEST_HOME/plain")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fail-open: empty stdin" {
    # No cwd in the payload → the hook falls back to $PWD; pin it to a non-repo
    # dir so the assertion never depends on the test runner's own repo state.
    mkdir -p "$TEST_HOME/plain"
    cd "$TEST_HOME/plain"
    run bash "$HOOK" <<<''
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fail-open: malformed JSON stdin" {
    mkdir -p "$TEST_HOME/plain"
    cd "$TEST_HOME/plain"
    run bash "$HOOK" <<<'{not json'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
