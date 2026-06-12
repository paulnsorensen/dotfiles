#!/usr/bin/env bats
#
# Tests for the local LLM stack wiring:
#   - chezmoi/lib/install-local-llm.sh  (opencode provider jq-merge)
#   - chezmoi/local-llm/scripts/executable_healthcheck.sh  (decision functions)
#   - chezmoi/local-llm/scripts/executable_install-llama-swap.sh  (pinned binary install)
#   - chezmoi/local-llm/configs/llama-swap.yaml + litellm.yaml  (routing shape)
#   - worker-unit retirement (#288: always-on workers → llama-swap on-demand)
#
# Strategy mirrors skills-external.bats: real jq/yq, fake the external services
# (curl, systemctl, tar) by putting executables earlier on $PATH. The provider
# lib is run as a subprocess; the healthcheck/install functions are sourced
# (both scripts are source-safe — main() only runs on direct execution).

# shellcheck disable=SC1090,SC2016  # $HEALTH = test-resolved source path; JSON fixtures hold literal $schema keys
load test_helper

LIB="$REAL_DOTFILES_DIR/chezmoi/lib/install-local-llm.sh"
HEALTH="$REAL_DOTFILES_DIR/chezmoi/local-llm/scripts/executable_healthcheck.sh"
ALIASES="$REAL_DOTFILES_DIR/chezmoi/local-llm/scripts/executable_aliases.sh"
LEAN="$REAL_DOTFILES_DIR/chezmoi/local-llm/configs/lean.json"
SWAP_YAML="$REAL_DOTFILES_DIR/chezmoi/local-llm/configs/llama-swap.yaml"
SWAP_SVC="$REAL_DOTFILES_DIR/chezmoi/dot_config/systemd/user/llama-swap.service"
INSTALL_SWAP="$REAL_DOTFILES_DIR/chezmoi/local-llm/scripts/executable_install-llama-swap.sh"
LITELLM="$REAL_DOTFILES_DIR/chezmoi/local-llm/configs/litellm.yaml"
UNITS_DIR="$REAL_DOTFILES_DIR/chezmoi/dot_config/systemd/user"

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"

    # Fake curl: distinguishes the /v1/models probe from a chat completion.
    #   FAKE_PORT=up|down           — controls the /v1/models probe
    #   FAKE_MODELS="a b c"         — model ids the /v1/models body lists
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
    [[ "${FAKE_PORT:-up}" == "up" ]] || exit 7
    if [[ -n "${FAKE_MODELS:-}" ]]; then
        printf '{"data":['
        first=true
        for m in $FAKE_MODELS; do
            $first || printf ','
            printf '{"id":"%s"}' "$m"
            first=false
        done
        printf ']}'
    fi
    exit 0
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
    export FAKE_ACTIVE="litellm llama-swap"
    run llm_unit_active litellm
    assert_success
    run llm_unit_active worker-npu
    assert_failure
}

