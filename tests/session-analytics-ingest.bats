#!/usr/bin/env bats
#
# Tests for skills/session-analytics/scripts/ingest.py — the multi-harness
# adapter layer. Each harness adapter must normalize its native session format
# into one canonical row shape carrying a `harness` column, then load the union
# into the XDG cache session-analytics database.
#
# The adapters under test:
#   - claude   : ~/.claude/projects/**/*.jsonl              (assistant/user blocks)
#   - codex    : ~/.codex/sessions/**/*.jsonl               (response_item payloads)
#   - cursor   : ~/.cursor/projects/**/agent-transcripts/**/*.jsonl
#   - copilot  : ~/.copilot   -> documented "no accessible logs" (best-effort)
#
# shellcheck disable=SC1090,SC2317

load test_helper

INGEST="$REAL_DOTFILES_DIR/skills/session-analytics/scripts/ingest.py"
DB="$TEST_HOME/.cache/dotfiles/session-analytics/sessions.duckdb"

setup() {
    setup_test_env
    export XDG_CACHE_HOME="$TEST_HOME/.cache"
    command -v duckdb  >/dev/null || skip "duckdb not installed"
    mkdir -p "$TEST_HOME/.claude/projects/proj"
    mkdir -p "$TEST_HOME/.codex/sessions/2026/05/30"
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

write_cursor_fixture() {
    local slug="${1:-zz-nope-dash-name}"
    local parent="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local dir="$TEST_HOME/.cursor/projects/$slug/agent-transcripts/$parent"
    mkdir -p "$dir"
    cat > "$dir/$parent.jsonl" <<'JSONL'
{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Sunday, Aug 23, 2026, 9:00 PM (UTC-7)</timestamp>\n<user_query>hi</user_query>"}]}}
{"role":"assistant","message":{"content":[{"type":"tool_use","name":"CallMcpTool","input":{"server":"user-tilth","toolName":"tilth_list","arguments":{"cwd":"/tmp"}}},{"type":"tool_use","name":"CallMcpTool","input":{"arguments":{"cwd":"/tmp"},"description":"orphan"}},{"type":"tool_use","name":"Task","input":{"description":"explore","subagent_type":"explorer","prompt":"look"}},{"type":"tool_use","name":"Shell","input":{"command":"ls","description":"list"}}]}}
{"type":"turn_ended","status":"error","error":"User aborted request"}
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


@test "ingest: a harness-filtered query unifies multiple sources in one schema" {
    write_claude_fixture
    write_codex_fixture
    run python3 "$INGEST" --force
    assert_success
    # The canonical schema must surface both reachable harnesses.
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
    # No codex/omp fixtures written — those adapters must record "no logs"
    # and the run must still complete and load the claude rows.
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness='claude';"
    assert_output_contains '"n":1'
}

@test "ingest: omp assistant turns land in model_turns with model, tokens, and latency" {
    mkdir -p "$TEST_HOME/.omp/agent/sessions/proj"
    cat > "$TEST_HOME/.omp/agent/sessions/proj/s.jsonl" <<'JSONL'
{"type":"session","id":"o-1","cwd":"/work/omp"}
{"type":"message","timestamp":"2026-05-30T13:00:00Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-x","stopReason":"toolUse","duration":7000.5,"ttft":1500,"usage":{"input":100,"output":20,"cacheRead":9000},"contextSnapshot":{"promptTokens":9100},"content":[{"type":"toolCall","id":"t1","name":"read","arguments":{"path":"a"}},{"type":"toolCall","id":"t2","name":"read","arguments":{"path":"b"}}]}}
{"type":"message","timestamp":"2026-05-30T13:00:09Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-x","stopReason":"error","errorMessage":"usage_limit_reached","content":[]}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT model, stop_reason, tool_calls, input_tokens, cache_read_tokens, prompt_tokens, duration_ms, ttft_ms FROM model_turns WHERE harness='omp' AND stop_reason='tool_use';"
    assert_output_contains '"model":"openai-codex/gpt-x"'
    assert_output_contains '"tool_calls":2'
    assert_output_contains '"input_tokens":100'
    assert_output_contains '"cache_read_tokens":9000'
    assert_output_contains '"prompt_tokens":9100'
    assert_output_contains '"duration_ms":7000.5'
    assert_output_contains '"ttft_ms":1500.0'
    # An omp error stop must reach stop_events, or quota stalls stay invisible.
    run q "SELECT e.stop_reason, t.error_message FROM stop_events e JOIN model_turns t USING (sessionId, timestamp) WHERE e.harness='omp';"
    assert_output_contains '"stop_reason":"error"'
    assert_output_contains '"error_message":"usage_limit_reached"'
}

@test "ingest: claude entries that share a message.id fold into one model_turns row" {
    # Claude writes one raw entry per content block and repeats usage on each.
    cat > "$TEST_HOME/.claude/projects/proj/sess-frag.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","sessionId":"c-9","cwd":"/w","message":{"id":"msg_1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":50},"content":[{"type":"tool_use","id":"f1","name":"Read","input":{}}]}}
{"type":"assistant","timestamp":"2026-05-30T10:00:01Z","sessionId":"c-9","cwd":"/w","message":{"id":"msg_1","model":"claude-x","stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":50},"content":[{"type":"tool_use","id":"f2","name":"Read","input":{}}]}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT count(*) AS n, CAST(sum(output_tokens) AS BIGINT) AS out_tokens, max(tool_calls) AS calls, max(stop_reason) AS stop FROM model_turns WHERE harness='claude';"
    assert_output_contains '"n":1'
    assert_output_contains '"out_tokens":50'
    assert_output_contains '"calls":2'
    assert_output_contains '"stop":"tool_use"'
}

