#!/usr/bin/env bats
# Package-backed integration tests for session analytics report scripts.

load test_helper
load lib/session-analytics-package

SKILLS="$REAL_DOTFILES_DIR/skills"

setup() {
    setup_test_env
    package_fixture_env
}

teardown() { teardown_test_env; }

make_fixture() {
    package_fixture_ingest >/dev/null
    printf '%s\n' \
        '{"type":"user","timestamp":"2026-08-01T10:00:00Z","sessionId":"s1","cwd":"/work/proj","gitBranch":"main","message":{"content":"fix the auth bug"}}' \
        '{"type":"assistant","timestamp":"2026-08-01T10:01:00Z","sessionId":"s1","cwd":"/work/proj","gitBranch":"main","message":{"content":[{"type":"tool_use","id":"tu3","name":"Read","input":{"file_path":"/work/proj/main.rs"}},{"type":"tool_use","id":"tu4","name":"Skill","input":{"skill":"cheese"}},{"type":"tool_use","id":"tu5","name":"mcp__tilth__tilth_read","input":{}}]}}' \
        '{"type":"user","timestamp":"2026-08-01T10:01:01Z","sessionId":"s1","cwd":"/work/proj","message":{"content":[{"type":"tool_result","tool_use_id":"tu3","content":"File not found: main.rs","is_error":"true"},{"type":"tool_result","tool_use_id":"tu4","content":"ok","is_error":"false"},{"type":"tool_result","tool_use_id":"tu5","content":"ok","is_error":"false"}]}}' \
        '{"type":"assistant","timestamp":"2026-08-01T10:02:00Z","sessionId":"s1","cwd":"/work/proj","gitBranch":"main","message":{"content":[{"type":"tool_use","id":"tu6","name":"Edit","input":{"file_path":"/work/proj/main.rs"}},{"type":"tool_use","id":"tu7","name":"Skill","input":{"skill":"cook"}}]}}' \
        '{"type":"assistant","timestamp":"2026-08-01T10:03:00Z","sessionId":"s1","cwd":"/work/proj","gitBranch":"main","message":{"content":[{"type":"tool_use","id":"tu8","name":"Bash","input":{"command":"cargo test"}}]}}' \
        '{"type":"assistant","timestamp":"2026-08-01T10:04:00Z","sessionId":"s1","cwd":"/work/proj","gitBranch":"main","message":{"content":[{"type":"tool_use","id":"tu9","name":"Bash","input":{"command":"grep foo | sort"}}]}}' \
        '{"type":"user","timestamp":"2026-08-01T10:04:01Z","sessionId":"s1","cwd":"/work/proj","message":{"content":[{"type":"tool_result","tool_use_id":"tu9","content":"Permission to use Bash with command grep foo | sort has been denied","is_error":"true"}]}}' \
        '{"type":"user","timestamp":"2026-08-01T10:05:00Z","sessionId":"s1","cwd":"/work/proj","message":{"content":"/cheese go"}}' \
        >> "$CLAUDE_CONFIG_DIR/projects/proj/session.jsonl"
    "${PACKAGE_CLI[@]}" ingest --force >/dev/null
    export SESSIONS_DB
    SESSIONS_DB="$(package_fixture_db)"
}

add_codex_token_fixture() {
    mkdir -p "$CODEX_HOME/sessions/2026/05/30"
    printf '%s\n' \
        '{"timestamp":"2026-05-30T11:00:00Z","type":"session_meta","payload":{"id":"cx1","cwd":"/work/proj"}}' \
        '{"timestamp":"2026-05-30T11:00:01Z","type":"turn_context","payload":{"cwd":"/work/proj","model":"gpt-x"}}' \
        '{"timestamp":"2026-05-30T11:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7,"total_tokens":107},"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7,"total_tokens":107}}}}' \
        > "$CODEX_HOME/sessions/2026/05/30/rollout.jsonl"
    unset SESSIONS_DB
    "${PACKAGE_CLI[@]}" ingest --force >/dev/null
    export SESSIONS_DB
    SESSIONS_DB="$(package_fixture_db)"
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || {
        printf 'expected to contain: %s\nactual: %s\n' "$2" "$1" >&2
        return 1
    }
}

assert_not_contains() {
    [[ "$1" != *"$2"* ]] || {
        printf 'expected NOT to contain: %s\nactual: %s\n' "$2" "$1" >&2
        return 1
    }
}

@test "package fixture contains only isolated Claude logs" {
    make_fixture
    run "${PACKAGE_CLI[@]}" sql "SELECT DISTINCT harness FROM sessions"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"claude"'
    assert_not_contains "$output" '"omp"'
}

@test "default report invokes package freshness without an override" {
    printf '%s\n' \
        '{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","sessionId":"fresh-1","cwd":"/work/fresh","message":{"content":[{"type":"tool_use","id":"fresh-tu","name":"Read","input":{"file_path":"README.md"}}]}}' \
        > "$CLAUDE_CONFIG_DIR/projects/proj/session.jsonl"
    unset SESSIONS_DB
    run "$SKILLS/work-recovery/scripts/sessions.sh" fresh
    [ "$status" -eq 0 ]
    assert_contains "$output" "fresh-1"
    assert_contains "$output" "fresh"
}

