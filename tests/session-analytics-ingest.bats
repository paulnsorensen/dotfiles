#!/usr/bin/env bats
#
# Tests for skills/session-analytics/scripts/ingest.py — the multi-harness
# adapter layer. Each harness adapter must normalize its native session format
# into one canonical row shape carrying a `harness` column, then load the union
# into ~/.claude/analytics/sessions.duckdb.
#
# The adapters under test:
#   - claude   : ~/.claude/projects/**/*.jsonl              (assistant/user blocks)
#   - codex    : ~/.codex/sessions/**/*.jsonl               (response_item payloads)
#   - omp      : ~/.omp/agent/sessions/**/*.jsonl           (Pi-family messages)
#   - pi       : ~/.pi/agent/sessions/**/*.jsonl            (Pi-family messages)
#   - cursor   : state.vscdb  -> documented "no accessible logs" (best-effort)
#   - copilot  : ~/.copilot   -> documented "no accessible logs" (best-effort)
#
# shellcheck disable=SC1090,SC2317

load test_helper

INGEST="$REAL_DOTFILES_DIR/skills/session-analytics/scripts/ingest.py"
DB="$TEST_HOME/.claude/analytics/sessions.duckdb"

setup() {
    setup_test_env
    command -v duckdb  >/dev/null || skip "duckdb not installed"
    mkdir -p "$TEST_HOME/.claude/projects/proj"
    mkdir -p "$TEST_HOME/.codex/sessions/2026/05/30"
    mkdir -p "$TEST_HOME/.pi/agent/sessions/2026/05/30"
}

teardown() { teardown_test_env; }

# --- fixtures -------------------------------------------------------------

# A minimal claude session: one Skill tool_use + a tool_result.
write_claude_fixture() {
    cat > "$TEST_HOME/.claude/projects/proj/sess-claude.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","sessionId":"c-1","cwd":"/work/claude","gitBranch":"main","message":{"content":[{"type":"tool_use","id":"tu-c-1","name":"Skill","input":{"skill":"cook","args":"go"}}]}}
{"type":"user","timestamp":"2026-05-30T10:00:01Z","sessionId":"c-1","message":{"content":[{"type":"tool_result","tool_use_id":"tu-c-1","content":"ok","is_error":"false"}]}}
JSONL
}

# A minimal codex session: session_meta + a function_call + function_call_output.
write_codex_fixture() {
    cat > "$TEST_HOME/.codex/sessions/2026/05/30/rollout-codex.jsonl" <<'JSONL'
{"timestamp":"2026-05-30T11:00:00Z","type":"session_meta","payload":{"id":"x-1","timestamp":"2026-05-30T11:00:00Z","cwd":"/work/codex"}}
{"timestamp":"2026-05-30T11:00:02Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"ls\"]}","call_id":"call-x-1"}}
{"timestamp":"2026-05-30T11:00:03Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-x-1","output":"a.txt"}}
JSONL
}

# A minimal upstream Pi session: header + native toolCall + toolResult messages.
write_pi_fixture() {
    cat > "$TEST_HOME/.pi/agent/sessions/2026/05/30/session-pi.jsonl" <<'JSONL'
{"type":"session","id":"p-1","timestamp":"2026-05-30T11:30:00Z","cwd":"/work/pi"}
{"type":"message","id":"m-1","timestamp":"2026-05-30T11:30:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-p-1","name":"read","arguments":{"path":"README.md"}}]}}
{"type":"message","id":"m-2","timestamp":"2026-05-30T11:30:03Z","message":{"role":"toolResult","toolCallId":"call-p-1","toolName":"read","content":[{"type":"text","text":"Pi"}],"isError":false}}
JSONL
}


q() { duckdb "$DB" -json -c "$1"; }

# --- tests ----------------------------------------------------------------

@test "ingest: claude adapter still loads sessions tagged harness=claude" {
    write_claude_fixture
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness='claude' AND tool_name='Skill';"
    assert_output_contains '"n":1'
}

@test "ingest: codex adapter normalizes function_call into a tool_use tagged harness=codex" {
    write_codex_fixture
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness='codex';"
    assert_output_contains '"n":1'
}

