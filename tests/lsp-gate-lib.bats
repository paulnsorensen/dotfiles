#!/usr/bin/env bats
# Tests for lsp_gate_compute — the pure tokei→enabledPlugins helper sourced
# by both _cc_lsp_gate (claude.zsh) and bin/cc-lsp-local.

load test_helper

LSP_PLUGINS=(
    "bash-language-server@claude-code-lsps"
    "vtsls@claude-code-lsps"
    "yaml-language-server@claude-code-lsps"
    "rust-analyzer@claude-code-lsps"
    "pyright@claude-code-lsps"
    "gopls@claude-code-lsps"
)

LSP_GATE_LIB="$REAL_DOTFILES_DIR/claude/lib/lsp-gate.sh"

# Run lsp_gate_compute against a mock tokei that returns the given JSON payload.
# Args: 1=tokei JSON payload, 2=threshold (optional, default 50)
run_with_mock_tokei() {
    local tokei_payload="$1"
    local threshold="${2:-50}"
    local mock_dir="$BATS_TEST_TMPDIR/mock-bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/tokei" <<EOF
#!/bin/bash
cat <<'JSON'
$tokei_payload
JSON
EOF
    chmod +x "$mock_dir/tokei"
    PATH="$mock_dir:$PATH" bash -c "
        source '$LSP_GATE_LIB'
        lsp_gate_compute '$threshold'
    "
}

# ── shape ─────────────────────────────────────────────────────────────────────

@test "lsp-gate.sh has no syntax errors" {
    run bash -n "$LSP_GATE_LIB"
    [[ $status -eq 0 ]]
}

@test "lsp_gate_compute is defined in lsp-gate.sh" {
    grep -q "^lsp_gate_compute()" "$LSP_GATE_LIB"
}

@test "lsp_gate_compute output is valid JSON" {
    local out
    out="$(run_with_mock_tokei '{"Rust":{"code":100}}' 50)"
    [[ -n "$out" ]]
    echo "$out" | jq -e . > /dev/null
}

@test "lsp_gate_compute output contains exactly the 6 LSP plugin keys" {
    local out
    out="$(run_with_mock_tokei '{"Rust":{"code":100}}' 50)"
    local key_count
    key_count="$(echo "$out" | jq 'length')"
    [[ "$key_count" -eq 6 ]]
    local plugin
    for plugin in "${LSP_PLUGINS[@]}"; do
        echo "$out" | jq -e --arg k "$plugin" 'has($k)' > /dev/null
    done
}

@test "lsp_gate_compute values are booleans not strings" {
    local out
    out="$(run_with_mock_tokei '{"Rust":{"code":100}}' 50)"
    local non_bool_count
    non_bool_count="$(echo "$out" | jq '[to_entries[] | select(.value | type != "boolean")] | length')"
    [[ "$non_bool_count" -eq 0 ]]
}

# ── threshold ─────────────────────────────────────────────────────────────────

@test "lsp_gate_compute defaults threshold to 50 when no arg given" {
    local out
    out="$(PATH="$BATS_TEST_TMPDIR/mock-bin:$PATH" bash -c "
        cat > '$BATS_TEST_TMPDIR/mock-bin/tokei' <<'EOF'
#!/bin/bash
echo '{\"Rust\":{\"code\":49}}'
EOF
        chmod +x '$BATS_TEST_TMPDIR/mock-bin/tokei'
        source '$LSP_GATE_LIB'
        lsp_gate_compute
    ")"
    # 49 < 50 → rust-analyzer should be false
    [[ "$(echo "$out" | jq -r '."rust-analyzer@claude-code-lsps"')" == "false" ]]
}

@test "lsp_gate_compute threshold 999999 disables every plugin" {
    local out
    out="$(run_with_mock_tokei '{"Rust":{"code":1000},"Python":{"code":1000},"Go":{"code":1000}}' 999999)"
    local enabled_count
    enabled_count="$(echo "$out" | jq '[to_entries[] | select(.value == true)] | length')"
    [[ "$enabled_count" -eq 0 ]]
}