@test "expert workflow reads public schema, path, and SQL" {
    make_fixture
    run "${PACKAGE_CLI[@]}" schema
    [ "$status" -eq 0 ]
    assert_contains "$output" '"reference": "canonical-schema.md"'
    run "${PACKAGE_CLI[@]}" db-path
    [ "$status" -eq 0 ]
    assert_contains "$output" "$SESSIONS_DB"
    run "${PACKAGE_CLI[@]}" sql "SELECT count(DISTINCT sessionId) AS n FROM sessions WHERE harness = 'claude'"
    [ "$status" -eq 0 ]
    assert_contains "$output" '"n": 2'
}

@test "tool usage preserves frequency and Bash task fit" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" tool-usage Bash
    [ "$status" -eq 0 ]
    assert_contains "$output" "### Frequency"
    assert_contains "$output" "| Bash |"
    assert_contains "$output" "### Task fit"
    assert_contains "$output" "grep"
}

@test "error forensics preserves the target and baseline" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" error-forensics Read
    [ "$status" -eq 0 ]
    assert_contains "$output" "| target |"
    assert_contains "$output" "| baseline |"
    assert_contains "$output" "File not found"
}

@test "permission friction reports denial category and command" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" permission-friction Bash
    [ "$status" -eq 0 ]
    assert_contains "$output" "grep (use tilth_search)"
    assert_contains "$output" 'grep foo \| sort'
}

@test "MCP health names the server and method" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" mcp-health tilth
    [ "$status" -eq 0 ]
    assert_contains "$output" "tilth"
    assert_contains "$output" "tilth_read"
}

@test "fix recommendations retain the signal caveat" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" fix-recommendations %
    [ "$status" -eq 0 ]
    assert_contains "$output" "### Raw-bash"
    assert_contains "$output" "insufficient signal"
}

@test "token economics counts native Codex input including cache reads" {
    make_fixture
    add_codex_token_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" token-economics Bash codex
    [ "$status" -eq 0 ]
    assert_contains "$output" "| cx1 | codex | incl_cache | 100 | 7 | 40 |"
    assert_contains "$output" "input_tokens: codex includes cached tokens"
}

@test "tool report honors harness filter" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" tool-usage Bash codex
    [ "$status" -eq 0 ]
    assert_not_contains "$output" "| Bash |"
}

@test "tool all domain keeps every section heading" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" all %
    [ "$status" -eq 0 ]
    for heading in 'Tool Usage' 'Error Forensics' 'Fix Recommendations' 'Permission Friction' 'MCP Health' 'Token Economics'; do
        assert_contains "$output" "## $heading"
    done
}

@test "prompt analysis separates slash commands and freeform text" {
    make_fixture
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" prompt-analysis %
    [ "$status" -eq 0 ]
    assert_contains "$output" "freeform"
    assert_contains "$output" "/cheese"
}

@test "routing accuracy reports downstream skill without intent proof" {
    make_fixture
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" routing-accuracy cheese
    [ "$status" -eq 0 ]
    assert_contains "$output" "cook"
    assert_contains "$output" "no intent ground-truth"
}

@test "knowledge gaps keeps its inference caveat" {
    make_fixture
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" knowledge-gaps auth
    [ "$status" -eq 0 ]
    assert_contains "$output" "medium signal"
    assert_contains "$output" "candidate gap only"
}

@test "prompt all domain keeps every section heading" {
    make_fixture
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" all %
    [ "$status" -eq 0 ]
    for heading in 'Prompt Analysis' 'Routing Accuracy' 'Knowledge Gaps'; do
        assert_contains "$output" "## $heading"
    done
}

@test "recent sessions filter lists the matching branch" {
    make_fixture
    run "$SKILLS/work-recovery/scripts/sessions.sh" proj claude
    [ "$status" -eq 0 ]
    assert_contains "$output" "s1"
    assert_contains "$output" "main"
}

@test "recovery quotes goal, file, and test command" {
    make_fixture
    run "$SKILLS/work-recovery/scripts/recover.sh" s1
    [ "$status" -eq 0 ]
    assert_contains "$output" "fix the auth bug"
    assert_contains "$output" "main.rs"
    assert_contains "$output" "cargo test"
}

@test "no matching session is an empty result, not a package failure" {
    make_fixture
    run "$SKILLS/work-recovery/scripts/recover.sh" absent
    [ "$status" -eq 0 ]
    assert_contains "$output" "| harness | sessionId |"
    assert_contains "$output" "no test/build/git command recorded"
}

@test "unstamped override fails rather than reporting insufficient signal" {
    local invalid="$TEST_HOME/invalid.duckdb"
    duckdb -init /dev/null "$invalid" -c "CREATE TABLE sessions (sessionId VARCHAR)" >/dev/null
    export SESSIONS_DB="$invalid"
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" tool-usage Bash
    [ "$status" -eq 4 ]
    assert_not_contains "$output" "insufficient signal"
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" prompt-analysis %
    [ "$status" -eq 4 ]
    run "$SKILLS/work-recovery/scripts/recover.sh" s1
    [ "$status" -eq 4 ]
    run "$SKILLS/work-recovery/scripts/sessions.sh"
    [ "$status" -eq 4 ]
}

@test "missing override fails instead of fabricating empty evidence" {
    export SESSIONS_DB="$TEST_HOME/missing.duckdb"
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" tool-usage Bash
    [ "$status" -eq 4 ]
    assert_not_contains "$output" "(query failed)"
}

@test "invalid arguments keep usage status" {
    run "$SKILLS/work-recovery/scripts/recover.sh"
    [ "$status" -eq 2 ]
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" bogus Bash
    [ "$status" -eq 2 ]
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" bogus %
    [ "$status" -eq 2 ]
}
