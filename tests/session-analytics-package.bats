#!/usr/bin/env bats
load test_helper
load lib/session-analytics-package

QUERY_SH="$REAL_DOTFILES_DIR/skills/session-analytics/scripts/query.sh"

setup() {
    setup_test_env
    package_fixture_env
    package_fixture_ingest >/dev/null
}

teardown() { teardown_test_env; }

@test "package reports keep names, headings, and harness filters" {
    local report heading
    for report in tools errors mcp skills sessions bash denials allowlist-gaps python3 hooks compound projects heatmap latency; do
        run "$QUERY_SH" "$report" claude
        [ "$status" -eq 0 ] || { echo "$report: $output" >&2; false; }
        case "$report" in
            tools) headings="tool_name uses" ;;
            errors) headings="tool_name total errors error_pct" ;;
            mcp) headings="server method calls" ;;
            skills) headings="skill_name day uses" ;;
            sessions) headings="sessionId project branch first_seen last_seen tool_calls" ;;
            bash) headings="cmd uses" ;;
            denials) headings="category denials" ;;
            allowlist-gaps) headings="cmd_prefix uses denied deny_pct" ;;
            python3) headings="purpose cnt pct" ;;
            hooks) headings="level preventedContinuation reason cnt" ;;
            compound) headings="cmd denials" ;;
            projects) headings="project tool_name uses" ;;
            heatmap) headings="day hour calls" ;;
            latency) headings="harness model turns calls_per_turn single_call_pct dur_p50_s dur_p95_s ttft_p50_s model_hours prompt_k_p50 error_stops" ;;
        esac
        for heading in $headings; do
            [[ "$output" == *"| $heading "* ]] || { echo "$report lacks $heading: $output" >&2; false; }
        done
    done
    run "$QUERY_SH" tools claude
    assert_output_contains "tool_name"
    assert_output_contains "Read"
    run "$QUERY_SH" tools
    assert_success
    assert_output_contains "Read"
    run "$QUERY_SH" errors claude
    assert_success
    assert_output_contains "error_pct"
    run "$QUERY_SH" sessions claude
    assert_success
    assert_output_contains "tool_calls"
    run "$QUERY_SH" tools codex
    [ "$status" -eq 0 ]
    [[ "$output" != *"Read"* ]]
}

@test "raw SQL renders headings, null, multiline text, and Markdown pipes" {
    run "$QUERY_SH" sql "SELECT 'one|two' AS label, NULL AS absent, 'line1'||chr(10)||'line2' AS note"
    assert_success
    assert_output_contains "label"
    assert_output_contains "one\\|two"
    assert_output_contains "line1<br>line2"
    assert_output_contains "absent"
    assert_output_contains "NULL"
}

@test "raw SQL keeps lowercase booleans and escapes header pipes" {
    run "$QUERY_SH" sql 'SELECT true AS yes, false AS no, 1 AS "a|b"'
    assert_success
    assert_output_contains '| yes | no | a\|b |'
    assert_output_contains '| true | false | 1 |'
}

@test "raw SQL empty result keeps column headings" {
    run "$QUERY_SH" sql "SELECT tool_name FROM tool_uses WHERE 1=0"
    assert_success
    [ "$output" = $'| tool_name |\n| --- |' ]
}

@test "package SQL failure stays nonzero and does not look empty" {
    run "$QUERY_SH" sql "SELECT * FROM not_a_table"
    [ "$status" -eq 5 ]
    [[ "$output" != *"(no rows)"* ]]
    [[ "$output" != *"(query failed)"* ]]
}

@test "package rejects unsafe SQL" {
    run "$QUERY_SH" sql "CREATE TABLE forbidden (x INTEGER)"
    [ "$status" -eq 5 ]
}

@test "unstamped override fails without implicit ingestion" {
    local db="$TEST_HOME/unstamped.duckdb"
    duckdb "$db" -c "CREATE TABLE tool_uses (tool_name VARCHAR)" >/dev/null
    SESSIONS_DB="$db" run "$QUERY_SH" tools
    [ "$status" -eq 4 ]
    [[ "$output" == *"schema version"* ]]
}

@test "missing override fails without successful empty evidence" {
    SESSIONS_DB="$TEST_HOME/missing.duckdb" run "$QUERY_SH" tools
    [ "$status" -eq 4 ]
    [[ "$output" != *"(no rows)"* ]]
}

@test "default database refreshes through package SQL" {
    local db
    db="$(package_fixture_db)"
    rm "$db"
    run "$QUERY_SH" tools claude
    assert_success
    assert_output_contains "Read"
    [ -f "$db" ]
}

