#!/usr/bin/env bats
# Metric extraction and display tests for claude-monitor
load monitor_helper

# ─── Token formatting ──────────────────────────────────────────────

@test "zero tokens — renders 0, no division by zero" {
    local d; d="$(make_project "/test/zero")"
    { make_user_entry; make_assistant_entry 0 0 0 0; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/zero" --once
    [[ $status -eq 0 ]]
    assert_contains "Cache:0%"
}

@test "null token values — treated as 0" {
    local d; d="$(make_project "/test/null-tok")"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"2025-01-01T12:00:00.000Z"}\n{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":null,"cache_read_input_tokens":null,"cache_creation_input_tokens":null,"output_tokens":null}},"timestamp":"2025-01-01T12:00:00.000Z"}\n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/null-tok" --once
    [[ $status -eq 0 ]]
    assert_contains "Cache:0%"
}

@test "large tokens — M suffix" {
    local d; d="$(make_project "/test/big")"
    { make_user_entry; make_assistant_entry 2000000 1000000 500000 500000; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/big" --once
    [[ $status -eq 0 ]]
    assert_contains "M"
}

@test "tokens at 1000 boundary — k suffix" {
    local d; d="$(make_project "/test/1k")"
    { make_user_entry; make_assistant_entry 1000 0 0 0; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/1k" --once
    [[ $status -eq 0 ]]
    assert_contains "k"
}

@test "tokens at 999 — no suffix, raw number" {
    local d; d="$(make_project "/test/999")"
    { make_user_entry; make_assistant_entry 999 0 0 0; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/999" --once
    [[ $status -eq 0 ]]
    local stripped; stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"In:999"* ]]
    [[ "$stripped" != *"0.9k"* ]]
}

@test "tokens 0 — displays In:0" {
    local d; d="$(make_project "/test/fmt-0")"
    { make_user_entry; make_assistant_entry 0 0 0 0; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/fmt-0" --once
    [[ $status -eq 0 ]]
    assert_contains "In:0"
}

# ─── Cache hit rate ────────────────────────────────────────────────

@test "100% cache hit" {
    local d; d="$(make_project "/test/cache-100")"
    { make_user_entry; make_assistant_entry 0 1000 0 50; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/cache-100" --once
    [[ $status -eq 0 ]]
    assert_contains "Cache:100%"
}

@test "0% cache hit" {
    local d; d="$(make_project "/test/cache-0")"
    { make_user_entry; make_assistant_entry 1000 0 0 50; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/cache-0" --once
    [[ $status -eq 0 ]]
    assert_contains "Cache:0%"
}

@test "50% cache hit" {
    local d; d="$(make_project "/test/cache-50")"
    { make_user_entry; make_assistant_entry 1000 1000 0 50; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/cache-50" --once
    [[ $status -eq 0 ]]
    assert_contains "Cache:50%"
}

# ─── Context trend ─────────────────────────────────────────────────

@test "context growing — up trend" {
    local d; d="$(make_project "/test/ctx-up")"
    { make_user_entry; make_assistant_entry 1000 0 0 50 "claude-opus-4-6" "msg_1"
      make_user_entry "2025-01-01T12:02:00.000Z"; make_assistant_entry 2000 0 0 50 "claude-opus-4-6" "msg_2" "2025-01-01T12:03:00.000Z"; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/ctx-up" --once
    [[ $status -eq 0 ]]
    local stripped; stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"^"* ]]
}

@test "context shrinking — down trend" {
    local d; d="$(make_project "/test/ctx-dn")"
    { make_user_entry; make_assistant_entry 2000 0 0 50 "claude-opus-4-6" "msg_1"
      make_user_entry "2025-01-01T12:02:00.000Z"; make_assistant_entry 1000 0 0 50 "claude-opus-4-6" "msg_2" "2025-01-01T12:03:00.000Z"; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/ctx-dn" --once
    [[ $status -eq 0 ]]
    local stripped; stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"v"* ]]
}

# ─── Model name ────────────────────────────────────────────────────

@test "claude- prefix stripped from model" {
    local d; d="$(make_project "/test/model")"
    { make_user_entry; make_assistant_entry 100 50 20 30 "claude-opus-4-6"; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/model" --once
    [[ $status -eq 0 ]]
    assert_contains "opus-4-6"
    assert_not_contains "claude-opus-4-6"
}

@test "unknown model — shown as-is" {
    local d; d="$(make_project "/test/unk-model")"
    { make_user_entry; make_assistant_entry 100 50 20 30 "unknown"; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/unk-model" --once
    [[ $status -eq 0 ]]
    assert_contains "unknown"
}

# ─── Timestamps / duration ─────────────────────────────────────────

@test "valid timestamp — duration is not --" {
    local d; d="$(make_project "/test/ts-ok")"
    local ts; ts="$(date -u "+%Y-%m-%dT%H:%M:%S.000Z")"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"%s"}\n' "$ts" > "$d/session-001.jsonl"
    printf '{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}},"timestamp":"%s"}\n' "$ts" >> "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/ts-ok" --once
    [[ $status -eq 0 ]]
    local stripped; stripped="$(strip_ansi "$output")"
    if [[ "$stripped" == *"T --"* ]]; then
        echo "Expected duration not to be '--' for valid ISO8601 timestamps"
        return 1
    fi
}

@test "malformed timestamp — duration falls back to --" {
    local d; d="$(make_project "/test/ts-bad")"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"not-real"}\n{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":20}},"timestamp":"not-real"}\n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/ts-bad" --once
    [[ $status -eq 0 ]]
    assert_contains "T --"
}

# ─── Tools ─────────────────────────────────────────────────────────

@test "single tool — shown in output" {
    local d; d="$(make_project "/test/tool1")"
    { make_user_entry; make_tool_use_entry "Bash" "msg_1"; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/tool1" --once
    [[ $status -eq 0 ]]
    assert_contains "Bash:1"
}

@test "8 tools — capped at 7" {
    local d; d="$(make_project "/test/tools8")"
    { make_user_entry
      for t in Bash Read Edit Write Glob Grep WebFetch ToolSearch; do
          make_tool_use_entry "$t" "msg_${t}"
      done; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/tools8" --once
    [[ $status -eq 0 ]]
    assert_not_contains "Write:1"
    assert_contains "Bash:1"
}

@test "no tool calls — shows none" {
    local d; d="$(make_project "/test/no-tools")"
    { make_user_entry; make_assistant_entry 100 50 20 30; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-tools" --once
    [[ $status -eq 0 ]]
    assert_contains "none"
}

@test "very long tool name — no crash" {
    local d; d="$(make_project "/test/long-tool")"
    { make_user_entry; make_tool_use_entry "VeryLongToolNameAAAAAAAAAAAA" "msg_1"; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/long-tool" --once
    [[ $status -eq 0 ]]
}

# ─── Skills ────────────────────────────────────────────────────────

@test "Skill tool — skill name extracted" {
    local d; d="$(make_project "/test/skill")"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"2025-01-01T12:00:00.000Z"}\n{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"Skill","id":"tu1","input":{"skill":"scout"}}],"usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":20}},"timestamp":"2025-01-01T12:01:00.000Z"}\n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/skill" --once
    [[ $status -eq 0 ]]
    assert_contains "scout"
}

@test "Skill with null input — no crash" {
    local d; d="$(make_project "/test/skill-null")"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"2025-01-01T12:00:00.000Z"}\n{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"Skill","id":"tu1","input":null}],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}},"timestamp":"2025-01-01T12:01:00.000Z"}\n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/skill-null" --once
    [[ $status -eq 0 ]]
}