@test "lsp_gate_compute threshold 1 enables every plugin with any code" {
    local payload='{"Rust":{"code":10},"Python":{"code":10},"Go":{"code":10},"YAML":{"code":10},"BASH":{"code":10},"JavaScript":{"code":10}}'
    local out
    out="$(run_with_mock_tokei "$payload" 1)"
    local enabled_count
    enabled_count="$(echo "$out" | jq '[to_entries[] | select(.value == true)] | length')"
    [[ "$enabled_count" -eq 6 ]]
}

# ── per-plugin language mapping ───────────────────────────────────────────────

@test "rust-analyzer follows Rust line count" {
    local above below
    above="$(run_with_mock_tokei '{"Rust":{"code":100}}' 50)"
    below="$(run_with_mock_tokei '{"Rust":{"code":10}}' 50)"
    [[ "$(echo "$above" | jq -r '."rust-analyzer@claude-code-lsps"')" == "true" ]]
    [[ "$(echo "$below" | jq -r '."rust-analyzer@claude-code-lsps"')" == "false" ]]
}

@test "pyright follows Python line count" {
    local above below
    above="$(run_with_mock_tokei '{"Python":{"code":100}}' 50)"
    below="$(run_with_mock_tokei '{"Python":{"code":10}}' 50)"
    [[ "$(echo "$above" | jq -r '."pyright@claude-code-lsps"')" == "true" ]]
    [[ "$(echo "$below" | jq -r '."pyright@claude-code-lsps"')" == "false" ]]
}

@test "gopls follows Go line count" {
    local above below
    above="$(run_with_mock_tokei '{"Go":{"code":100}}' 50)"
    below="$(run_with_mock_tokei '{"Go":{"code":10}}' 50)"
    [[ "$(echo "$above" | jq -r '."gopls@claude-code-lsps"')" == "true" ]]
    [[ "$(echo "$below" | jq -r '."gopls@claude-code-lsps"')" == "false" ]]
}

@test "yaml-language-server follows YAML line count" {
    local above below
    above="$(run_with_mock_tokei '{"YAML":{"code":100}}' 50)"
    below="$(run_with_mock_tokei '{"YAML":{"code":10}}' 50)"
    [[ "$(echo "$above" | jq -r '."yaml-language-server@claude-code-lsps"')" == "true" ]]
    [[ "$(echo "$below" | jq -r '."yaml-language-server@claude-code-lsps"')" == "false" ]]
}

@test "bash-language-server sums BASH+Shell+Zsh" {
    local out
    # Each individually < 50, but sum = 60 → should enable.
    out="$(run_with_mock_tokei '{"BASH":{"code":20},"Shell":{"code":20},"Zsh":{"code":20}}' 50)"
    [[ "$(echo "$out" | jq -r '."bash-language-server@claude-code-lsps"')" == "true" ]]
}

@test "vtsls sums JS+TS+TSX+JSX" {
    local out
    # Each individually < 50, but sum = 80 → should enable.
    out="$(run_with_mock_tokei '{"JavaScript":{"code":20},"TypeScript":{"code":20},"TSX":{"code":20},"JSX":{"code":20}}' 50)"
    [[ "$(echo "$out" | jq -r '."vtsls@claude-code-lsps"')" == "true" ]]
}

@test "missing language buckets default to 0 and disable the plugin" {
    local out
    out="$(run_with_mock_tokei '{}' 50)"
    local plugin
    for plugin in "${LSP_PLUGINS[@]}"; do
        [[ "$(echo "$out" | jq -r --arg k "$plugin" '.[$k]')" == "false" ]]
    done
}

# ── failure modes ─────────────────────────────────────────────────────────────

@test "lsp_gate_compute returns nonzero when tokei is missing" {
    run bash -c "
        PATH='/usr/bin:/bin'  # no tokei in this PATH
        source '$LSP_GATE_LIB'
        lsp_gate_compute 50
    "
    [[ $status -ne 0 ]]
}