@test "failed default ingestion preserves exit four" {
    local db="$TEST_HOME/.cache/dotfiles/session-analytics/sessions.duckdb"
    local bindir="$TEST_HOME/bin"
    rm "$db"
    mkdir -p "$bindir"
    printf '#!/usr/bin/env bash\nexit 42\n' > "$bindir/duckdb"
    chmod +x "$bindir/duckdb"
    PATH="$bindir:$PATH" run "$QUERY_SH" tools
    [ "$status" -eq 4 ]
    [[ "$output" != *"(no rows)"* ]]
}

@test "metadata query failure keeps its package exit status" {
    local bindir="$TEST_HOME/bin"
    local duckdb_real
    duckdb_real="$(command -v duckdb)"
    mkdir -p "$bindir"
    printf '#!/usr/bin/env bash\ncase "$*" in *DESCRIBE*) exit 42;; esac\nexec "%s" "$@"\n' "$duckdb_real" > "$bindir/duckdb"
    chmod +x "$bindir/duckdb"
    PATH="$bindir:$PATH" run "$QUERY_SH" sql "SELECT tool_name FROM tool_uses WHERE 1=0"
    [ "$status" -eq 5 ]
    [[ "$output" != *"(no rows)"* ]]
}

@test "fixture resets HOME before package scans OMP and Pi" {
    local outside="$TEST_HOME/outside"
    local harness
    for harness in omp pi; do
        local log="$outside/.$harness/agent/sessions/session.jsonl"
        mkdir -p "${log%/*}"
        printf '%s\n' \
            '{"type":"session","id":"outside","timestamp":"2026-05-30T11:00:00Z","cwd":"/work/outside"}' \
            '{"type":"message","id":"m-1","timestamp":"2026-05-30T11:00:01Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"t-1","name":"read","arguments":{"path":"outside"}}]}}' \
            > "$log"
    done
    export HOME="$outside"
    package_fixture_env
    [ "$HOME" = "$TEST_HOME" ]
    package_fixture_ingest >/dev/null
    run "$QUERY_SH" sql "SELECT count(*) AS n FROM raw_entries WHERE harness IN ('omp', 'pi')"
    assert_success
    assert_output_contains "| 0 |"
}


@test "package latency filters OMP turns and counts error stops" {
    local log="$TEST_HOME/.omp/agent/sessions/proj/s.jsonl"
    mkdir -p "${log%/*}"
    printf '%s\n' \
        '{"type":"session","id":"o-3","cwd":"/work/omp"}' \
        '{"type":"message","timestamp":"2026-05-30T13:00:00Z","message":{"role":"assistant","provider":"p","model":"gpt-x","stopReason":"toolUse","duration":4000,"content":[{"type":"toolCall","id":"t1","name":"read","arguments":{}}]}}' \
        '{"type":"message","timestamp":"2026-05-30T13:00:09Z","message":{"role":"assistant","provider":"p","model":"gpt-x","stopReason":"error","errorMessage":"usage_limit_reached","content":[]}}' \
        > "$log"
    run "${PACKAGE_CLI[@]}" ingest --force
    assert_success
    run "$QUERY_SH" latency omp
    assert_success
    assert_output_contains "error_stops"
    [[ "$output" =~ omp[[:space:]]*\|[[:space:]]*p/gpt-x[[:space:]]*\|[[:space:]]*2[[:space:]]*\|[[:space:]]*0\.5[[:space:]]*\|[[:space:]]*50\.0[[:space:]]*\|[[:space:]]*4\.0 ]]
    [[ "$output" =~ \|[[:space:]]*1[[:space:]]*\|$ ]]
    [[ "$output" != *claude* ]]
}

@test "package latency keeps NULL single-call rate for Codex turns without tool calls" {
    local log="$TEST_HOME/.codex/sessions/2026/05/30/rollout-latency.jsonl"
    mkdir -p "${log%/*}"
    printf '%s\n' \
        '{"timestamp":"2026-05-30T11:00:00Z","type":"session_meta","payload":{"id":"x-2","cwd":"/work/codex"}}' \
        '{"timestamp":"2026-05-30T11:00:01Z","type":"turn_context","payload":{"cwd":"/work/codex","model":"gpt-x"}}' \
        '{"timestamp":"2026-05-30T11:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7},"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}}}' \
        > "$log"
    run "${PACKAGE_CLI[@]}" ingest --force
    assert_success
    run "$QUERY_SH" sql "SELECT count(*) AS n, count(tool_calls) AS t FROM model_turns WHERE harness='codex'"
    assert_success
    assert_output_contains "| 0 |"
    run "$QUERY_SH" latency codex
    assert_success
    [[ "$output" != *"| 0.0 "* ]]
    [[ "$output" =~ gpt-x[[:space:]]*\|[[:space:]]*1[[:space:]]*\|[[:space:]]*NULL[[:space:]]*\| ]]
}
