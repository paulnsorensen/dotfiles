#!/usr/bin/env bats
#
# Tests for the local LLM stack wiring:
#   - chezmoi/lib/install-local-llm.sh  (opencode provider jq-merge)
#   - chezmoi/local-llm/scripts/executable_healthcheck.sh  (decision functions)
#
# Strategy mirrors skills-external.bats: real jq, fake the external services
# (curl, systemctl) by putting executables earlier on $PATH. The provider lib is
# run as a subprocess; the healthcheck functions are sourced (the script is
# source-safe — main() only runs on direct execution) and called via `run`.

# shellcheck disable=SC1090,SC2016  # $HEALTH = test-resolved source path; JSON fixtures hold literal $schema keys
load test_helper

LIB="$REAL_DOTFILES_DIR/chezmoi/lib/install-local-llm.sh"
HEALTH="$REAL_DOTFILES_DIR/chezmoi/local-llm/scripts/executable_healthcheck.sh"
ALIASES="$REAL_DOTFILES_DIR/chezmoi/local-llm/scripts/executable_aliases.sh"
LEAN="$REAL_DOTFILES_DIR/chezmoi/local-llm/configs/lean.json"

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"

    # Fake curl: distinguishes the /v1/models probe from a chat completion.
    #   FAKE_PORT=up|down           — controls the /v1/models probe
    #   FAKE_COMPLETION=ok|empty|fail — controls the chat completion
    #   FAKE_SERVED=<model>         — the `.model` the proxy "answered" with
    cat > "$MOCK_BIN/curl" << 'MOCK'
#!/bin/bash
args="$*"
if [[ "$args" == *chat/completions* ]]; then
    case "${FAKE_COMPLETION:-ok}" in
        fail)  exit 22 ;;
        empty) printf '{"model":"%s","choices":[{"message":{"content":""}}]}' "${FAKE_SERVED:-local-haiku}"; exit 0 ;;
        *)     printf '{"model":"%s","choices":[{"message":{"content":"OK"}}]}' "${FAKE_SERVED:-local-haiku}"; exit 0 ;;
    esac
elif [[ "$args" == */v1/models* ]]; then
    [[ "${FAKE_PORT:-up}" == "up" ]] && exit 0 || exit 7
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/curl"

    # Fake systemctl: FAKE_ACTIVE is a space-separated list of active units.
    cat > "$MOCK_BIN/systemctl" << 'MOCK'
#!/bin/bash
unit="${!#}"   # last positional arg
[[ " ${FAKE_ACTIVE:-} " == *" $unit "* ]] && exit 0 || exit 3
MOCK
    chmod +x "$MOCK_BIN/systemctl"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    teardown_test_env
}

# ─── provider lib ───────────────────────────────────────────────────────────

@test "provider lib adds local-llm with 6 models and preserves existing .mcp" {
    local cfg="$TEST_HOME/opencode.json"
    echo '{"$schema":"x","formatter":true,"mcp":{"tilth":{"type":"local"}}}' > "$cfg"

    run bash "$LIB" "$cfg"
    assert_success

    run jq -r '.provider["local-llm"].models | keys | length' "$cfg"
    assert_output_contains "6"

    run jq -r '.provider["local-llm"].options.baseURL' "$cfg"
    assert_output_contains "http://127.0.0.1:4000/v1"

    run jq -r '.provider["local-llm"].options.apiKey' "$cfg"
    assert_output_contains "sk-local"

    run jq -r '.provider["local-llm"].npm' "$cfg"
    assert_output_contains "@ai-sdk/openai-compatible"

    # The pre-existing MCP block must survive untouched.
    run jq -e '.mcp.tilth.type' "$cfg"
    assert_success
    assert_output_contains "local"
}

@test "provider lib is idempotent (re-run is byte-identical)" {
    local cfg="$TEST_HOME/opencode.json"
    echo '{"mcp":{}}' > "$cfg"
    bash "$LIB" "$cfg"
    cp "$cfg" "$cfg.first"
    bash "$LIB" "$cfg"
    run diff "$cfg.first" "$cfg"
    assert_success
}

@test "provider lib scaffolds opencode.json when the file is absent" {
    local cfg="$TEST_HOME/nested/opencode.json"
    run bash "$LIB" "$cfg"
    assert_success
    assert_file_exists "$cfg"
    run jq -r '.provider["local-llm"].models["local-coder"].name' "$cfg"
    assert_output_contains "Coder"
}

@test "provider lib honours LOCAL_LLM_BASE_URL override" {
    local cfg="$TEST_HOME/opencode.json"
    echo '{}' > "$cfg"
    LOCAL_LLM_BASE_URL="http://127.0.0.1:9999/v1" run bash "$LIB" "$cfg"
    assert_success
    run jq -r '.provider["local-llm"].options.baseURL' "$cfg"
    assert_output_contains "http://127.0.0.1:9999/v1"
}

# ─── healthcheck decision functions ───────────────────────────────────────────

@test "llm_unit_active reflects systemctl is-active" {
    source "$HEALTH"
    export FAKE_ACTIVE="litellm worker-igpu"
    run llm_unit_active litellm
    assert_success
    run llm_unit_active worker-vision
    assert_failure
}

