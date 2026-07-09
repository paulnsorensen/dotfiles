#!/usr/bin/env bats
# Tests for bin/lib/resume.sh (post-reboot tmux resume) and `dots resume`.

load test_helper

setup() {
    setup_test_env
    # shellcheck source=bin/lib/resume.sh
    source "$REAL_DOTFILES_DIR/bin/lib/resume.sh"
}

teardown() {
    teardown_test_env
}

@test "resume_encode_claude_dir maps / to - including the leading slash" {
    run resume_encode_claude_dir "/home/paul/Dev/dotfiles"
    assert_success
    [[ "$output" == "-home-paul-Dev-dotfiles" ]]
}

@test "resume_encode_claude_dir maps dots in worktree paths too" {
    run resume_encode_claude_dir "/home/paul/Dev/dotfiles/.worktrees/x"
    assert_success
    [[ "$output" == "-home-paul-Dev-dotfiles--worktrees-x" ]]
}

@test "resume_claude_session picks the newest jsonl by mtime" {
    local proj="$HOME/.claude/projects/-home-paul-Dev-dotfiles"
    mkdir -p "$proj"
    : > "$proj/old-session.jsonl"
    touch -d '2 days ago' "$proj/old-session.jsonl"
    : > "$proj/new-session.jsonl"
    touch -d '1 hour ago' "$proj/new-session.jsonl"

    run resume_claude_session "/home/paul/Dev/dotfiles"
    assert_success
    [[ "$output" == "new-session	"* ]]
}

@test "resume_claude_session returns 1 when no project dir exists" {
    run resume_claude_session "/home/paul/Dev/nonexistent"
    [[ "$status" -eq 1 ]]
}

@test "resume_codex_session matches session_meta.payload.cwd within the last 7 days" {
    local sessions="$HOME/.codex/sessions/2026/07/08"
    mkdir -p "$sessions"
    local f="$sessions/rollout-2026-07-08T00-00-00-0000abcd-abcd-abcd-abcd-000000000001.jsonl"
    printf '{"payload":{"id":"0000abcd-abcd-abcd-abcd-000000000001","cwd":"/home/paul/Dev/dotfiles"}}\n' > "$f"

    run resume_codex_session "/home/paul/Dev/dotfiles"
    assert_success
    [[ "$output" == "0000abcd-abcd-abcd-abcd-000000000001	"* ]]
}

@test "resume_codex_session returns 1 when no rollout matches the cwd" {
    local sessions="$HOME/.codex/sessions/2026/07/08"
    mkdir -p "$sessions"
    local f="$sessions/rollout-2026-07-08T00-00-00-0000abcd-abcd-abcd-abcd-000000000002.jsonl"
    printf '{"payload":{"id":"0000abcd-abcd-abcd-abcd-000000000002","cwd":"/some/other/path"}}\n' > "$f"

    run resume_codex_session "/home/paul/Dev/dotfiles"
    [[ "$status" -eq 1 ]]
}

@test "resume_opencode_session finds the newest session for a directory" {
    local db="$TEST_HOME/opencode.db"
    sqlite3 "$db" "CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL, time_updated integer NOT NULL);"
    sqlite3 "$db" "INSERT INTO session (id, directory, time_updated) VALUES ('ses_old', '/home/paul/Dev/dotfiles', 1000000);"
    sqlite3 "$db" "INSERT INTO session (id, directory, time_updated) VALUES ('ses_new', '/home/paul/Dev/dotfiles', 9000000);"

    RESUME_OPENCODE_DB="$db" run resume_opencode_session "/home/paul/Dev/dotfiles"
    assert_success
    [[ "$output" == "ses_new	9000" ]]
}

@test "resume_opencode_session returns 1 when the db is missing" {
    RESUME_OPENCODE_DB="$TEST_HOME/no-such.db" run resume_opencode_session "/home/paul/Dev/dotfiles"
    [[ "$status" -eq 1 ]]
}

@test "resume_format_age renders days, hours, and minutes" {
    run resume_format_age 200000 100000
    assert_success
    [[ "$output" == "1d3h" ]]

    run resume_format_age 10000 6000
    assert_success
    [[ "$output" == "1h6m" ]]

    run resume_format_age 1000 700
    assert_success
    [[ "$output" == "5m" ]]
}

@test "resume_command_for produces the exact per-harness resume command" {
    run resume_command_for claude abc123
    [[ "$output" == "claude --resume abc123" ]]

    run resume_command_for codex 0000abcd-abcd-abcd-abcd-000000000001
    [[ "$output" == "codex resume 0000abcd-abcd-abcd-abcd-000000000001" ]]

    run resume_command_for opencode ses_new
    [[ "$output" == "opencode --session ses_new" ]]
}

# --- dots resume integration: mock tmux on PATH, verify table + send-keys ---

stub_tmux() {
    local bin_dir="$1" panes="$2"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/tmux" <<STUB
#!/bin/bash
case "\$1" in
    list-sessions)
        exit 0
        ;;
    has-session)
        exit 0
        ;;
    list-panes)
        printf '%s\n' '$panes'
        ;;
    send-keys)
        echo "SEND-KEYS: \$*" >> "$TEST_HOME/send-keys.log"
        ;;
    *)
        exit 0
        ;;
esac
STUB
    chmod +x "$bin_dir/tmux"
}

@test "dots resume --dry-run prints the table and sends no keys" {
    local proj="$HOME/.claude/projects/-home-paul-Dev-dotfiles"
    mkdir -p "$proj"
    : > "$proj/dry-run-session.jsonl"

    local bin_dir="$TEST_HOME/mockbin"
    stub_tmux "$bin_dir" "dotfiles	0	0	%1	/home/paul/Dev/dotfiles"
    PATH="$bin_dir:$PATH" run dots resume --dry-run

    assert_success
    assert_output_contains "PANE"
    assert_output_contains "%1"
    assert_output_contains "claude"
    assert_output_contains "dry-run-session"
    [[ ! -f "$TEST_HOME/send-keys.log" ]]
}

@test "dots resume (no --dry-run) types the resume command into the matched pane" {
    local proj="$HOME/.claude/projects/-home-paul-Dev-dotfiles"
    mkdir -p "$proj"
    : > "$proj/type-session.jsonl"

    local bin_dir="$TEST_HOME/mockbin"
    stub_tmux "$bin_dir" "dotfiles	0	0	%2	/home/paul/Dev/dotfiles"
    PATH="$bin_dir:$PATH" run dots resume

    assert_success
    [[ -f "$TEST_HOME/send-keys.log" ]]
    grep -qx -- "SEND-KEYS: send-keys -t %2 claude --resume type-session" "$TEST_HOME/send-keys.log"
    ! grep -qE -- "Enter|C-m" "$TEST_HOME/send-keys.log"
}

@test "dots resume skips panes with no resumable session" {
    local bin_dir="$TEST_HOME/mockbin"
    stub_tmux "$bin_dir" "dotfiles	0	0	%3	/no/agent/session/here"
    PATH="$bin_dir:$PATH" run dots resume --dry-run

    assert_success
    assert_output_contains "PANE"
    [[ "$output" != *"%3"* ]]
}
