#!/usr/bin/env bats
#
# Regression tests for agents/mcp/lib.sh.
#
# Strategy: source sync-common.sh + lib.sh, populate HARNESS_DESIRED_JSON
# and EXISTING by hand, mock `claude` / `codex` on PATH, then call the
# helpers directly.
#
# Pins the bug where every-MCP-in-sync made `mcp_detect_drift` exit 1:
# the trailing `[[ ... ]] && echo` short-circuited to 1 on no-drift, the
# while loop adopted that as its exit code, the function returned 1, and
# sync.sh's `to_update=$(mcp_detect_drift ...)` bare assignment tripped
# `set -e`. chezmoi surfaced the symptom as
#   "chezmoi: .chezmoiscripts/install-mcp.sh: exit status 1".

load test_helper

setup() {
    setup_test_env

    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"

    # shellcheck source=../claude/lib/sync-common.sh
    source "$REAL_DOTFILES_DIR/claude/lib/sync-common.sh"
    # shellcheck source=../agents/mcp/lib.sh
    source "$REAL_DOTFILES_DIR/agents/mcp/lib.sh"
}

teardown() {
    teardown_test_env
}

# Stub `claude mcp get NAME` to print the contents of CLAUDE_STUB_<NAME>.
write_claude_stub() {
    cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
if [[ "$1" == mcp && "$2" == get ]]; then
    var="CLAUDE_STUB_$3"
    printf '%s' "${!var:-}"
    exit 0
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/claude"
}

# Stub `codex mcp list --json` to print $CODEX_STUB_JSON.
write_codex_stub() {
    cat > "$MOCK_BIN/codex" << 'MOCK'
#!/bin/bash
if [[ "$1" == mcp && "$2" == list ]]; then
    printf '%s' "${CODEX_STUB_JSON:-[]}"
    exit 0
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/codex"
}

@test "mcp_detect_drift (claude): all-in-sync returns 0 with no output (regression: was exit 1)" {
    write_claude_stub

    export EXISTING=$'foo\nbar'
    export HARNESS_DESIRED_JSON='{
      "foo": {"command": "npx", "args": ["-y", "foo-mcp"]},
      "bar": {"command": "npx", "args": ["-y", "bar-mcp"]}
    }'
    export CLAUDE_STUB_foo='foo:
  Command: npx
  Args: -y foo-mcp
  Environment:'
    export CLAUDE_STUB_bar='bar:
  Command: npx
  Args: -y bar-mcp
  Environment:'

    run mcp_detect_drift claude
    assert_success
    [[ -z "$output" ]] || { echo "expected empty output, got: [$output]" >&2; return 1; }
}

@test "mcp_detect_drift (claude): drifted entry is emitted, function still returns 0" {
    write_claude_stub

    export EXISTING=$'foo\nbar'
    export HARNESS_DESIRED_JSON='{
      "foo": {"command": "npx", "args": ["-y", "foo-mcp-NEW"]},
      "bar": {"command": "npx", "args": ["-y", "bar-mcp"]}
    }'
    export CLAUDE_STUB_foo='foo:
  Command: npx
  Args: -y foo-mcp
  Environment:'
    export CLAUDE_STUB_bar='bar:
  Command: npx
  Args: -y bar-mcp
  Environment:'

    run mcp_detect_drift claude
    assert_success
    assert_output_contains "foo"
    assert_output_not_contains "bar"
}

@test "mcp_detect_drift: empty EXISTING returns 0 with no output" {
    export EXISTING=""
    export HARNESS_DESIRED_JSON='{}'

    run mcp_detect_drift claude
    assert_success
    [[ -z "$output" ]] || { echo "expected empty output, got: [$output]" >&2; return 1; }
}

@test "mcp_detect_drift (codex): all-in-sync returns 0 with no output" {
    write_codex_stub

    export EXISTING=$'foo\nbar'
    export HARNESS_DESIRED_JSON='{
      "foo": {"command": "npx", "args": ["-y", "foo-mcp"]},
      "bar": {"command": "npx", "args": ["-y", "bar-mcp"]}
    }'
    export CODEX_STUB_JSON='[
      {"name": "foo", "transport": {"command": "npx", "args": ["-y", "foo-mcp"], "env": {}}},
      {"name": "bar", "transport": {"command": "npx", "args": ["-y", "bar-mcp"], "env": {}}}
    ]'

    run mcp_detect_drift codex
    assert_success
    [[ -z "$output" ]] || { echo "expected empty output, got: [$output]" >&2; return 1; }
}