@test "llm_port_up follows the /v1/models probe" {
    source "$HEALTH"
    FAKE_PORT=up run llm_port_up 4000
    assert_success
    FAKE_PORT=down run llm_port_up 8090
    assert_failure
}

@test "llm_completion_ok true on non-empty content, false otherwise" {
    source "$HEALTH"
    FAKE_COMPLETION=ok run llm_completion_ok local-haiku
    assert_success
    FAKE_COMPLETION=empty run llm_completion_ok local-haiku
    assert_failure
    FAKE_COMPLETION=fail run llm_completion_ok local-haiku
    assert_failure
}

@test "llm_served_model reports the model the proxy actually answered with" {
    source "$HEALTH"
    # Ask for opus but the proxy falls back to sonnet — served-as must reflect that.
    FAKE_SERVED=local-sonnet run llm_served_model local-opus
    assert_success
    assert_output_contains "local-sonnet"
}

@test "llm_quick_check fails when a hard unit is down" {
    source "$HEALTH"
    # litellm + worker-cpu active, worker-igpu missing, proxy up.
    FAKE_ACTIVE="litellm worker-cpu" FAKE_PORT=up run llm_quick_check
    assert_failure
    assert_output_contains "worker-igpu inactive"
}

@test "llm_quick_check passes when all hard units active and proxy up" {
    source "$HEALTH"
    FAKE_ACTIVE="litellm worker-igpu worker-cpu" FAKE_PORT=up run llm_quick_check
    assert_success
}

@test "llm_quick_check treats a fully-stopped stack as idle, not a failure" {
    source "$HEALTH"
    # No units active: the stack is cleanly stopped (workers are never
    # auto-started). `dots doctor` must NOT count this as an issue, else it
    # cries wolf on every flag-on machine that hasn't run llm-up.
    FAKE_ACTIVE="" run llm_quick_check
    assert_success
    assert_output_contains "not running"
}

# ─── lean opencode overlay (fits the 32k local-coder window) ──────────────────
#
# OPENCODE_CONFIG mergeDeeps onto the global config — it does NOT replace it — so
# the overlay is just the `enabled: false` lines for the heavy non-coding MCP
# servers. Disabling a server is the ONLY lever that stops schema injection;
# per-agent `tools:{x:false}` gates execution but still ships the schema tokens.

@test "lean.json is valid JSON and disables exactly the heavy MCP servers" {
    run jq -e . "$LEAN"
    assert_success

    for server in code-review-graph hallouminate tavily; do
        run jq -e --arg s "$server" '.mcp[$s].enabled == false' "$LEAN"
        assert_success
    done

    # Exclusivity: exactly those three — no accidental extra disable slips in.
    run jq -e '.mcp | keys | length == 3' "$LEAN"
    assert_success
}

@test "lean.json leaves the coding MCP servers untouched (absent = stays enabled)" {
    # mergeDeep semantics: only the keys the overlay names change. tilth, serena,
    # and context7 must NOT appear, or the overlay would strip the coder's own
    # tools out of the window it is meant to protect.
    for server in tilth serena context7; do
        run jq -r --arg s "$server" '.mcp | has($s)' "$LEAN"
        assert_output_contains "false"
    done
}

@test "every server lean.json disables is a real opencode-loaded MCP (catches registry rename drift)" {
    # The overlay only saves tokens if its keys match opencode's actual MCP server
    # names. A rename in agents/mcp/registry.yaml that isn't mirrored here makes the
    # overlay a silent no-op: the 32k window blows out with no error. Tie the
    # disabled keys to the registry source of truth so that drift fails loudly.
    local registry="$REAL_DOTFILES_DIR/agents/mcp/registry.yaml"

    # Servers the registry renders into opencode: harnesses absent (default = all
    # harnesses) or explicitly listing opencode. `// ["opencode"]` substitutes the
    # default only when the field is null/absent; an explicit `[]` (e.g. todoist)
    # stays empty and is correctly excluded.
    local opencode_servers
    opencode_servers=$(yq -r \
      '.mcps | to_entries | map(select((.value.harnesses // ["opencode"]) | contains(["opencode"]))) | .[].key' \
      "$registry")

    local disabled
    disabled=$(jq -r '.mcp | keys | .[]' "$LEAN")
    [ -n "$disabled" ]

    local s
    for s in $disabled; do
        echo "$opencode_servers" | grep -qx "$s" || {
            echo "lean.json disables '$s' — not an opencode-loaded MCP in registry.yaml"
            return 1
        }
    done
}

@test "opencode-lean points OPENCODE_CONFIG at the deployed lean.json and forwards args" {
    cat > "$MOCK_BIN/opencode" << 'MOCK'
#!/bin/bash
echo "CONFIG=$OPENCODE_CONFIG"
echo "ARGS=$*"
MOCK
    chmod +x "$MOCK_BIN/opencode"

    # shellcheck disable=SC1090
    source "$ALIASES"
    run opencode-lean --model local-coder
    assert_success
    assert_output_contains "CONFIG=$HOME/local-llm/configs/lean.json"
    assert_output_contains "ARGS=--model local-coder"
}