@test "ingest: a malformed omp metric becomes NULL and does not abort the ingest" {
    mkdir -p "$TEST_HOME/.omp/agent/sessions/proj"
    cat > "$TEST_HOME/.omp/agent/sessions/proj/bad.jsonl" <<'JSONL'
{"type":"session","id":"o-2","cwd":"/work/omp"}
{"type":"message","timestamp":"2026-05-30T13:00:00Z","message":{"role":"assistant","model":"gpt-x","stopReason":"stop","duration":"slow","usage":"n/a","contextSnapshot":[1],"content":[]}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT duration_ms, input_tokens, prompt_tokens, stop_reason FROM model_turns WHERE harness='omp';"
    assert_output_contains '"duration_ms":null'
    assert_output_contains '"input_tokens":null'
    assert_output_contains '"prompt_tokens":null'
    assert_output_contains '"stop_reason":"end_turn"'
}

@test "query: latency report filters by harness and counts error stops" {
    write_claude_fixture
    mkdir -p "$TEST_HOME/.omp/agent/sessions/proj"
    cat > "$TEST_HOME/.omp/agent/sessions/proj/s.jsonl" <<'JSONL'
{"type":"session","id":"o-3","cwd":"/work/omp"}
{"type":"message","timestamp":"2026-05-30T13:00:00Z","message":{"role":"assistant","provider":"p","model":"gpt-x","stopReason":"toolUse","duration":4000,"content":[{"type":"toolCall","id":"t1","name":"read","arguments":{}}]}}
{"type":"message","timestamp":"2026-05-30T13:00:09Z","message":{"role":"assistant","provider":"p","model":"gpt-x","stopReason":"error","errorMessage":"usage_limit_reached","content":[]}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    run env SESSIONS_DB="$DB" "$REAL_DOTFILES_DIR/skills/session-analytics/scripts/query.sh" latency omp
    assert_success
    assert_output_contains "error_stops"
    # One p/gpt-x row: 2 turns, 50% single-call, 4.0 s median, 1 error stop.
    [[ "$output" =~ omp[[:space:]]*\|[[:space:]]*p/gpt-x[[:space:]]*\|[[:space:]]*2[[:space:]]*\|[[:space:]]*0\.5[[:space:]]*\|[[:space:]]*50\.0[[:space:]]*\|[[:space:]]*4\.0 ]]
    [[ "$output" =~ \|[[:space:]]*1[[:space:]]*\|$ ]]
    [[ "$output" != *claude* ]]
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

@test "ingest: copilot is a documented no-log skip and never appears as a harness" {
    write_claude_fixture
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness='copilot';"
    assert_output_contains '"n":0'
}

# --- #704 ingest-gap hardening --------------------------------------------

@test "ingest: codex exec_command populates bash_cmd from cmd" {
    cat > "$TEST_HOME/.codex/sessions/2026/05/30/rollout-execcmd.jsonl" <<'JSONL'
{"timestamp":"2026-05-30T13:00:00Z","type":"session_meta","payload":{"id":"x-3","cwd":"/work/codex"}}
{"timestamp":"2026-05-30T13:00:02Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"git status\",\"workdir\":\"/work/codex\"}","call_id":"call-x-3"}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT bash_cmd FROM tool_uses WHERE harness='codex' AND tool_use_id='call-x-3';"
    assert_output_contains '"bash_cmd":"git status"'
}

@test "ingest: codex shell argv array normalizes to the -lc payload string" {
    # write_codex_fixture's shell call carries command:[\"ls\"] — before #704
    # the array extracted to NULL and command-level analysis was blind.
    write_codex_fixture
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT bash_cmd FROM tool_uses WHERE harness='codex' AND tool_use_id='call-x-1';"
    assert_output_contains '"bash_cmd":"ls"'
}

@test "ingest: codex custom_tool_call exec raw string round-trips call + output" {
    cat > "$TEST_HOME/.codex/sessions/2026/05/30/rollout-custom.jsonl" <<'JSONL'
{"timestamp":"2026-05-30T14:00:00Z","type":"session_meta","payload":{"id":"x-4","cwd":"/work/codex"}}
{"timestamp":"2026-05-30T14:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"text(ALL_TOOLS.length)","call_id":"call-x-4"}}
{"timestamp":"2026-05-30T14:00:03Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-x-4","output":"42"}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    # The exec call's raw code string is the command...
    run q "SELECT bash_cmd FROM tool_uses WHERE harness='codex' AND tool_use_id='call-x-4';"
    assert_output_contains '"bash_cmd":"text(ALL_TOOLS.length)"'
    # ...and custom_tool_call_output lands as a joined tool_result (this was
    # the ~50% codex result-join gap — every custom output was dropped).
    run q "SELECT content, is_error FROM tool_results WHERE harness='codex' AND tool_use_id='call-x-4';"
    assert_output_contains '"content":"42"'
    assert_output_contains '"is_error":"false"'
}

@test "ingest: claude absent is_error backfills to explicit false, flagged inexplicit" {
    cat > "$TEST_HOME/.claude/projects/proj/sess-noflag.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","sessionId":"c-2","cwd":"/w","message":{"content":[{"type":"tool_use","id":"tu-nf-1","name":"Read","input":{"file_path":"/x"}}]}}
{"type":"user","timestamp":"2026-05-30T10:00:01Z","sessionId":"c-2","message":{"content":[{"type":"tool_result","tool_use_id":"tu-nf-1","content":"ok"}]}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    # Absent flag must become an explicit 'false' (never NULL — a NULL is
    # invisible to the catalog's string compares), with is_error_explicit
    # recording that the source block carried no flag.
    run q "SELECT is_error, is_error_explicit FROM tool_results WHERE tool_use_id='tu-nf-1';"
    assert_output_contains '"is_error":"false"'
    assert_output_contains '"is_error_explicit":false'
}

@test "ingest: the coverage stanza reports per-harness join + flag quality" {
    write_claude_fixture
    write_codex_fixture
    run python3 "$INGEST" --force
    assert_success
    assert_output_contains "Coverage (per harness):"
    assert_output_contains "results_joined_pct"
    assert_output_contains "explicit_error_flag_pct"
}

@test "ingest: cursor remaps CallMcpTool only when server and toolName are present" {
    write_cursor_fixture
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT count(*) AS n FROM mcp_calls WHERE harness='cursor' AND tool_name='mcp__user-tilth__tilth_list';"
    assert_output_contains '"n":1'
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness='cursor' AND tool_name='CallMcpTool';"
    assert_output_contains '"n":1'
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness='cursor' AND tool_name='mcp__None__None';"
    assert_output_contains '"n":0'
}

@test "ingest: cursor Task rows land in agent_spawns and aborts become stop_reason=aborted" {
    write_cursor_fixture
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT agent_type FROM agent_spawns WHERE harness='cursor';"
    assert_output_contains '"agent_type":"explorer"'
    run q "SELECT stop_reason FROM stop_events WHERE harness='cursor';"
    assert_output_contains '"stop_reason":"aborted"'
    run q "SELECT project FROM sessions WHERE harness='cursor';"
    assert_output_contains '"project":"/zz/nope/dash/name"'
}

@test "ingest: cursor subagent files set isSidechain and parentUuid" {
    local parent="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local child="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    local dir="$TEST_HOME/.cursor/projects/zz-nope-dash-name/agent-transcripts/$parent/subagents"
    mkdir -p "$dir"
    cat > "$dir/$child.jsonl" <<'JSONL'
{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Sunday, Aug 23, 2026, 9:01 PM (UTC-7)</timestamp>\n<user_query>sub</user_query>"}]}}
{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"path":"/tmp/x"}}]}}
JSONL
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT isSidechain, parentUuid FROM raw_entries WHERE harness='cursor' AND sessionId='$child' LIMIT 1;"
    assert_output_contains '"isSidechain":true'
    assert_output_contains "\"parentUuid\":\"$parent\""
}

@test "ingest: cursor discover ignores jsonl outside agent-transcripts" {
    write_cursor_fixture
    mkdir -p "$TEST_HOME/.cursor/projects/zz-nope-dash-name"
    echo '{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}' > "$TEST_HOME/.cursor/projects/zz-nope-dash-name/noise.jsonl"
    run python3 "$INGEST" --force
    assert_success
    run q "SELECT count(*) AS n FROM tool_uses WHERE harness='cursor' AND tool_name='Read';"
    assert_output_contains '"n":0'
}

@test "ingest: cursor cwd resolve prefers the longest existing path segment" {
    run python3 -c "
import importlib.util, os, tempfile
spec = importlib.util.spec_from_file_location('ingest', '''$INGEST''')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
root = tempfile.mkdtemp()
os.makedirs(os.path.join(root, 'Users', 'paul', 'Dev', 'easy-cheese'))
got = mod._cursor_resolve_slug('Users-paul-Dev-easy-cheese', fs_root=root)
want = os.path.join(root, 'Users', 'paul', 'Dev', 'easy-cheese')
assert got == want, got
print('ok')
"
    assert_success
    assert_output_contains "ok"
}

@test "ingest: configured harness roots and relative database override resolve" {
    local roots="$TEST_HOME/portable-roots"
    mkdir -p "$roots/claude/projects/p" "$roots/codex/sessions" \
        "$roots/cursor/projects/p/agent-transcripts"
    touch "$roots/claude/projects/p/claude.jsonl"
    touch "$roots/codex/sessions/codex.jsonl"
    touch "$roots/cursor/projects/p/agent-transcripts/cursor.jsonl"
    run env CLAUDE_CONFIG_DIR="$roots/claude" CODEX_HOME="$roots/codex" CURSOR_HOME="$roots/cursor" SESSIONS_DB=relative.db \
        python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('ingest', '''$INGEST''')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.DB_PATH == os.path.abspath('relative.db')
assert mod.claude_discover() == [
    os.path.abspath('''$roots/claude/projects/p/claude.jsonl''')
]
assert mod.codex_discover() == [
    os.path.abspath('''$roots/codex/sessions/codex.jsonl''')
]
assert mod.cursor_discover() == [
    os.path.abspath('''$roots/cursor/projects/p/agent-transcripts/cursor.jsonl''')
]
print('ok')
"
    assert_success
    assert_output_contains "ok"
}

# --- portable cache placement hardening ------------------------------------

@test "ingest: SESSIONS_DB stage dir never collides with a sibling 'stage' directory" {
    write_claude_fixture
    mkdir -p "$TEST_HOME/stage"
    touch "$TEST_HOME/stage/file.txt"
    export SESSIONS_DB="$TEST_HOME/db.duckdb"
    run python3 "$INGEST" --force
    assert_success
    # The pre-existing sibling 'stage' dir must survive: STAGE_DIR is derived
    # from the database file name, not its parent dir, so it never aliases
    # (and rmtree's) an unrelated 'stage' directory next to the database.
    assert_file_exists "$TEST_HOME/stage/file.txt"
    assert_dir_exists "$TEST_HOME/db.duckdb.stage"
}

@test "ingest: an apostrophe in SESSIONS_DB's path still ingests (SQL-quoted stage glob)" {
    write_claude_fixture
    local qdir="$TEST_HOME/o'brien"
    mkdir -p "$qdir"
    export SESSIONS_DB="$qdir/sessions.duckdb"
    run python3 "$INGEST" --force
    assert_success
    run duckdb -init /dev/null "$SESSIONS_DB" -json -c "SELECT count(*) AS n FROM tool_uses WHERE harness='claude';"
    assert_output_contains '"n":1'
}

@test "ingest: a relative XDG_CACHE_HOME is ignored; the default resolves under HOME" {
    run env XDG_CACHE_HOME=relative/cache python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('ingest', '''$INGEST''')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
want = os.path.join(os.path.expanduser('~'), '.cache', 'dotfiles', 'session-analytics')
assert mod.DEFAULT_DB_DIR == want, mod.DEFAULT_DB_DIR
print('ok')
"
    assert_success
    assert_output_contains "ok"
}
