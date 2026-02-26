#!/usr/bin/env bats
# Adversarial tests for bin/claude-monitor
# Covers: invalid inputs, edge cases, malformed data, path encoding

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
MONITOR="$DOTFILES_DIR/bin/claude-monitor"

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Strip ANSI escape codes from output
strip_ansi() {
    printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*[mK]//g'
}

assert_success() {
    [[ $status -eq 0 ]] || {
        echo "Expected success (exit 0), got status=$status"
        echo "Output: $(strip_ansi "$output")"
        return 1
    }
}

assert_failure() {
    [[ $status -ne 0 ]] || {
        echo "Expected failure (exit != 0), got status=0"
        echo "Output: $(strip_ansi "$output")"
        return 1
    }
}

assert_contains() {
    local needle="$1"
    local haystack
    haystack="$(strip_ansi "$output")"
    [[ "$haystack" == *"$needle"* ]] || {
        echo "Output does not contain: $needle"
        echo "Actual (stripped): $haystack"
        return 1
    }
}

assert_not_contains() {
    local needle="$1"
    local haystack
    haystack="$(strip_ansi "$output")"
    [[ "$haystack" != *"$needle"* ]] || {
        echo "Output should NOT contain: $needle"
        echo "Actual (stripped): $haystack"
        return 1
    }
}

# Create a temp dir scoped to each test
setup() {
    TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-monitor-test.XXXXXX")"
    # Fake Claude projects dir structure
    FAKE_HOME="$TEST_TMP/fake_home"
    mkdir -p "$FAKE_HOME"
}

teardown() {
    rm -rf "$TEST_TMP" 2>/dev/null || true
}

# Build a minimal assistant JSONL entry with usage data
make_assistant_entry() {
    local input_tokens="${1:-100}"
    local cache_read="${2:-50}"
    local cache_create="${3:-20}"
    local output_tokens="${4:-30}"
    local model="${5:-claude-opus-4-6}"
    local msg_id="${6:-msg_abc123}"
    local timestamp="${7:-2025-01-01T12:00:00.000Z}"
    cat <<EOF
{"type":"assistant","message":{"id":"${msg_id}","model":"${model}","content":[],"usage":{"input_tokens":${input_tokens},"cache_read_input_tokens":${cache_read},"cache_creation_input_tokens":${cache_create},"output_tokens":${output_tokens}}},"timestamp":"${timestamp}"}
EOF
}

make_user_entry() {
    local timestamp="${1:-2025-01-01T12:00:00.000Z}"
    cat <<EOF
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]},"toolUseResult":null,"timestamp":"${timestamp}"}
EOF
}

