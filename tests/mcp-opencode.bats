#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2016,SC2034,SC2317
# Regression tests for the opencode backend in agents/mcp/lib.sh.
#
# opencode has no non-interactive `mcp add` / `mcp remove`, so the sync writes
# the `mcp` object directly into ~/.config/opencode/opencode.json. These tests
# pin: list/current-signature drift detection, idempotent add+remove, env-var
# resolution, and that non-mcp keys (e.g. theme, formatter) are preserved.
#
# OPENCODE_CONFIG points the helpers at a per-test scratch file, so they
# never touch the developer's real config.

load test_helper

setup() {
    setup_test_env
    export OPENCODE_CONFIG="$TEST_HOME/opencode.json"

    # shellcheck source=../claude/lib/sync-common.sh
    source "$REAL_DOTFILES_DIR/claude/lib/sync-common.sh"
    # shellcheck source=../agents/mcp/lib.sh
    source "$REAL_DOTFILES_DIR/agents/mcp/lib.sh"
}

teardown() {
    teardown_test_env
}

@test "mcp_opencode_ensure_config seeds a minimal schema-only file" {
    [[ ! -e "$OPENCODE_CONFIG" ]]
    mcp_opencode_ensure_config
    assert_file_exists "$OPENCODE_CONFIG"
    run jq -r '."$schema"' "$OPENCODE_CONFIG"
    assert_success
    assert_output_contains "opencode.ai/config.json"
}

@test "mcp_opencode_ensure_config leaves an existing file untouched" {
    printf '{"theme":"chocolate-donut","formatter":true}' > "$OPENCODE_CONFIG"
    local before after _
    read -r before _ < <(shasum -a 256 "$OPENCODE_CONFIG")
    mcp_opencode_ensure_config
    read -r after  _ < <(shasum -a 256 "$OPENCODE_CONFIG")
    [[ "$before" == "$after" ]]
}

@test "mcp_opencode_add writes the entry without clobbering sibling keys" {
    printf '{"$schema":"https://opencode.ai/config.json","formatter":true,"theme":"chocolate-donut"}' > "$OPENCODE_CONFIG"
    export HARNESS_DESIRED_JSON='{
      "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
    }'

    run mcp_opencode_add context7
    assert_success

    # Sibling keys preserved.
    run jq -r '.formatter' "$OPENCODE_CONFIG"
    assert_output_contains "true"
    run jq -r '.theme' "$OPENCODE_CONFIG"
    assert_output_contains "chocolate-donut"

    # Entry shape: type=local, command is the full array.
    run jq -r '.mcp.context7.type' "$OPENCODE_CONFIG"
    assert_output_contains "local"
    run jq -c '.mcp.context7.command' "$OPENCODE_CONFIG"
    assert_output_contains '["npx","-y","@upstash/context7-mcp"]'
    run jq -r '.mcp.context7.enabled' "$OPENCODE_CONFIG"
    assert_output_contains "true"
}

@test "mcp_opencode_add resolves \${VAR} env placeholders against live env" {
    export HARNESS_DESIRED_JSON='{
      "tavily": {
        "command": "npx",
        "args": ["-y", "tavily-mcp@latest"],
        "env": {"TAVILY_API_KEY": "${TAVILY_API_KEY}"}
      }
    }'
    export TAVILY_API_KEY="sk-test-rotated"

    run mcp_opencode_add tavily
    assert_success
    run jq -r '.mcp.tavily.environment.TAVILY_API_KEY' "$OPENCODE_CONFIG"
    assert_output_contains "sk-test-rotated"
}

@test "mcp_opencode_add fails loud when a referenced env var is unset" {
    export HARNESS_DESIRED_JSON='{
      "tavily": {
        "command": "npx",
        "args": ["-y", "tavily-mcp@latest"],
        "env": {"TAVILY_API_KEY": "${TAVILY_API_KEY}"}
      }
    }'
    unset TAVILY_API_KEY

    run mcp_opencode_add tavily
    assert_failure
    assert_output_contains "TAVILY_API_KEY"
    # Nothing should have been written.
    [[ ! -e "$OPENCODE_CONFIG" ]] || ! jq -e '.mcp.tavily' "$OPENCODE_CONFIG" >/dev/null
}

@test "mcp_opencode_list_current enumerates configured names sorted" {
    cat > "$OPENCODE_CONFIG" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "tavily":   {"type":"local","command":["npx","-y","tavily-mcp"]},
    "context7": {"type":"local","command":["npx","-y","@upstash/context7-mcp"]}
  }
}
JSON
    run mcp_opencode_list_current
    assert_success
    # sort -u ⇒ context7 before tavily
    [[ "${lines[0]}" == "context7" ]]
    [[ "${lines[1]}" == "tavily"   ]]
}