# ─── Tasks ─────────────────────────────────────────────────────────

@test "Task tool — count shown" {
    local d; d="$(make_project "/test/task")"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"2025-01-01T12:00:00.000Z"}\n{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"Task","id":"tu1","input":{"description":"do something"}}],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}},"timestamp":"2025-01-01T12:01:00.000Z"}\n' > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/task" --once
    [[ $status -eq 0 ]]
    assert_contains "Tasks:1"
}

@test "zero tasks — Tasks section omitted" {
    local d; d="$(make_project "/test/no-task")"
    { make_user_entry; make_assistant_entry 100 50 20 30; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-task" --once
    [[ $status -eq 0 ]]
    assert_not_contains "Tasks:"
}

# ─── Compaction ────────────────────────────────────────────────────

@test "compact_boundary — C:1 shown" {
    local d; d="$(make_project "/test/compact")"
    { make_user_entry; make_assistant_entry 100 50 20 30
      printf '{"type":"system","subtype":"compact_boundary","timestamp":"2025-01-01T12:05:00.000Z"}\n'; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/compact" --once
    [[ $status -eq 0 ]]
    assert_contains "C:1"
}

@test "3 compactions — C:3 shown" {
    local d; d="$(make_project "/test/compact3")"
    { make_user_entry; make_assistant_entry 100 50 20 30
      for i in 1 2 3; do printf '{"type":"system","subtype":"compact_boundary","timestamp":"2025-01-01T12:%02d:00.000Z"}\n' "$((i*5))"; done; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/compact3" --once
    [[ $status -eq 0 ]]
    assert_contains "C:3"
}

# ─── Path encoding ─────────────────────────────────────────────────

@test "path with spaces — session found" {
    local d; d="$(make_project "/test/path with spaces")"
    { make_user_entry; make_assistant_entry 100 50 20 30; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/path with spaces" --once
    [[ $status -eq 0 ]]
}

@test "path with dots — session found" {
    local d; d="$(make_project "/Users/paul.s/my.project")"
    { make_user_entry; make_assistant_entry 100 50 20 30; } > "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/Users/paul.s/my.project" --once
    [[ $status -eq 0 ]]
}

@test "duration display: recent timestamp — shows s or m" {
    local d; d="$(make_project "/test/dur")"
    local ts; ts="$(date -u "+%Y-%m-%dT%H:%M:%S.000Z")"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"toolUseResult":null,"timestamp":"%s"}\n' "$ts" > "$d/session-001.jsonl"
    printf '{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-4-6","content":[],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}},"timestamp":"%s"}\n' "$ts" >> "$d/session-001.jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/dur" --once
    [[ $status -eq 0 ]]
    local stripped; stripped="$(strip_ansi "$output")"
    [[ "$stripped" == *"s"* || "$stripped" == *"m"* ]]
}
