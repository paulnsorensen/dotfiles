#!/usr/bin/env bats
# Tests for bin/cc-salvage and bin/lib/cc-salvage.sh — reopen dead Claude
# sessions from the ~/.claude/sessions registry in tmux windows.

load test_helper

setup() {
    setup_test_env
    export CC_SALVAGE_PROC_DIR="$TEST_HOME/proc"
    export DOTFILES_DIR="$TEST_HOME/dotfiles"
    mkdir -p "$CC_SALVAGE_PROC_DIR" "$HOME/.claude/sessions" "$TEST_HOME/stub-bin" "$DOTFILES_DIR/agents"
    : > "$DOTFILES_DIR/agents/preamble.md"
    TMUX_LOG="$TEST_HOME/tmux.log"
    export TMUX_LOG
    : > "$TMUX_LOG"
    # Stub tmux: log every call; report "main" as the current session.
    cat > "$TEST_HOME/stub-bin/tmux" <<'EOF'
#!/usr/bin/env bash
call="$*"
printf '%s\n' "${call//$'\n'/ }" >> "$TMUX_LOG"
[[ "$1" == display-message ]] && echo main
if [[ "$1" == new-window && -n "${TMUX_COMMAND_FILE:-}" ]]; then
    shift 8 # new-window -d -t target -n name -c cwd
    printf '%q ' "$@" > "$TMUX_COMMAND_FILE"
fi
exit 0
EOF
    chmod +x "$TEST_HOME/stub-bin/tmux"
    export PATH="$TEST_HOME/stub-bin:$PATH"
    export TMUX=/tmp/fake,1,0
    export TZ=UTC CC_SALVAGE_NOW=1767268800
    WT="$TEST_HOME/repo/.worktrees/feat"
    mkdir -p "$WT"
}

teardown() {
    teardown_test_env
}

# add_session <pid> <session-id> <cwd> [entrypoint] [procStart]
add_session() {
    local pid="$1" sid="$2" cwd="$3" entry="${4:-cli}" start="${5:-111}"
    jq -n --argjson pid "$pid" --arg sid "$sid" --arg cwd "$cwd" --arg entry "$entry" --arg start "$start" \
        '{pid: $pid, sessionId: $sid, cwd: $cwd, kind: "interactive", entrypoint: $entry, procStart: $start, name: ("win-" + ($pid|tostring))}' \
        > "$HOME/.claude/sessions/$pid.json"
}

# add_transcript <session-id> <minutes-before-NOW>
# NOW is 2026-01-01 12:00 UTC; touch -t keeps this portable to BSD.
add_transcript() {
    local dir="$HOME/.claude/projects/-proj" m=$(( 720 - $2 ))
    mkdir -p "$dir"
    echo '{}' > "$dir/$1.jsonl"
    touch -t "$(printf '20260101%02d%02d' $(( m / 60 )) $(( m % 60 )))" "$dir/$1.jsonl"
}

# mark_live <pid> <procStart> — fake /proc/<pid>/stat with field 22 set.
mark_live() {
    mkdir -p "$CC_SALVAGE_PROC_DIR/$1"
    echo "$1 (claude code) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $2 19 20" > "$CC_SALVAGE_PROC_DIR/$1/stat"
}

# Save the detached command so each test can run it after cc-salvage returns.
capture_resume() {
    export TMUX_COMMAND_FILE="$TEST_HOME/resume.sh"
    cat > "$TEST_HOME/stub-bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${CLAUDE_REPLACEMENT:-}" ]]; then
    cp "$CLAUDE_REPLACEMENT" "$HOME/.claude/sessions/501.json"
fi
exit "${CLAUDE_EXIT_CODE:-0}"
EOF
    chmod +x "$TEST_HOME/stub-bin/claude"
}

@test "a dead session in the window opens one tmux window that resumes it in its cwd" {
    add_session 501 aaaa1111-0000-0000-0000-000000000001 "$WT"
    add_transcript aaaa1111-0000-0000-0000-000000000001 30

    run cc-salvage --since 2h
    assert_success
    assert_output_contains "aaaa1111-0000-0000-0000-000000000001"
    assert_output_contains "resumed"
    run grep -F "new-window -d -t main: -n win-501 -c $WT" "$TMUX_LOG"
    assert_success
    assert_output_contains "--system-prompt-file $DOTFILES_DIR/agents/preamble.md --resume aaaa1111-0000-0000-0000-000000000001"
}