@test "mcp_opencode_current_signature matches mcp_desired_signature when in sync" {
    cat > "$OPENCODE_CONFIG" <<'JSON'
{"mcp": {"context7": {"type":"local","command":["npx","-y","@upstash/context7-mcp"],"enabled":true}}}
JSON
    export HARNESS_DESIRED_JSON='{
      "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
    }'
    local desired current
    desired=$(mcp_desired_signature           context7 opencode)
    current=$(mcp_opencode_current_signature  context7)
    [[ "$desired" == "$current" ]] || {
        echo "desired=[$desired] current=[$current]" >&2
        return 1
    }
}

@test "mcp_opencode_current_signature flags drift on arg change" {
    cat > "$OPENCODE_CONFIG" <<'JSON'
{"mcp": {"context7": {"type":"local","command":["npx","-y","@upstash/context7-mcp"]}}}
JSON
    export HARNESS_DESIRED_JSON='{
      "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp@2"]}
    }'
    local desired current
    desired=$(mcp_desired_signature           context7 opencode)
    current=$(mcp_opencode_current_signature  context7)
    [[ "$desired" != "$current" ]]
}

@test "mcp_opencode_current_signature flags drift when enabled flipped to false" {
    cat > "$OPENCODE_CONFIG" <<'JSON'
{"mcp": {"context7": {"type":"local","command":["npx","-y","@upstash/context7-mcp"],"enabled":false}}}
JSON
    export HARNESS_DESIRED_JSON='{
      "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
    }'
    local desired current
    desired=$(mcp_desired_signature           context7 opencode)
    current=$(mcp_opencode_current_signature  context7)
    [[ "$desired" != "$current" ]] || {
        echo "expected drift; desired=[$desired] current=[$current]" >&2
        return 1
    }
}

@test "mcp_detect_drift (opencode) returns drifted names with exit 0" {
    cat > "$OPENCODE_CONFIG" <<'JSON'
{"mcp": {
  "context7": {"type":"local","command":["npx","-y","@upstash/context7-mcp"]},
  "tilth":    {"type":"local","command":["tilth","--mcp","--edit"]}
}}
JSON
    export EXISTING=$'context7\ntilth'
    export HARNESS_DESIRED_JSON='{
      "context7": {"command": "npx",   "args": ["-y", "@upstash/context7-mcp@NEW"]},
      "tilth":    {"command": "tilth", "args": ["--mcp", "--edit"]}
    }'

    run mcp_detect_drift opencode
    assert_success
    assert_output_contains "context7"
    assert_output_not_contains "tilth"
}

@test "mcp_opencode_remove deletes only the named entry" {
    cat > "$OPENCODE_CONFIG" <<'JSON'
{
  "theme": "chocolate-donut",
  "mcp": {
    "tavily":   {"type":"local","command":["npx","-y","tavily-mcp"]},
    "context7": {"type":"local","command":["npx","-y","@upstash/context7-mcp"]}
  }
}
JSON

    run mcp_opencode_remove tavily
    assert_success

    run jq -e '.mcp.tavily // empty' "$OPENCODE_CONFIG"
    [[ -z "$output" ]]
    run jq -r '.mcp.context7.type' "$OPENCODE_CONFIG"
    assert_output_contains "local"
    run jq -r '.theme' "$OPENCODE_CONFIG"
    assert_output_contains "chocolate-donut"
}

@test "mcp_opencode_remove on a missing file is a no-op (no crash)" {
    [[ ! -e "$OPENCODE_CONFIG" ]]
    run mcp_opencode_remove never-existed
    assert_success
    [[ ! -e "$OPENCODE_CONFIG" ]]
}

@test "mcp_filter_for_harness defaults to including opencode" {
    local registry; registry=$(cat <<'JSON'
{
  "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]},
  "claude-only": {"command": "foo", "harnesses": ["claude"]}
}
JSON
)
    local filtered; filtered=$(mcp_filter_for_harness opencode "$registry")
    # context7 has no `harnesses` field → included by default.
    run jq -r '.context7.command' <<<"$filtered"
    assert_output_contains "npx"
    # claude-only entry is opted out → excluded.
    run jq -r '."claude-only" // empty' <<<"$filtered"
    [[ -z "$output" ]]
}