# End-to-end: registry `args` strings are rendered through `chezmoi
# execute-template` per harness, so the same entry can produce different
# argv for Claude vs Codex (used by Serena's --context=claude-code|codex).
@test "sync.sh --dry-run: per-harness templating swaps args based on HARNESS env" {
    write_claude_stub
    write_codex_stub

    cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
if [[ "$1" == mcp && "$2" == list ]]; then exit 0; fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/claude"
    export CODEX_STUB_JSON='[]'

    local fake_dotfiles="$TEST_HOME/fake-dotfiles"
    mkdir -p "$fake_dotfiles/agents/mcp" "$fake_dotfiles/claude/lib"
    cp "$REAL_DOTFILES_DIR/agents/mcp/sync.sh" "$fake_dotfiles/agents/mcp/sync.sh"
    cp "$REAL_DOTFILES_DIR/agents/mcp/lib.sh"  "$fake_dotfiles/agents/mcp/lib.sh"
    cp "$REAL_DOTFILES_DIR/claude/lib/sync-common.sh" "$fake_dotfiles/claude/lib/sync-common.sh"
    cat > "$fake_dotfiles/agents/mcp/registry.yaml" << 'YAML'
mcps:
  picky:
    command: picky
    args:
      - --mode={{ if eq (env "HARNESS") "claude" }}claude-mode{{ else }}codex-mode{{ end }}
    scope: user
    description: per-harness templating fixture
YAML

    run bash "$fake_dotfiles/agents/mcp/sync.sh" --dry-run
    assert_success
    assert_output_contains "picky --mode=claude-mode"
    assert_output_contains "picky --mode=codex-mode"
}

# End-to-end: the exact failure mode chezmoi reported. Drives sync.sh in
# dry-run with both harnesses in sync — pre-fix this hit exit 1 silently,
# now it must print "Sync complete!" and exit 0.
@test "sync.sh --dry-run: all-in-sync exits 0 (regression: chezmoi install-mcp.sh exit 1)" {
    write_claude_stub
    write_codex_stub

    export CLAUDE_STUB_foo='foo:
  Command: npx
  Args: -y foo-mcp
  Environment:'
    export CODEX_STUB_JSON='[
      {"name": "foo", "transport": {"command": "npx", "args": ["-y", "foo-mcp"], "env": {}}}
    ]'

    # `claude mcp list` (used by mcp_claude_list_current) needs to enumerate
    # configured names. Override the stub to handle both `get` and `list`.
    cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
if [[ "$1" == mcp && "$2" == list ]]; then
    echo "foo: npx -y foo-mcp"
    exit 0
fi
if [[ "$1" == mcp && "$2" == get ]]; then
    var="CLAUDE_STUB_$3"
    printf '%s' "${!var:-}"
    exit 0
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/claude"

    # Stand up a minimal registry the script can read.
    local fake_dotfiles="$TEST_HOME/fake-dotfiles"
    mkdir -p "$fake_dotfiles/agents/mcp" "$fake_dotfiles/claude/lib"
    cp "$REAL_DOTFILES_DIR/agents/mcp/sync.sh" "$fake_dotfiles/agents/mcp/sync.sh"
    cp "$REAL_DOTFILES_DIR/agents/mcp/lib.sh"  "$fake_dotfiles/agents/mcp/lib.sh"
    cp "$REAL_DOTFILES_DIR/claude/lib/sync-common.sh" "$fake_dotfiles/claude/lib/sync-common.sh"
    cat > "$fake_dotfiles/agents/mcp/registry.yaml" << 'YAML'
mcps:
  foo:
    command: npx
    args: ["-y", "foo-mcp"]
    description: test
    scope: user
    harnesses: [claude, codex]
YAML

    run bash "$fake_dotfiles/agents/mcp/sync.sh" --dry-run
    assert_success
    assert_output_contains "Sync complete!"
}