@test "a session whose process still runs is not resumed" {
    add_session 502 bbbb2222-0000-0000-0000-000000000002 "$WT" cli 777
    add_transcript bbbb2222-0000-0000-0000-000000000002 5
    mark_live 502 777

    run cc-salvage --since 2h
    assert_success
    assert_output_not_contains "bbbb2222"
    run grep -c new-window "$TMUX_LOG"
    [[ "$output" == 0 ]]
}

@test "a reused pid with a different start time counts as dead" {
    add_session 503 cccc3333-0000-0000-0000-000000000003 "$WT" cli 777
    add_transcript cccc3333-0000-0000-0000-000000000003 5
    mark_live 503 999

    run cc-salvage --since 2h --dry-run
    assert_success
    assert_output_contains "cccc3333"
}

@test "a session id with a live registry entry elsewhere is not resumed" {
    add_session 504 dddd4444-0000-0000-0000-000000000004 "$WT" cli 111
    add_session 505 dddd4444-0000-0000-0000-000000000004 "$WT" cli 222
    add_transcript dddd4444-0000-0000-0000-000000000004 5
    mark_live 505 222

    run cc-salvage --since 2h --dry-run
    assert_success
    assert_output_not_contains "dddd4444"
}

@test "headless sdk-cli sessions are ignored" {
    add_session 506 eeee5555-0000-0000-0000-000000000005 "$WT" sdk-cli
    add_transcript eeee5555-0000-0000-0000-000000000005 5

    run cc-salvage --since 2h --dry-run
    assert_success
    assert_output_not_contains "eeee5555"
}

@test "Remote Control sessions (sdk-cli with a bridge id) are resumed" {
    add_session 514 baba0000-0000-0000-0000-000000000014 "$WT" sdk-cli
    jq '. + {bridgeSessionId: "session_x"}' "$HOME/.claude/sessions/514.json" > "$TEST_HOME/514.json"
    mv "$TEST_HOME/514.json" "$HOME/.claude/sessions/514.json"
    add_transcript baba0000-0000-0000-0000-000000000014 5

    run cc-salvage --since 2h --dry-run
    assert_success
    assert_output_contains "baba0000"
}

@test "sessions outside the time window are ignored" {
    add_session 507 ffff6666-0000-0000-0000-000000000006 "$WT"
    add_transcript ffff6666-0000-0000-0000-000000000006 300
    add_session 508 ffff7777-0000-0000-0000-000000000007 "$WT"
    add_transcript ffff7777-0000-0000-0000-000000000007 10

    run cc-salvage --since 2h --until 30m --dry-run
    assert_success
    assert_output_not_contains "ffff6666"
    assert_output_not_contains "ffff7777"

    run cc-salvage --since 6h --until 30m --dry-run
    assert_output_contains "ffff6666"
}

@test "--dry-run lists candidates and opens no window" {
    add_session 509 abab0000-0000-0000-0000-000000000009 "$WT"
    add_transcript abab0000-0000-0000-0000-000000000009 5

    run cc-salvage --dry-run
    assert_success
    assert_output_contains "dry-run"
    run grep -c new-window "$TMUX_LOG"
    [[ "$output" == 0 ]]
}

@test "a session whose cwd is gone is reported and skipped" {
    add_session 510 acac0000-0000-0000-0000-000000000010 "$TEST_HOME/gone"
    add_transcript acac0000-0000-0000-0000-000000000010 5

    run cc-salvage --since 2h
    assert_success
    assert_output_contains "skipped:cwd-missing"
    run grep -c new-window "$TMUX_LOG"
    [[ "$output" == 0 ]]
}

@test "--limit resumes only the newest sessions" {
    add_session 511 adad0000-0000-0000-0000-000000000011 "$WT"
    add_transcript adad0000-0000-0000-0000-000000000011 5
    add_session 512 aeae0000-0000-0000-0000-000000000012 "$WT"
    add_transcript aeae0000-0000-0000-0000-000000000012 50

    run cc-salvage --since 2h --limit 1
    assert_success
    run grep -c new-window "$TMUX_LOG"
    [[ "$output" == 1 ]]
    run grep -c adad0000 "$TMUX_LOG"
    [[ "$output" == 1 ]]
}

@test "outside tmux the windows go to a detached salvage session" {
    unset TMUX
    add_session 513 afaf0000-0000-0000-0000-000000000013 "$WT"
    add_transcript afaf0000-0000-0000-0000-000000000013 5

    run cc-salvage --since 2h
    assert_success
    run grep -F "new-window -d -t salvage:" "$TMUX_LOG"
    assert_success
}

