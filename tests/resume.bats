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
    touch -t 202001010000 "$proj/old-session.jsonl"
    : > "$proj/new-session.jsonl"
    touch -t 202601010000 "$proj/new-session.jsonl"

    run resume_claude_session "/home/paul/Dev/dotfiles"
    assert_success
    [[ "$output" == "new-session	"* ]]
}

@test "resume_claude_session falls back to BSD stat mtimes" {
    local proj="$HOME/.claude/projects/-home-paul-Dev-dotfiles" bin_dir="$TEST_HOME/bsd-bin"
    mkdir -p "$proj" "$bin_dir"
    : > "$proj/old-session.jsonl"
    : > "$proj/new-session.jsonl"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\n[[ "$1" == "-c" ]] && exit 1\ncase "$3" in\n  *new-session*) echo 200 ;;\n  *) echo 100 ;;\nesac\n' > "$bin_dir/stat"
    chmod +x "$bin_dir/stat"

    PATH="$bin_dir:$PATH" run resume_claude_session "/home/paul/Dev/dotfiles"
    assert_success
    [[ "$output" == "new-session	200" ]]
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

# --- snapshot picker: list, format, point-at, pick ---

# seed_resurrect <name> <sessions-csv> <window-count> — write a minimal
# snapshot file under the resurrect dir with the requested state/window lines.
seed_resurrect() {
    local name="$1" sessions="$2" windows="$3" dir="$HOME/.tmux/resurrect" s w
    mkdir -p "$dir"
    local f="$dir/tmux_resurrect_${name}.txt"
    : > "$f"
    for ((w = 0; w < windows; w++)); do
        printf 'window\tsess\t%d\t:zsh\t1\t:*\tlayout\t:\n' "$w" >> "$f"
    done
    local IFS=,
    for s in $sessions; do
        printf 'state\t%s\n' "$s" >> "$f"
    done
}

@test "resume_snapshot_line summarizes sessions and window count" {
    seed_resurrect 20260610T075410 "crabbot,easy-cheese" 3
    run resume_snapshot_line "$HOME/.tmux/resurrect/tmux_resurrect_20260610T075410.txt"
    assert_success
    [[ "$output" == "tmux_resurrect_20260610T075410.txt	crabbot,easy-cheese	3	"* ]]
}

@test "resume_list_snapshots orders newest first by mtime" {
    seed_resurrect 20260610T070000 "old" 1
    seed_resurrect 20260610T090000 "new" 1
    touch -t 202606100700 "$HOME/.tmux/resurrect/tmux_resurrect_20260610T070000.txt"
    touch -t 202606100900 "$HOME/.tmux/resurrect/tmux_resurrect_20260610T090000.txt"

    run resume_list_snapshots
    assert_success
    [[ "${lines[0]}" == "tmux_resurrect_20260610T090000.txt	new	"* ]]
    [[ "${lines[1]}" == "tmux_resurrect_20260610T070000.txt	old	"* ]]
}

@test "resume_format_menu renders a bracketed sessions column and an age" {
    seed_resurrect 20260610T075410 "crabbot" 2
    touch -t 202606100754 "$HOME/.tmux/resurrect/tmux_resurrect_20260610T075410.txt"
    local saved now
    saved=$(resume_file_mtime "$HOME/.tmux/resurrect/tmux_resurrect_20260610T075410.txt")
    now=$((saved + 3600))

    run resume_format_menu "$now"
    assert_success
    [[ "$output" == "tmux_resurrect_20260610T075410.txt	[crabbot]	2win	1h0m" ]]
}

@test "resume_point_last accepts a bare timestamp and repoints the symlink" {
    seed_resurrect 20260610T075410 "crabbot" 1
    run resume_point_last 20260610T075410
    assert_success
    [[ "$(readlink "$HOME/.tmux/resurrect/last")" == "tmux_resurrect_20260610T075410.txt" ]]
}

@test "resume_point_last accepts a full basename too" {
    seed_resurrect 20260610T075410 "crabbot" 1
    run resume_point_last tmux_resurrect_20260610T075410.txt
    assert_success
    [[ "$(readlink "$HOME/.tmux/resurrect/last")" == "tmux_resurrect_20260610T075410.txt" ]]
}

@test "resume_point_last fails on a missing snapshot" {
    mkdir -p "$HOME/.tmux/resurrect"
    run resume_point_last 20990101T000000
    [[ "$status" -eq 1 ]]
    assert_output_contains "no snapshot"
}

@test "resume_pick_snapshot returns the basename of the fzf-chosen line" {
    seed_resurrect 20260610T075410 "crabbot" 1
    local bin_dir="$TEST_HOME/fzfbin"
    mkdir -p "$bin_dir"
    # Stub fzf: echo the first (only) menu line, mimicking a selection.
    printf '#!/usr/bin/env bash\nhead -1\n' > "$bin_dir/fzf"
    chmod +x "$bin_dir/fzf"

    RESUME_FZF="$bin_dir/fzf" run resume_pick_snapshot 9999999999
    assert_success
    [[ "$output" == "tmux_resurrect_20260610T075410.txt" ]]
}