@test "ingest: upstream Pi adapter preserves native tool calls and harness identity" {
    write_pi_fixture
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT tool_name, json_extract_string(input, '$.path') AS path FROM tool_uses WHERE harness='pi' AND tool_use_id='call-p-1';"
    assert_output_contains '"tool_name":"read"'
    assert_output_contains '"path":"README.md"'
    run q "SELECT content, is_error FROM tool_results WHERE harness='pi' AND tool_use_id='call-p-1';"
    assert_output_contains '"content":"Pi"'
    assert_output_contains '"is_error":"false"'
}


@test "ingest: a harness-filtered query unifies multiple sources in one schema" {
    write_claude_fixture
    write_codex_fixture
    run python3 "$INGEST" --force
    assert_success
    # The canonical schema surfaces both reachable fixture harnesses.
    run q "SELECT count(DISTINCT harness) AS n FROM tool_uses;"
    assert_output_contains '"n":2'
}

@test "ingest: sessions table carries the harness column" {
    write_codex_fixture
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT harness FROM sessions WHERE harness='codex';"
    assert_output_contains '"harness":"codex"'
}

@test "ingest: harness adapters with no logs are non-fatal (claude-only still succeeds)" {
    write_claude_fixture
    # No other harness fixtures: absent logs must stay non-fatal.
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness='claude';"
    assert_output_contains '"n":1'
}

# --- boundary + round-trip hardening -------------------------------------

@test "ingest: codex function_call_output round-trips into a tool_result with matching call_id" {
    write_codex_fixture
    run python3 "$INGEST" --force
    assert_success
    # The output side of the pair must land, keyed by the same call_id as the
    # tool_use, or correlation (a tool's result) is silently lost.
    run q "SELECT content FROM tool_results WHERE harness='codex' AND tool_use_id='call-x-1';"
    assert_output_contains '"content":"a.txt"'
    # Output with no exit marker is not an error.
    run q "SELECT is_error FROM tool_results WHERE harness='codex' AND tool_use_id='call-x-1';"
    assert_output_contains '"is_error":"false"'
}

@test "ingest: codex non-zero exit maps to is_error=true" {
    cat > "$TEST_HOME/.codex/sessions/2026/05/30/rollout-codex-fail.jsonl" <<'JSONL'
{"timestamp":"2026-05-30T12:00:00Z","type":"session_meta","payload":{"id":"x-2","timestamp":"2026-05-30T12:00:00Z","cwd":"/work/codex"}}
{"timestamp":"2026-05-30T12:00:02Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"false\"]}","call_id":"call-x-2"}}
{"timestamp":"2026-05-30T12:00:03Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-x-2","output":"Process exited with code 1\nboom"}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    # A non-zero codex exit must record is_error=true, or codex tool failures
    # are systematically under-reported as successes (the canonical schema's
    # fail-loud intent).
    run q "SELECT is_error FROM tool_results WHERE harness='codex' AND tool_use_id='call-x-2';"
    assert_output_contains '"is_error":"true"'
}


@test "ingest: a malformed JSONL line is skipped without aborting the run" {
    cat > "$TEST_HOME/.claude/projects/proj/sess-corrupt.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","sessionId":"c-1","cwd":"/w","message":{"content":[{"type":"tool_use","id":"tu-1","name":"Skill","input":{"skill":"cook"}}]}}
this is not json {{{

{"type":"assistant","timestamp":"2026-05-30T10:00:05Z","sessionId":"c-1","cwd":"/w","message":{"content":[{"type":"tool_use","id":"tu-2","name":"Read","input":{}}]}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    # Both well-formed rows survive; the corrupt line and the blank line are dropped.
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness='claude';"
    assert_output_contains '"n":2'
}

@test "ingest: no accessible logs from any harness exits non-zero (fail loud)" {
    # No fixtures written for any harness. The pipeline must refuse to build an
    # empty DB rather than silently produce a schema with zero rows.
    run python3 "$INGEST" --force
    assert_failure
    assert_output_contains "No accessible sessions from any harness"
}

@test "ingest: cursor/copilot are documented no-log skips, never appear as harnesses" {
    write_claude_fixture
    run python3 "$INGEST" --force
    assert_success
    # These two harnesses are best-effort no-accessible-logs: they must not
    # materialize phantom rows under their own harness tag.
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness IN ('cursor','copilot');"
    assert_output_contains '"n":0'
}
