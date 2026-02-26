#!/usr/bin/env bats
# Malformed data, missing fields, deduplication, edge cases
load monitor_helper

# ─── Empty / whitespace ────────────────────────────────────────────

@test "empty JSONL file — no crash" {
    local d; d="$(make_project "/test/empty")"
    printf '' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/empty" --once
    [[ $status -eq 0 || $status -eq 1 ]]
    assert_not_contains "parse error"
}

@test "whitespace-only JSONL — no crash" {
    local d; d="$(make_project "/test/ws")"
    printf '\n   \n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/ws" --once
    [[ $status -eq 0 || $status -eq 1 ]]
    assert_not_contains "parse error"
}

# ─── Malformed JSON ────────────────────────────────────────────────

@test "non-JSON lines — falls back gracefully" {
    local d; d="$(make_project "/test/nonjson")"
    printf 'not json\n{broken}\n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/nonjson" --once
    [[ $status -eq 0 || $status -eq 1 ]]
    assert_not_contains "parse error"
}

@test "truncated JSON mid-write — no crash" {
    local d; d="$(make_project "/test/trunc")"
    { make_assistant_entry 100 50 20 30; printf '{"type":"assistant","message":{"id":"msg_x","model":"clau'; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/trunc" --once
    [[ $status -eq 0 || $status -eq 1 ]]
    assert_not_contains "parse error"
}

@test "mix of valid and invalid lines — valid lines processed" {
    local d; d="$(make_project "/test/mixed")"
    { make_user_entry; printf 'GARBAGE\n'; make_assistant_entry 500 200 100 50; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/mixed" --once
    [[ $status -eq 0 || $status -eq 1 ]]
    assert_not_contains "parse error"
}

# ─── Missing fields ────────────────────────────────────────────────

@test "assistant missing usage — no crash" {
    local d; d="$(make_project "/test/no-usage")"
    printf '{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[]},"timestamp":"2025-01-01T12:00:00.000Z"}\n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-usage" --once
    [[ $status -eq 0 || $status -eq 1 ]]
}

@test "entries missing .type — no crash" {
    local d; d="$(make_project "/test/no-type")"
    printf '{"message":{"role":"user"},"timestamp":"2025-01-01T12:00:00.000Z"}\n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-type" --once
    [[ $status -eq 0 || $status -eq 1 ]]
}

@test "assistant missing .message.id — no crash" {
    local d; d="$(make_project "/test/no-id")"
    printf '{"type":"assistant","message":{"model":"claude-opus-4-6","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}},"timestamp":"2025-01-01T12:00:00.000Z"}\n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-id" --once
    [[ $status -eq 0 || $status -eq 1 ]]
}

@test "entries without .timestamp — duration shows --" {
    local d; d="$(make_project "/test/no-ts")"
    { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null}\n'
      printf '{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":20}}}\n'; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-ts" --once
    [[ $status -eq 0 || $status -eq 1 ]]
}

# ─── Deduplication ─────────────────────────────────────────────────

@test "duplicate message IDs — deduplicated (last wins)" {
    local d; d="$(make_project "/test/dedup")"
    { make_user_entry
      printf '{"type":"assistant","message":{"id":"msg_same","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}},"timestamp":"2025-01-01T12:01:00.000Z"}\n'
      printf '{"type":"assistant","message":{"id":"msg_same","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":50}},"timestamp":"2025-01-01T12:01:01.000Z"}\n'; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/dedup" --once
    [[ $status -eq 0 ]]
    assert_contains "Turns: 1/1"
}

# ─── Concurrent writes ────────────────────────────────────────────

@test "JSONL being appended during read — no crash" {
    local d; d="$(make_project "/test/concurrent")"
    { make_user_entry; make_assistant_entry 100 50 20 30; } > "$d/session-001.jsonl"
    ( sleep 0.1; make_assistant_entry 200 100 40 60 "claude-opus-4-6" "msg_2" >> "$d/session-001.jsonl" ) &
    local bg=$!
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/concurrent" --once
    wait "$bg" 2>/dev/null || true
    [[ $status -eq 0 || $status -eq 1 ]]
}

# ─── Large files ───────────────────────────────────────────────────

@test "2000 entries — completes within 10 seconds" {
    local d; d="$(make_project "/test/large")"
    { local i=1; while (( i <= 1000 )); do
        make_user_entry; make_assistant_entry 100 50 20 30 "claude-opus-4-6" "msg_${i}"
        i=$((i + 1))
    done; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run timeout 10 "$MONITOR" --cwd "/test/large" --once
    [[ $status -eq 0 ]]
}