@test "an invalid duration fails with a usage error" {
    run cc-salvage --since yesterday
    assert_failure
    assert_output_contains "duration"
}

@test "duration counts use decimal for every unit including seconds" {
    source "$REAL_DOTFILES_DIR/bin/lib/cc-salvage.sh"
    local unit expected
    for unit in s m h d; do
        case "$unit" in
            s) expected=9 ;;
            m) expected=540 ;;
            h) expected=32400 ;;
            d) expected=777600 ;;
        esac
        run salvage_duration_secs "009$unit"
        assert_success
        [[ "$output" == "$expected" ]]
    done

    run salvage_duration_secs 010m
    assert_success
    [[ "$output" == 600 ]]
}

@test "leading-zero durations and limits work through the CLI" {
    add_session 501 decimal-session "$WT"
    add_transcript decimal-session 9

    run cc-salvage --since 010m --until 008s --limit 008 --dry-run
    assert_success
    assert_output_contains "dry-run"

    run cc-salvage --limit 000 --dry-run
    assert_success
    assert_output_contains "skipped:limit"

    run cc-salvage --limit 08x
    [[ "$status" == 2 ]]
    assert_output_contains "--limit needs a number"
}

@test "a successful detached resume archives only the selected registry path" {
    capture_resume
    add_session 501 archive-session "$WT"
    add_transcript archive-session 5
    local record="$HOME/.claude/sessions/selected record's.json"
    mv "$HOME/.claude/sessions/501.json" "$record"
    cp "$record" "$TEST_HOME/expected.json"
    add_session 502 other-session "$WT"

    run cc-salvage
    assert_success
    [[ -f "$record" ]]
    [[ ! -d "$HOME/.claude/sessions/salvaged" ]]

    run bash "$TMUX_COMMAND_FILE"
    assert_success
    [[ ! -e "$record" ]]
    cmp "$TEST_HOME/expected.json" "$HOME/.claude/sessions/salvaged/${record##*/}"
    [[ -f "$HOME/.claude/sessions/502.json" ]]

    run cc-salvage --dry-run
    assert_success
    assert_output_not_contains "archive-session"
}

@test "a failed detached resume preserves the record for retry" {
    capture_resume
    export CLAUDE_EXIT_CODE=7
    add_session 501 retry-session "$WT"
    add_transcript retry-session 5
    cp "$HOME/.claude/sessions/501.json" "$TEST_HOME/expected.json"

    run cc-salvage
    assert_success
    run bash "$TMUX_COMMAND_FILE" <<< ''
    assert_output_contains "resume exited 7"
    cmp "$TEST_HOME/expected.json" "$HOME/.claude/sessions/501.json"
    [[ ! -d "$HOME/.claude/sessions/salvaged" ]]

    run cc-salvage --dry-run
    assert_success
    assert_output_contains "retry-session"
}

@test "a successful resume preserves records with any changed identity value" {
    capture_resume
    export CLAUDE_REPLACEMENT="$TEST_HOME/replacement.json"
    local field
    for field in pid procStart sessionId; do
        add_session 501 original-session "$WT"
        add_transcript original-session 5
        jq --arg field "$field" '.[$field] = (if $field == "pid" then 999 else "changed" end)' \
            "$HOME/.claude/sessions/501.json" > "$CLAUDE_REPLACEMENT"

        run cc-salvage
        assert_success
        run bash "$TMUX_COMMAND_FILE"
        assert_success
        cmp "$CLAUDE_REPLACEMENT" "$HOME/.claude/sessions/501.json"
        [[ ! -d "$HOME/.claude/sessions/salvaged" ]]
    done
}

@test "a missing procStart uses the same identity fallback during archival" {
    capture_resume
    add_session 501 fallback-session "$WT"
    add_transcript fallback-session 5
    jq 'del(.procStart)' "$HOME/.claude/sessions/501.json" > "$TEST_HOME/fallback.json"
    mv "$TEST_HOME/fallback.json" "$HOME/.claude/sessions/501.json"

    run cc-salvage
    assert_success
    run bash "$TMUX_COMMAND_FILE"
    assert_success
    [[ ! -e "$HOME/.claude/sessions/501.json" ]]
    [[ -f "$HOME/.claude/sessions/salvaged/501.json" ]]
}