@test "resume_pick_snapshot returns 1 when no snapshots exist" {
    mkdir -p "$HOME/.tmux/resurrect"
    run resume_pick_snapshot 9999999999
    [[ "$status" -eq 1 ]]
}

@test "resume_parse_args captures --restore with an explicit snapshot" {
    run resume_parse_args --restore 20260610T075410
    assert_success
    [[ "$output" == "false		true	20260610T075410" ]]
}

@test "resume_parse_args treats a bare --restore as picker mode" {
    run resume_parse_args --restore
    assert_success
    [[ "$output" == "false		true	" ]]
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
    run-shell)
        # Real tmux run-shell executes the command inside the server; mirror
        # that so the vendored restore.sh stub actually runs.
        exec bash -c "\$2"
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

@test "dots resume --dry-run reports the plan and sends no keys" {
    local proj="$HOME/.claude/projects/-home-paul-Dev-dotfiles"
    mkdir -p "$proj"
    : > "$proj/dry-run-session.jsonl"

    local bin_dir="$TEST_HOME/mockbin"
    stub_tmux "$bin_dir" "dotfiles	0	0	%1	/home/paul/Dev/dotfiles"
    PATH="$bin_dir:$PATH" run dots resume --dry-run

    assert_success
    assert_output_contains "dry-run"
    assert_output_contains "%1"
    assert_output_contains "claude --resume dry-run-session"
    [[ ! -f "$TEST_HOME/send-keys.log" ]]
}

@test "dots resume (no --dry-run) types AND runs the resume command in the matched pane" {
    local proj="$HOME/.claude/projects/-home-paul-Dev-dotfiles"
    mkdir -p "$proj"
    : > "$proj/type-session.jsonl"

    local bin_dir="$TEST_HOME/mockbin"
    stub_tmux "$bin_dir" "dotfiles	0	0	%2	/home/paul/Dev/dotfiles"
    PATH="$bin_dir:$PATH" run dots resume

    assert_success
    [[ -f "$TEST_HOME/send-keys.log" ]]
    # Command typed with a trailing Enter so it actually runs.
    grep -qx -- "SEND-KEYS: send-keys -t %2 claude --resume type-session Enter" "$TEST_HOME/send-keys.log"
}

@test "resume_main --restore repoints last and runs restore even with a live server" {
    seed_resurrect 20260610T075410 "crabbot" 1

    local bin_dir="$TEST_HOME/mockbin"
    stub_tmux "$bin_dir" ""   # list-sessions exits 0 -> server is up

    # Fake dotfiles tree with a restore.sh stub that records it ran.
    local fake="$TEST_HOME/fake-dotfiles"
    mkdir -p "$fake/tmux/plugins/tmux-resurrect/scripts"
    printf '#!/usr/bin/env bash\necho ran >> "%s/restore.log"\n' "$TEST_HOME" \
        > "$fake/tmux/plugins/tmux-resurrect/scripts/restore.sh"
    chmod +x "$fake/tmux/plugins/tmux-resurrect/scripts/restore.sh"

    PATH="$bin_dir:$PATH" DOTFILES_DIR="$fake" run resume_main --restore 20260610T075410
    assert_success
    [[ "$(readlink "$HOME/.tmux/resurrect/last")" == "tmux_resurrect_20260610T075410.txt" ]]
    [[ -f "$TEST_HOME/restore.log" ]]
}

@test "resume_main --restore --dry-run reports without repointing last" {
    seed_resurrect 20260610T075410 "crabbot" 1
    local bin_dir="$TEST_HOME/mockbin"
    stub_tmux "$bin_dir" ""

    PATH="$bin_dir:$PATH" run resume_main --restore 20260610T075410 --dry-run
    assert_success
    [[ ! -e "$HOME/.tmux/resurrect/last" ]]
    assert_output_contains "would restore snapshot"
}

@test "dots resume skips panes with no resumable session" {
    local bin_dir="$TEST_HOME/mockbin"
    stub_tmux "$bin_dir" "dotfiles	0	0	%3	/no/agent/session/here"
    PATH="$bin_dir:$PATH" run dots resume --dry-run

    assert_success
    assert_output_contains "no resumable agent sessions"
    [[ "$output" != *"%3"* ]]
}

@test "resume_list_snapshots caps the picker at RESUME_MAX_SNAPSHOTS" {
    local i
    for i in $(seq -w 1 25); do
        seed_resurrect "202606100000${i}" "s$i" 1
        touch -t "2026061000${i}" "$HOME/.tmux/resurrect/tmux_resurrect_202606100000${i}.txt"
    done

    RESUME_MAX_SNAPSHOTS=20 run resume_list_snapshots
    assert_success
    [[ "${#lines[@]}" -eq 20 ]]
}