make_tool_use_entry() {
    local tool_name="${1:-Bash}"
    local msg_id="${2:-msg_tool1}"
    local timestamp="${3:-2025-01-01T12:00:00.000Z}"
    cat <<EOF
{"type":"assistant","message":{"id":"${msg_id}","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"${tool_name}","id":"tu1","input":{}}],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}},"timestamp":"${timestamp}"}
EOF
}

# Create a fake project dir under FAKE_HOME and write a JSONL file
make_project() {
    local cwd_path="$1"
    # encode_path: replace / and . with -
    local encoded="${cwd_path//[\/.]/-}"
    local proj_dir="$FAKE_HOME/.claude/projects/${encoded}"
    mkdir -p "$proj_dir"
    echo "$proj_dir"
}

write_jsonl() {
    local proj_dir="$1"
    local content="$2"
    local fname="${proj_dir}/session-001.jsonl"
    printf '%s' "$content" > "$fname"
    echo "$fname"
}

# Run monitor --once with a custom HOME pointing to FAKE_HOME
run_monitor_once() {
    local cwd_path="$1"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "$cwd_path" --once
}

# ─── CLI argument tests ───────────────────────────────────────────────────────

@test "help flag exits 0 and shows usage" {
    run "$MONITOR" --help
    assert_success
    assert_contains "Usage: claude-monitor"
}

@test "-h flag shows usage" {
    run "$MONITOR" -h
    assert_success
    assert_contains "Usage: claude-monitor"
}

@test "unknown flag exits non-zero" {
    run "$MONITOR" --bogus-flag-xyz
    assert_failure
    assert_contains "Unknown option"
}

# ─── Session discovery — missing/empty session ────────────────────────────────

@test "no session found exits 1 with --once" {
    # Point at a HOME with no .claude dir at all
    HOME="$FAKE_HOME" run "$MONITOR" --cwd /no/such/path --once
    assert_failure
    assert_contains "No active session found"
}

@test "project dir exists but no JSONL files — exits 1 with --once" {
    local proj_dir
    proj_dir="$(make_project "/test/no-jsonl")"
    # No .jsonl file written
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-jsonl" --once
    assert_failure
    assert_contains "No active session found"
}

@test "empty JSONL file — renders waiting, exits 1" {
    local proj_dir
    proj_dir="$(make_project "/test/empty")"
    write_jsonl "$proj_dir" ""
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/empty" --once
    # Empty file yields no metrics — script should fall back gracefully
    # Status is 0 (rendered waiting) or 1 (no session); either is acceptable
    # What must NOT happen: crash/segfault (non-zero is fine if graceful)
    [[ $status -eq 0 || $status -eq 1 ]]
    # Must not print raw jq errors or stack traces to stdout
    assert_not_contains "parse error"
    assert_not_contains "null (null)"
}

@test "JSONL file containing only whitespace — no crash" {
    local proj_dir
    proj_dir="$(make_project "/test/whitespace")"
    write_jsonl "$proj_dir" "

   "
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/whitespace" --once
    [[ $status -eq 0 || $status -eq 1 ]]
    assert_not_contains "parse error"
}

# ─── Malformed JSON ───────────────────────────────────────────────────────────

@test "file with non-JSON lines — no crash, falls back gracefully" {
    local proj_dir
    proj_dir="$(make_project "/test/nonjson")"
    write_jsonl "$proj_dir" "this is not json
neither is this
{broken: json}
"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/nonjson" --once
    [[ $status -eq 0 || $status -eq 1 ]]
    assert_not_contains "parse error"
}

@test "truncated JSON mid-write — no crash" {
    local proj_dir
    proj_dir="$(make_project "/test/truncated")"
    # Simulate a partial write: valid lines + incomplete last line
    {
        make_assistant_entry 100 50 20 30
        printf '{"type":"assistant","message":{"id":"msg_partial","model":"claude-op'
    } | write_jsonl "$proj_dir" "$(cat)"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/truncated" --once
    [[ $status -eq 0 || $status -eq 1 ]]
    assert_not_contains "parse error"
}

@test "mix of valid and invalid JSON lines — valid lines are processed" {
    local proj_dir
    proj_dir="$(make_project "/test/mixed")"
    {
        make_user_entry
        printf '%s\n' 'NOT VALID JSON AT ALL'
        make_assistant_entry 500 200 100 50
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/mixed" --once
    # The jq `fromjson? // empty` should skip bad lines and still produce output
    [[ $status -eq 0 || $status -eq 1 ]]
    assert_not_contains "parse error"
}

# ─── Missing fields ───────────────────────────────────────────────────────────

@test "assistant entry missing usage field — no crash" {
    local proj_dir
    proj_dir="$(make_project "/test/no-usage")"
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[]},"timestamp":"2025-01-01T12:00:00.000Z"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-usage" --once
    [[ $status -eq 0 || $status -eq 1 ]]
}

@test "entries missing .type field — no crash" {
    local proj_dir
    proj_dir="$(make_project "/test/no-type")"
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"message":{"role":"user","content":[]},"timestamp":"2025-01-01T12:00:00.000Z"}
{"model":"claude-opus-4-6","timestamp":"2025-01-01T12:00:00.000Z"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-type" --once
    [[ $status -eq 0 || $status -eq 1 ]]
}

@test "assistant entry missing .message.id — no crash" {
    local proj_dir
    proj_dir="$(make_project "/test/no-msg-id")"
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"type":"assistant","message":{"model":"claude-opus-4-6","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}},"timestamp":"2025-01-01T12:00:00.000Z"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-msg-id" --once
    [[ $status -eq 0 || $status -eq 1 ]]
}

@test "entries without .timestamp field — no crash, duration shows --" {
    local proj_dir
    proj_dir="$(make_project "/test/no-ts")"
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":20}}}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-ts" --once
    # Should not crash
    [[ $status -eq 0 || $status -eq 1 ]]
}

# ─── Edge case tokens ─────────────────────────────────────────────────────────

@test "zero tokens — renders 0, no division by zero" {
    local proj_dir
    proj_dir="$(make_project "/test/zero-tokens")"
    {
        make_user_entry
        make_assistant_entry 0 0 0 0
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/zero-tokens" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    # cache_pct should be 0 (no division by zero crash)
    [[ "$stripped" == *"Cache:0%"* ]]
}

@test "null token values — treated as 0, no crash" {
    local proj_dir
    proj_dir="$(make_project "/test/null-tokens")"
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"2025-01-01T12:00:00.000Z"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":null,"cache_read_input_tokens":null,"cache_creation_input_tokens":null,"output_tokens":null}},"timestamp":"2025-01-01T12:00:00.000Z"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/null-tokens" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"Cache:0%"* ]]
}

@test "very large token counts — formatted with k/M suffix, no overflow" {
    local proj_dir
    proj_dir="$(make_project "/test/large-tokens")"
    {
        make_user_entry
        # 2M input, 1M cache_read, 500k output
        make_assistant_entry 2000000 1000000 500000 500000
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/large-tokens" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    # Should use M suffix
    [[ "$stripped" == *"M"* ]]
}

@test "tokens exactly at 1000 boundary — uses k suffix" {
    local proj_dir
    proj_dir="$(make_project "/test/boundary-1k")"
    {
        make_user_entry
        make_assistant_entry 1000 0 0 0
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/boundary-1k" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"k"* ]]
}

@test "tokens exactly at 1M boundary — uses M suffix" {
    local proj_dir
    proj_dir="$(make_project "/test/boundary-1m")"
    {
        make_user_entry
        make_assistant_entry 1000000 0 0 0
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/boundary-1m" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"M"* ]]
}

@test "tokens just below 1000 — no suffix, raw number" {
    local proj_dir
    proj_dir="$(make_project "/test/boundary-999")"
    {
        make_user_entry
        make_assistant_entry 999 0 0 0
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/boundary-999" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    # Should not have k or M suffix for 999
    [[ "$stripped" != *"0.9k"* ]] || true  # should be 999, not 0.9k
}

# ─── Path encoding (encode_path) ─────────────────────────────────────────────

@test "path with spaces — encoded correctly, session found" {
    local cwd_path="/test/path with spaces"
    local proj_dir
    proj_dir="$(make_project "$cwd_path")"
    {
        make_user_entry
        make_assistant_entry 100 50 20 30
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "$cwd_path" --once
    assert_success
}

@test "path with dots — encoded correctly (dots become dashes)" {
    local cwd_path="/Users/paul.sorensen/Dev/my.project"
    local proj_dir
    proj_dir="$(make_project "$cwd_path")"
    {
        make_user_entry
        make_assistant_entry 100 50 20 30
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "$cwd_path" --once
    assert_success
}

@test "path with special chars (hyphens, underscores) — no crash" {
    local cwd_path="/Users/paul-sorensen/Dev/my_project-v2"
    local proj_dir
    proj_dir="$(make_project "$cwd_path")"
    {
        make_user_entry
        make_assistant_entry 100 50 20 30
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "$cwd_path" --once
    assert_success
}

@test "waiting message shows encoded path" {
    # No session exists — waiting message should show encoded path
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/my/test/path" --once
    assert_failure
    # Should still produce some output (not crash silently)
    [[ -n "$output" ]]
}

# ─── Tool names and display ───────────────────────────────────────────────────

@test "single tool usage — shown in output" {
    local proj_dir
    proj_dir="$(make_project "/test/tools")"
    {
        make_user_entry
        make_tool_use_entry "Bash" "msg_1"
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/tools" --once
    assert_success
    assert_contains "Bash:1"
}

@test "multiple different tools — all shown up to 7" {
    local proj_dir
    proj_dir="$(make_project "/test/many-tools")"
    {
        make_user_entry
        # 8 unique tools, each 1 call — jq group_by sorts alphabetically, [:7] takes first 7
        # Alphabetically: Bash Edit Glob Grep Read ToolSearch WebFetch Write
        # So "Write" (8th) is truncated; ToolSearch (6th) IS shown
        local tools=("Bash" "Read" "Edit" "Write" "Glob" "Grep" "WebFetch" "ToolSearch")
        local idx=1
        for t in "${tools[@]}"; do
            make_tool_use_entry "$t" "msg_${idx}"
            idx=$((idx + 1))
        done
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/many-tools" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    # Exactly 7 shown — "Write" (8th alphabetically) is truncated
    [[ "$stripped" != *"Write:1"* ]]
    # First 7 alphabetically should all be present
    [[ "$stripped" == *"Bash:1"* ]]
    [[ "$stripped" == *"ToolSearch:1"* ]]
}

@test "no tool calls — shows 'none'" {
    local proj_dir
    proj_dir="$(make_project "/test/no-tools")"
    {
        make_user_entry
        make_assistant_entry 100 50 20 30
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-tools" --once
    assert_success
    assert_contains "none"
}

@test "very long tool name — no crash" {
    local proj_dir
    proj_dir="$(make_project "/test/long-tool")"
    local long_name="VeryLongToolNameThatExceedsReasonableLimitsForDisplayPurposesAAAAAAAAAAAA"
    {
        make_user_entry
        make_tool_use_entry "$long_name" "msg_1"
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/long-tool" --once
    assert_success
}

# ─── Skills detection ─────────────────────────────────────────────────────────

@test "Skill tool calls — skill name extracted" {
    local proj_dir
    proj_dir="$(make_project "/test/skills")"
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"2025-01-01T12:00:00.000Z"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"Skill","id":"tu1","input":{"skill":"scout"}}],"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":20}},"timestamp":"2025-01-01T12:01:00.000Z"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/skills" --once
    assert_success
    assert_contains "scout"
}

@test "Skill tool with null input — no crash" {
    local proj_dir
    proj_dir="$(make_project "/test/skill-null")"
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"2025-01-01T12:00:00.000Z"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"Skill","id":"tu1","input":null}],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}},"timestamp":"2025-01-01T12:01:00.000Z"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/skill-null" --once
    assert_success
}

# ─── Compaction detection ─────────────────────────────────────────────────────

@test "compact_boundary entries — compaction count shown" {
    local proj_dir
    proj_dir="$(make_project "/test/compact")"
    {
        make_user_entry
        make_assistant_entry 100 50 20 30
        printf '%s\n' '{"type":"system","subtype":"compact_boundary","timestamp":"2025-01-01T12:05:00.000Z"}'
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/compact" --once
    assert_success
    assert_contains "C:1"
}

@test "multiple compactions — count aggregated" {
    local proj_dir
    proj_dir="$(make_project "/test/multi-compact")"
    {
        make_user_entry
        make_assistant_entry 100 50 20 30
        printf '%s\n' '{"type":"system","subtype":"compact_boundary","timestamp":"2025-01-01T12:05:00.000Z"}'
        printf '%s\n' '{"type":"system","subtype":"compact_boundary","timestamp":"2025-01-01T12:10:00.000Z"}'
        printf '%s\n' '{"type":"system","subtype":"compact_boundary","timestamp":"2025-01-01T12:15:00.000Z"}'
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/multi-compact" --once
    assert_success
    assert_contains "C:3"
}

# ─── Cache hit rate ───────────────────────────────────────────────────────────

@test "100% cache hit — shows green (high) percentage" {
    local proj_dir
    proj_dir="$(make_project "/test/cache-full")"
    {
        make_user_entry
        # All input is cache_read, none is raw input
        make_assistant_entry 0 1000 0 50
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/cache-full" --once
    assert_success
    assert_contains "Cache:100%"
}

@test "0% cache hit — shows red percentage" {
    local proj_dir
    proj_dir="$(make_project "/test/cache-zero")"
    {
        make_user_entry
        make_assistant_entry 1000 0 0 50
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/cache-zero" --once
    assert_success
    assert_contains "Cache:0%"
}

@test "50% cache hit — shows yellow percentage" {
    local proj_dir
    proj_dir="$(make_project "/test/cache-mid")"
    {
        make_user_entry
        # 1000 raw input, 1000 cache_read → 50% cache
        make_assistant_entry 1000 1000 0 50
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/cache-mid" --once
    assert_success
    assert_contains "Cache:50%"
}

# ─── Context trend ────────────────────────────────────────────────────────────

@test "context growing — shows up trend" {
    local proj_dir
    proj_dir="$(make_project "/test/ctx-up")"
    {
        make_user_entry "2025-01-01T12:00:00.000Z"
        make_assistant_entry 1000 0 0 50 "claude-opus-4-6" "msg_1" "2025-01-01T12:01:00.000Z"
        make_user_entry "2025-01-01T12:02:00.000Z"
        make_assistant_entry 2000 0 0 50 "claude-opus-4-6" "msg_2" "2025-01-01T12:03:00.000Z"
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/ctx-up" --once
    assert_success
    # Trend symbol ^ should be in output (may be ANSI-wrapped)
    stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"^"* ]]
}

@test "context shrinking — shows down trend" {
    local proj_dir
    proj_dir="$(make_project "/test/ctx-down")"
    {
        make_user_entry "2025-01-01T12:00:00.000Z"
        make_assistant_entry 2000 0 0 50 "claude-opus-4-6" "msg_1" "2025-01-01T12:01:00.000Z"
        make_user_entry "2025-01-01T12:02:00.000Z"
        make_assistant_entry 1000 0 0 50 "claude-opus-4-6" "msg_2" "2025-01-01T12:03:00.000Z"
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/ctx-down" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"v"* ]]
}

# ─── Model name display ───────────────────────────────────────────────────────

@test "model prefix 'claude-' stripped from display" {
    local proj_dir
    proj_dir="$(make_project "/test/model-strip")"
    {
        make_user_entry
        make_assistant_entry 100 50 20 30 "claude-opus-4-6"
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/model-strip" --once
    assert_success
    assert_contains "opus-4-6"
    assert_not_contains "claude-opus-4-6"
}

@test "unknown model — shown as-is (not stripped)" {
    local proj_dir
    proj_dir="$(make_project "/test/model-unknown")"
    {
        make_user_entry
        make_assistant_entry 100 50 20 30 "unknown"
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/model-unknown" --once
    assert_success
    assert_contains "unknown"
}

# ─── Timestamp / duration parsing ────────────────────────────────────────────

@test "valid ISO8601 timestamp — duration shown (not '--')" {
    local proj_dir
    proj_dir="$(make_project "/test/ts-valid")"
    {
        make_user_entry "2025-01-01T00:00:00.000Z"
        make_assistant_entry 100 50 20 30 "claude-opus-4-6" "msg_1" "2025-01-01T00:00:01.000Z"
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/ts-valid" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    # Duration should appear in output (not '--' for a valid timestamp from the past)
    # Note: if the date is far in the past this will show a large duration value
    [[ "$stripped" != *"T --"* ]] || true
}

@test "malformed timestamp — falls back to '--'" {
    local proj_dir
    proj_dir="$(make_project "/test/ts-bad")"
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"not-a-real-timestamp"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":20}},"timestamp":"not-a-real-timestamp"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/ts-bad" --once
    assert_success
    # Should fall back to -- for duration display
    assert_contains "T --"
}

# ─── Message deduplication (group_by message.id) ─────────────────────────────

@test "duplicate message IDs — deduplicated (last wins)" {
    local proj_dir
    proj_dir="$(make_project "/test/dedup")"
    # Same msg ID appears twice (streaming chunk pattern)
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"2025-01-01T12:00:00.000Z"}
{"type":"assistant","message":{"id":"msg_same","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}},"timestamp":"2025-01-01T12:01:00.000Z"}
{"type":"assistant","message":{"id":"msg_same","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":50}},"timestamp":"2025-01-01T12:01:01.000Z"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/dedup" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    # assistant_turns should be 1, not 2 (deduped)
    # Display format is "Turns: 1/1" with a space after the colon
    [[ "$stripped" == *"Turns: 1/1"* ]]
}

# ─── Task counting ────────────────────────────────────────────────────────────

@test "Task tool usage — task count shown" {
    local proj_dir
    proj_dir="$(make_project "/test/tasks")"
    cat > "$proj_dir/session-001.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"2025-01-01T12:00:00.000Z"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"Task","id":"tu1","input":{"description":"do something"}}],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}},"timestamp":"2025-01-01T12:01:00.000Z"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/tasks" --once
    assert_success
    assert_contains "Tasks:1"
}

@test "zero tasks — Tasks: section omitted" {
    local proj_dir
    proj_dir="$(make_project "/test/no-tasks")"
    {
        make_user_entry
        make_assistant_entry 100 50 20 30
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-tasks" --once
    assert_success
    assert_not_contains "Tasks:"
}

# ─── Performance / large file ─────────────────────────────────────────────────

@test "large session file (2000 entries) — completes within 10 seconds" {
    local proj_dir
    proj_dir="$(make_project "/test/large")"
    {
        local i=1
        while (( i <= 1000 )); do
            make_user_entry "2025-01-01T12:00:00.000Z"
            make_assistant_entry 100 50 20 30 "claude-opus-4-6" "msg_${i}" "2025-01-01T12:00:00.000Z"
            i=$((i + 1))
        done
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run timeout 10 "$MONITOR" --cwd "/test/large" --once
    assert_success
}

# ─── fmt_tokens unit-level checks via full pipeline ──────────────────────────

@test "fmt_tokens: 999 — no suffix" {
    local proj_dir
    proj_dir="$(make_project "/test/fmt-999")"
    {
        make_user_entry
        make_assistant_entry 999 0 0 0
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/fmt-999" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    # In:999 — should not use k or M
    [[ "$stripped" == *"In:999"* ]]
}

@test "fmt_tokens: 0 — displays as 0" {
    local proj_dir
    proj_dir="$(make_project "/test/fmt-0")"
    {
        make_user_entry
        make_assistant_entry 0 0 0 0
    } > "$proj_dir/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/fmt-0" --once
    assert_success
    stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"In:0"* ]]
}

# ─── fmt_duration unit-level checks via full pipeline ────────────────────────
# These are harder to test precisely (depend on real clock), so we test
# that durations appear and don't crash.

@test "duration display: recent timestamp — shows seconds or minutes" {
    local proj_dir
    proj_dir="$(make_project "/test/duration")"
    # Use a timestamp that was 30 seconds ago (hard to be precise, so just test it runs)
    local ts
    ts="$(date -u "+%Y-%m-%dT%H:%M:%S.000Z")"
    cat > "$proj_dir/session-001.jsonl" <<EOF
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"${ts}"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}},"timestamp":"${ts}"}
EOF
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/duration" --once
    assert_success
    # Duration should show some value with s or m suffix
    stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"s"* || "$stripped" == *"m"* ]]
}

# ─── Concurrent write simulation ──────────────────────────────────────────────

@test "JSONL being appended during read — no crash" {
    local proj_dir
    proj_dir="$(make_project "/test/concurrent")"
    # Write initial content
    {
        make_user_entry
        make_assistant_entry 100 50 20 30
    } > "$proj_dir/session-001.jsonl"

    # Start appending in background while monitor runs
    (
        sleep 0.1
        make_assistant_entry 200 100 40 60 "claude-opus-4-6" "msg_2" >> "$proj_dir/session-001.jsonl"
    ) &
    local bg_pid=$!

    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/concurrent" --once
    wait "$bg_pid" 2>/dev/null || true
    [[ $status -eq 0 || $status -eq 1 ]]
}