@test "llm_port_up follows the /v1/models probe" {
    source "$HEALTH"
    FAKE_PORT=up run llm_port_up 4000
    assert_success
    FAKE_PORT=down run llm_port_up 9000
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

@test "llm_model_registered checks llama-swap's /v1/models listing" {
    source "$HEALTH"
    FAKE_MODELS="local-haiku local-sonnet" run llm_model_registered local-sonnet
    assert_success
    FAKE_MODELS="local-haiku" run llm_model_registered local-sonnet
    assert_failure
}

@test "llm_quick_check fails when a hard unit is down" {
    source "$HEALTH"
    # litellm active, llama-swap missing, proxy up.
    FAKE_ACTIVE="litellm" FAKE_PORT=up run llm_quick_check
    assert_failure
    assert_output_contains "llama-swap inactive"
}

@test "llm_quick_check passes when all hard units active and proxy up" {
    source "$HEALTH"
    FAKE_ACTIVE="litellm llama-swap" FAKE_PORT=up run llm_quick_check
    assert_success
}

@test "llm_quick_check treats a fully-stopped stack as idle, not a failure" {
    source "$HEALTH"
    # No units active: the stack is cleanly stopped. `dots doctor` must NOT
    # count this as an issue, else it cries wolf on every flag-on machine
    # that hasn't run llm-up.
    FAKE_ACTIVE="" run llm_quick_check
    assert_success
    assert_output_contains "not running"
}

# ─── llama-swap config (#288) ──────────────────────────────────────────────────

@test "llama-swap.yaml: valid YAML with grounded global settings" {
    assert_file_exists "$SWAP_YAML"
    run yq -e '.healthCheckTimeout == 360' "$SWAP_YAML"
    assert_success
    run yq -e '.globalTTL == 600' "$SWAP_YAML"
    assert_success
}

@test "llama-swap.yaml: hot group pins local-haiku resident (swap/exclusive false, persistent true)" {
    run yq -e '.groups.hot.swap == false' "$SWAP_YAML"
    assert_success
    run yq -e '.groups.hot.exclusive == false' "$SWAP_YAML"
    assert_success
    run yq -e '.groups.hot.persistent == true' "$SWAP_YAML"
    assert_success
    # #288 ships local-haiku only; local-embed joins in #289 with its model download.
    run yq -r '.groups.hot.members | join(" ")' "$SWAP_YAML"
    assert_output_contains "local-haiku"
    run yq -e '.groups.hot.members | length == 1' "$SWAP_YAML"
    assert_success
}

@test "llama-swap.yaml: swap pool holds sonnet/coder/vision one-at-a-time" {
    run yq -r '.groups.pool.members | join(" ")' "$SWAP_YAML"
    assert_output_contains "local-sonnet"
    assert_output_contains "local-coder"
    assert_output_contains "local-vision"
    run yq -e '.groups.pool.swap == true' "$SWAP_YAML"
    assert_success
    run yq -e '.groups.pool.exclusive == true' "$SWAP_YAML"
    assert_success
}

@test "llama-swap.yaml: every group member has a model entry with a \${PORT} cmd" {
    local members m
    members=$(yq -r '.groups[].members[]' "$SWAP_YAML")
    [ -n "$members" ]
    for m in $members; do
        run yq -r ".models[\"$m\"].cmd" "$SWAP_YAML"
        assert_success
        assert_output_contains '--port ${PORT}'
    done
}

@test "llama-swap.yaml: no systemd %h specifier (llama-swap runs cmd without systemd expansion)" {
    run grep -F '%h' "$SWAP_YAML"
    assert_failure
}

@test "llama-swap.yaml: hot haiku never unloads, coder gets its longer ttl" {
    run yq -e '.models["local-haiku"].ttl == 0' "$SWAP_YAML"
    assert_success
    run yq -e '.models["local-coder"].ttl == 900' "$SWAP_YAML"
    assert_success
}

@test "llama-swap.service: #287 hardening pattern + single listen port" {
    assert_file_exists "$SWAP_SVC"
    grep -q 'StartLimitBurst=3' "$SWAP_SVC"
    grep -q 'StartLimitIntervalSec=120' "$SWAP_SVC"
    grep -q 'RestartSec=30' "$SWAP_SVC"
    grep -q 'MemoryMax=30G' "$SWAP_SVC"
    grep -q 'OOMScoreAdjust=1000' "$SWAP_SVC"
    grep -q -- '--listen 127.0.0.1:9000' "$SWAP_SVC"
    grep -q -- '--config %h/local-llm/configs/llama-swap.yaml' "$SWAP_SVC"
}

# ─── LiteLLM rewire (#288) ─────────────────────────────────────────────────────

@test "litellm.yaml: llama-swap-served models point at the single :9000 port" {
    local m
    for m in local-sonnet local-haiku local-coder local-vision; do
        run yq -r ".model_list[] | select(.model_name == \"$m\") | .litellm_params.api_base" "$LITELLM"
        assert_output_contains "http://127.0.0.1:9000/v1"
    done
}

@test "litellm.yaml: non-llama-swap tiers keep their own ports (npu :8000, opus :8090)" {
    run yq -r '.model_list[] | select(.model_name == "local-classifier") | .litellm_params.api_base' "$LITELLM"
    assert_output_contains "http://127.0.0.1:8000/v1"
    run yq -r '.model_list[] | select(.model_name == "local-opus") | .litellm_params.api_base' "$LITELLM"
    assert_output_contains "http://127.0.0.1:8090/v1"
}

@test "litellm.yaml: no api_base still points at a retired per-worker port" {
    run grep -E ':(8080|8081|8085|8082)/' "$LITELLM"
    assert_failure
}

@test "litellm.yaml: swap-pool models carry cold-load timeouts" {
    local m
    for m in local-sonnet local-coder local-vision; do
        run yq -e ".model_list[] | select(.model_name == \"$m\") | .litellm_params.timeout == 300" "$LITELLM"
        assert_success
    done
}

@test "litellm.yaml: stale coder fallback dropped, classifier fallback kept" {
    # coder→sonnet assumed manual mutual exclusion; llama-swap loads coder on demand.
    run yq -e '.router_settings.fallbacks[] | select(has("local-coder"))' "$LITELLM"
    assert_failure
    run yq -r '.router_settings.fallbacks[] | select(has("local-classifier")) | .["local-classifier"][0]' "$LITELLM"
    assert_output_contains "local-haiku"
}

# ─── worker-unit retirement (#288) ─────────────────────────────────────────────

@test "retired worker unit sources are gone; npu + opus + llama-swap remain" {
    local u
    for u in worker-igpu worker-cpu worker-coder worker-vision; do
        [[ ! -e "$UNITS_DIR/$u.service" ]]
    done
    assert_file_exists "$UNITS_DIR/worker-npu.service"
    assert_file_exists "$UNITS_DIR/worker-opus.service"
    assert_file_exists "$UNITS_DIR/llama-swap.service"
}

@test ".chezmoiremove deletes the deployed retired units" {
    local remove="$REAL_DOTFILES_DIR/chezmoi/.chezmoiremove"
    assert_file_exists "$remove"
    local u
    for u in worker-igpu worker-cpu worker-coder worker-vision; do
        grep -q ".config/systemd/user/$u.service" "$remove"
    done
}

@test ".chezmoiignore gates llama-swap.service and drops retired unit entries" {
    local ignore="$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    grep -q '.config/systemd/user/llama-swap.service' "$ignore"
    run grep -E 'worker-(igpu|cpu|coder|vision)' "$ignore"
    assert_failure
}

@test "local-llm.target wants llama-swap + litellm, not retired workers" {
    local target="$UNITS_DIR/local-llm.target"
    grep -q 'Wants=llama-swap.service litellm.service' "$target"
    run grep -E 'worker-(igpu|cpu)' "$target"
    assert_failure
}

@test "worker-opus mutual exclusion targets llama-swap, not the retired units" {
    grep -q 'Conflicts=llama-swap.service' "$UNITS_DIR/worker-opus.service"
    run grep -E 'worker-(igpu|coder)' "$UNITS_DIR/worker-opus.service"
    assert_failure
}
@test "run_onchange disables and masks the retired units so a stale copy can't restart" {
    local t="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_install-local-llm.sh.tmpl"
    grep -q 'mask' "$t"
    local u
    for u in worker-igpu worker-cpu worker-coder worker-vision; do
        grep -q "$u" "$t"
    done
}

@test "aliases.sh references no retired worker units and pings the llama-swap port" {
    run grep -E 'worker-(igpu|cpu|coder|vision)' "$ALIASES"
    assert_failure
    grep -q '9000' "$ALIASES"
    # retired per-worker ports must not linger in llm-ping
    run grep -E '8080|8081|8085|8082' "$ALIASES"
    assert_failure
}

# ─── install-llama-swap.sh (pinned binary install) ─────────────────────────────

@test "llama_swap_asset maps machine arch to the release asset" {
    source "$INSTALL_SWAP"
    run llama_swap_asset x86_64
    assert_success
    assert_output_contains "linux_amd64.tar.gz"
    run llama_swap_asset aarch64
    assert_success
    assert_output_contains "linux_arm64.tar.gz"
    run llama_swap_asset riscv64
    assert_failure
}

@test "install-llama-swap downloads the pinned release, installs binary, stamps version" {
    cat > "$MOCK_BIN/curl" << 'MOCK'
#!/bin/bash
out=""; url=""
while (($#)); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
echo "$url" > "${CURL_URL_LOG:?}"
touch "$out"
MOCK
    chmod +x "$MOCK_BIN/curl"
    cat > "$MOCK_BIN/tar" << 'MOCK'
#!/bin/bash
dir=""
while (($#)); do
    case "$1" in
        -C) dir="$2"; shift 2 ;;
        *) shift ;;
    esac
done
echo fake-binary > "$dir/llama-swap"
MOCK
    chmod +x "$MOCK_BIN/tar"

    export CURL_URL_LOG="$TEST_HOME/url.log"
    export LLAMA_SWAP_BIN_DIR="$TEST_HOME/local-llm/bin"
    run bash "$INSTALL_SWAP"
    assert_success
    assert_file_exists "$LLAMA_SWAP_BIN_DIR/llama-swap"
    [[ -x "$LLAMA_SWAP_BIN_DIR/llama-swap" ]]

    # Stamp matches the pin; URL hits the pinned GitHub release.
    source "$INSTALL_SWAP"
    run cat "$LLAMA_SWAP_BIN_DIR/llama-swap.version"
    assert_output_contains "$LLAMA_SWAP_VERSION"
    run cat "$CURL_URL_LOG"
    assert_output_contains "github.com/mostlygeek/llama-swap/releases/download/v${LLAMA_SWAP_VERSION}/"
}

@test "install-llama-swap skips the download when the pinned version is already installed" {
    source "$INSTALL_SWAP"
    export LLAMA_SWAP_BIN_DIR="$TEST_HOME/local-llm/bin"
    mkdir -p "$LLAMA_SWAP_BIN_DIR"
    echo bin > "$LLAMA_SWAP_BIN_DIR/llama-swap"
    chmod +x "$LLAMA_SWAP_BIN_DIR/llama-swap"
    echo "$LLAMA_SWAP_VERSION" > "$LLAMA_SWAP_BIN_DIR/llama-swap.version"

    # Poison curl: any download attempt fails loudly.
    cat > "$MOCK_BIN/curl" << 'MOCK'
#!/bin/bash
exit 99
MOCK
    chmod +x "$MOCK_BIN/curl"

    run install_llama_swap
    assert_success
    assert_output_contains "already installed"
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
