#!/usr/bin/env bats
# Package-backed integration tests for session analytics report scripts.

load test_helper
load lib/session-analytics-package

SKILLS="$REAL_DOTFILES_DIR/skills"

setup() {
    setup_test_env
    package_fixture_env
    unset SESSIONS_COHORT SESSIONS_SINCE SESSIONS_UNTIL
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

add_real_prompt_fixture() {
    make_fixture
    printf '%s\n' \
        '{"type":"user","timestamp":"2026-08-01T10:00:00Z","sessionId":"s2","message":{"content":[{"type":"text","text":"auth line"},{"type":"text","text":"second line"}]}}' \
        '{"type":"user","timestamp":"2026-08-01T10:00:01Z","sessionId":"s2","isMeta":true,"message":{"content":"auth injected"}}' \
        '{"type":"user","timestamp":"2026-08-01T10:00:02Z","sessionId":"s2","message":{"content":[{"type":"tool_result","tool_use_id":"unused","content":"auth tool result"}]}}' \
        >> "$CLAUDE_CONFIG_DIR/projects/proj/session.jsonl"
    mkdir -p "$CODEX_HOME/sessions/2026/08/01"
    printf '%s\n' \
        '{"timestamp":"2026-08-01T10:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/work/proj"}}' \
        '{"timestamp":"2026-08-01T10:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"auth injected codex"}]}}' \
        '{"timestamp":"2026-08-01T10:00:01Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"/review auth"}]}}}' \
        '{"timestamp":"2026-08-01T10:00:01Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"auth codex detail"}]}}}' \
        '{"timestamp":"2026-08-01T10:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"unused","output":"auth tool result"}}' \
        > "$CODEX_HOME/sessions/2026/08/01/rollout-main.jsonl"
    printf '%s\n' \
        '{"timestamp":"2026-08-01T10:00:00Z","type":"session_meta","payload":{"id":"agent-1","cwd":"/work/proj","source":{"subagent":{"thread_spawn":{"parent_thread_id":"s1"}}}}}' \
        '{"timestamp":"2026-08-01T10:00:01Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"/phantom auth"}]}}}' \
        > "$CODEX_HOME/sessions/2026/08/01/rollout-agent.jsonl"
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

make_cohort_fixture() {
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/proj" "$CODEX_HOME/sessions/2026/08/01"
    printf '%s\n' \
        '{"type":"assistant","timestamp":"2026-08-01T10:00:00Z","sessionId":"retained","cwd":"/work/benchmark-helper","message":{"content":[{"type":"tool_use","id":"shared","name":"Read","input":{}},{"type":"tool_use","id":"missing","name":"Read","input":{}},{"type":"tool_use","id":"bash1","name":"Bash","input":{"command":"grep foo"}},{"type":"tool_use","id":"mcp1","name":"mcp__tilth__tilth_read","input":{}}]}}' \
        '{"type":"user","timestamp":"2026-08-01T10:00:01Z","sessionId":"retained","cwd":"/work/benchmark-helper","message":{"content":[{"type":"tool_result","tool_use_id":"shared","content":"ok","is_error":"false"},{"type":"tool_result","tool_use_id":"shared","content":"ok again","is_error":"false"},{"type":"tool_result","tool_use_id":"bash1","content":"ok","is_error":"false"},{"type":"tool_result","tool_use_id":"mcp1","content":"ok","is_error":"false"}]}}' \
        '{"type":"assistant","timestamp":"2026-08-01T11:00:00Z","sessionId":"benchmark","cwd":"/work/benchmark/results/candidates","message":{"content":[{"type":"tool_use","id":"shared","name":"Read","input":{}},{"type":"tool_use","id":"bash1","name":"Bash","input":{"command":"grep foo"}},{"type":"tool_use","id":"mcp1","name":"mcp__tilth__tilth_read","input":{}}]}}' \
        '{"type":"user","timestamp":"2026-08-01T11:00:01Z","sessionId":"benchmark","cwd":"/work/benchmark/results/candidates","message":{"content":[{"type":"tool_result","tool_use_id":"shared","content":"benchmark failure","is_error":"true"},{"type":"tool_result","tool_use_id":"shared","content":"ok","is_error":"false"},{"type":"tool_result","tool_use_id":"bash1","content":"Permission to use Bash denied","is_error":"true"},{"type":"tool_result","tool_use_id":"mcp1","content":"benchmark mcp failure","is_error":"true"}]}}' \
        '{"type":"assistant","timestamp":"2026-08-01T12:00:00Z","sessionId":"benchmark","cwd":"/work/proj","gitBranch":"other","message":{"content":"same session, other cwd"}}' \
        '{"type":"assistant","timestamp":"2026-08-01T13:00:00Z","sessionId":"unknown","message":{"content":[{"type":"tool_use","id":"shared","name":"Read","input":{}}]}}' \
        '{"type":"user","timestamp":"2026-08-01T13:00:01Z","sessionId":"unknown","message":{"content":[{"type":"tool_result","tool_use_id":"shared","content":"unknown ok","is_error":"false"}]}}' \
        '{"type":"assistant","timestamp":"2026-08-02T00:00:00Z","sessionId":"after","cwd":"/work/proj","message":{"content":[{"type":"tool_use","id":"after","name":"Read","input":{}}]}}' \
        > "$CLAUDE_CONFIG_DIR/projects/proj/session.jsonl"
    printf '%s\n' \
        '{"timestamp":"2026-08-01T14:00:00Z","type":"session_meta","payload":{"id":"codex","cwd":"/work/proj"}}' \
        '{"timestamp":"2026-08-01T14:00:01Z","type":"response_item","payload":{"type":"function_call","call_id":"shared","name":"Read","arguments":"{}"}}' \
        '{"timestamp":"2026-08-01T14:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"shared","output":"codex ok"}}' \
        '{"timestamp":"2026-08-01T16:00:01.250+02:00","type":"response_item","payload":{"type":"function_call","call_id":"inferred","name":"Broken","arguments":"{}"}}' \
        '{"timestamp":"2026-08-01T16:00:02.250+02:00","type":"response_item","payload":{"type":"function_call_output","call_id":"inferred","output":"{\"status\":\"error\"}"}}' \
        > "$CODEX_HOME/sessions/2026/08/01/rollout.jsonl"
    "${PACKAGE_CLI[@]}" ingest --force >/dev/null
    export SESSIONS_DB
    SESSIONS_DB="$(package_fixture_db)"
    export SESSIONS_SINCE=2026-08-01T00:00:00Z SESSIONS_UNTIL=2026-08-02T00:00:00Z
}

@test "tool cohorts keep unknown sessions and isolate duplicate result keys" {
    make_cohort_fixture
    run "${PACKAGE_CLI[@]}" sql 'SELECT count(*) AS rows FROM raw_entries'
    [ "$status" -eq 0 ]
    local raw_before="$output"
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" error-forensics Read
    [ "$status" -eq 0 ]
    assert_contains "$output" '| retained | 3 | 7 |'
    assert_contains "$output" '| benchmark | 1 | 3 |'
    assert_contains "$output" '| target | 4 | 3 | 1 | 0 | 0.0 |'
    assert_not_contains "$output" 'benchmark failure'
    export SESSIONS_COHORT=benchmark
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" error-forensics Read
    [ "$status" -eq 0 ]
    assert_contains "$output" '| target | 1 | 1 | 0 | 1 | 100.0 |'
    assert_contains "$output" 'benchmark failure'
    run "${PACKAGE_CLI[@]}" sql 'SELECT count(*) AS rows FROM raw_entries'
    [ "$status" -eq 0 ]
    [ "$output" = "$raw_before" ]
}

@test "benchmark errors do not create retained recommendations or friction" {
    make_cohort_fixture
    printf '%s\n' \
        '{"type":"assistant","timestamp":"2026-08-01T00:00:00Z","sessionId":"benchmark","cwd":"/work/proj","message":{"content":[{"type":"tool_use","id":"bench2","name":"Read","input":{}}]}}' \
        '{"type":"user","timestamp":"2026-08-01T00:00:00Z","sessionId":"benchmark","cwd":"/work/proj","message":{"content":[{"type":"tool_result","tool_use_id":"bench2","content":"lower-bound failure","is_error":"true"}]}}' \
        '{"type":"assistant","timestamp":"2026-08-01T11:02:00Z","sessionId":"benchmark","cwd":"/work/proj","message":{"content":[{"type":"tool_use","id":"bench3","name":"Read","input":{}}]}}' \
        '{"type":"user","timestamp":"2026-08-01T11:02:01Z","sessionId":"benchmark","cwd":"/work/proj","message":{"content":[{"type":"tool_result","tool_use_id":"bench3","content":"other failure","is_error":"true"}]}}' \
        >> "$CLAUDE_CONFIG_DIR/projects/proj/session.jsonl"
    "${PACKAGE_CLI[@]}" ingest --force >/dev/null
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" fix-recommendations Read
    [ "$status" -eq 0 ]
    assert_not_contains "$output" '| Read |'
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" permission-friction Bash
    [ "$status" -eq 0 ]
    assert_not_contains "$output" 'grep (use tilth_search)'
    assert_contains "$output" '| 1 | 1 | 0 |'
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" mcp-health tilth
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    assert_contains "$output" '| tilth | 1 |'
    export SESSIONS_COHORT=all
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" mcp-health tilth
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    assert_contains "$output" '| tilth | 2 |'
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" fix-recommendations Read
    [ "$status" -eq 0 ]
    assert_contains "$output" '| Read | 7 | 6 | 1 | 3 | 50.0 |'
    export SESSIONS_COHORT=benchmark
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" fix-recommendations Read
    [ "$status" -eq 0 ]
    assert_contains "$output" '| Read | 3 | 3 | 0 | 3 | 100.0 |'
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" error-forensics Read
    [ "$status" -eq 0 ]
    assert_contains "$output" 'lower-bound failure'
}

@test "recommendations require three result-bearing calls" {
    make_cohort_fixture
    printf '%s\n' \
        '{"timestamp":"2026-08-01T14:01:00Z","type":"response_item","payload":{"type":"function_call","call_id":"missing1","name":"Broken","arguments":"{}"}}' \
        '{"timestamp":"2026-08-01T14:02:00Z","type":"response_item","payload":{"type":"function_call","call_id":"missing2","name":"Broken","arguments":"{}"}}' \
        >> "$CODEX_HOME/sessions/2026/08/01/rollout.jsonl"
    "${PACKAGE_CLI[@]}" ingest --force >/dev/null
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" error-forensics Broken codex
    [ "$status" -eq 0 ]
    assert_contains "$output" '| target | 3 | 1 | 2 | 1 | 100.0 |'
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" fix-recommendations Broken codex
    [ "$status" -eq 0 ]
    assert_not_contains "$output" '| Broken |'
    printf '%s\n' \
        '{"timestamp":"2026-08-01T14:03:00Z","type":"response_item","payload":{"type":"function_call_output","call_id":"missing1","output":"{\"status\":\"error\"}"}}' \
        '{"timestamp":"2026-08-01T14:04:00Z","type":"response_item","payload":{"type":"function_call_output","call_id":"missing2","output":"{\"status\":\"error\"}"}}' \
        >> "$CODEX_HOME/sessions/2026/08/01/rollout.jsonl"
    "${PACKAGE_CLI[@]}" ingest --force >/dev/null
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" fix-recommendations Broken codex
    [ "$status" -eq 0 ]
    assert_contains "$output" '| Broken | 3 | 3 | 0 | 3 | 100.0 |'
}

@test "invalid tool cohort and window fail as usage errors" {
    make_cohort_fixture
    export SESSIONS_COHORT=bogus
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" tool-usage Read
    [ "$status" -eq 2 ]
    export SESSIONS_COHORT=retained SESSIONS_SINCE=not-a-date
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" tool-usage Read
    [ "$status" -eq 2 ]
    export SESSIONS_SINCE=2026-08-02T00:00:00Z
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" tool-usage Read
    [ "$status" -eq 2 ]
}

@test "artifact payloads and inferred Codex errors respect the UTC window" {
    make_cohort_fixture
    printf '%s\n' \
        '{"type":"assistant","timestamp":"2026-08-01T15:00:00Z","sessionId":"artifact","cwd":"/work/proj","message":{"content":"Candidate /tmp/benchmark/results/candidates/abc"}}' \
        '{"type":"assistant","timestamp":"2026-08-01T15:00:01Z","sessionId":"artifact","cwd":"/work/proj","message":{"content":[{"type":"tool_use","id":"artifact-read","name":"Read","input":{}}]}}' \
        >> "$CLAUDE_CONFIG_DIR/projects/proj/session.jsonl"
    "${PACKAGE_CLI[@]}" ingest --force >/dev/null
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" error-forensics Read
    [ "$status" -eq 0 ]
    assert_contains "$output" '| benchmark | 2 | 4 |'
    assert_contains "$output" '| retained | 3 | 7 |'
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" error-forensics Broken codex
    [ "$status" -eq 0 ]
    assert_contains "$output" '| target | 1 | 1 | 0 | 1 | 100.0 |'
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

@test "real Codex prompts use canonical turns and stable opener order" {
    add_real_prompt_fixture
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" prompt-analysis % codex
    [ "$status" -eq 0 ]
    assert_contains "$output" '| slash-command | 1 |'
    assert_contains "$output" '| freeform | 1 |'
    assert_contains "$output" '| /review | 1 |'
    assert_contains "$output" '| /review auth | 1 |'
    assert_not_contains "$output" '/phantom'
    assert_not_contains "$output" '| auth codex detail | 1 |'
}

@test "real Claude text blocks count but injected and result text do not" {
    add_real_prompt_fixture
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" prompt-analysis % claude
    [ "$status" -eq 0 ]
    assert_contains "$output" '| freeform | 2 |'
    assert_contains "$output" '| slash-command | 1 |'
    assert_contains "$output" '| auth line<br>second line | 1 |'
    assert_not_contains "$output" 'auth injected'
    assert_not_contains "$output" 'auth tool result'
}

@test "knowledge gaps qualify sessions by harness before joining skills" {
    add_real_prompt_fixture
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" knowledge-gaps auth codex
    [ "$status" -eq 0 ]
    assert_contains "$output" '| 1 | 1 |'
    assert_not_contains "$output" '| cheese |'
    assert_not_contains "$output" '| cook |'
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" knowledge-gaps auth
    [ "$status" -eq 0 ]
    assert_contains "$output" '| 3 | 3 |'
    assert_contains "$output" '| cheese | 1 |'
    assert_contains "$output" '| cook | 1 |'
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
