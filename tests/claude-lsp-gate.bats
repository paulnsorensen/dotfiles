#!/usr/bin/env bats
# Tests for _cc_lsp_gate and the language-aware LSP plugin gate in cc/ccp

load test_helper

LSP_PLUGINS=(
    "bash-language-server@claude-code-lsps"
    "vtsls@claude-code-lsps"
    "yaml-language-server@claude-code-lsps"
    "rust-analyzer@claude-code-lsps"
    "pyright@claude-code-lsps"
    "gopls@claude-code-lsps"
)

# Run a zsh snippet with claude.zsh sourced. Errors from compdef are suppressed.
zsh_run() {
    local snippet="$1"
    DOTFILES_DIR="$DOTFILES_DIR" zsh -c "
source '$REAL_DOTFILES_DIR/zsh/claude.zsh' 2>/dev/null || true
$snippet
"
}

setup() {
    setup_test_env

    # Minimal git repo with a shell script (triggers bash-language-server)
    GATE_REPO="$TEST_HOME/gate-repo"
    mkdir -p "$GATE_REPO"
    git -C "$GATE_REPO" init -q
    git -C "$GATE_REPO" config user.email "test@test.com"
    git -C "$GATE_REPO" config user.name "Test"
    printf '#!/bin/bash\necho hello\n' > "$GATE_REPO/run.sh"
    git -C "$GATE_REPO" add .
    git -C "$GATE_REPO" commit -q -m "init"

    # Mock claude binary that prints its args one-per-line
    MOCK_BIN="$TEST_HOME/mock-bin"
    mkdir -p "$MOCK_BIN"
    printf '#!/bin/bash\nprintf "%%s\\n" "$@"\n' > "$MOCK_BIN/claude"
    chmod +x "$MOCK_BIN/claude"
}

teardown() {
    teardown_test_env
}

# ── syntax ────────────────────────────────────────────────────────────────────

@test "claude.zsh has no syntax errors" {
    run zsh -n "$REAL_DOTFILES_DIR/zsh/claude.zsh"
    [[ $status -eq 0 ]]
}

@test "_cc_lsp_gate is defined in claude.zsh" {
    grep -q "^_cc_lsp_gate()" "$REAL_DOTFILES_DIR/zsh/claude.zsh"
}

@test "cc is a function, not an alias" {
    grep -q "^cc()" "$REAL_DOTFILES_DIR/zsh/claude.zsh"
    ! grep -qE "^alias cc=" "$REAL_DOTFILES_DIR/zsh/claude.zsh"
}

@test "ccc is a function, not an alias" {
    grep -q "^ccc()" "$REAL_DOTFILES_DIR/zsh/claude.zsh"
    ! grep -qE "^alias ccc=" "$REAL_DOTFILES_DIR/zsh/claude.zsh"
}

@test "ccr is a function, not an alias" {
    grep -q "^ccr()" "$REAL_DOTFILES_DIR/zsh/claude.zsh"
    ! grep -qE "^alias ccr=" "$REAL_DOTFILES_DIR/zsh/claude.zsh"
}

# ── gate helper ───────────────────────────────────────────────────────────────

@test "_cc_lsp_gate prints nothing outside a git repo" {
    run zsh_run "cd /tmp && _cc_lsp_gate"
    [[ $status -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_cc_lsp_gate prints a file path inside a git repo" {
    run zsh_run "cd '$GATE_REPO' && _cc_lsp_gate"
    [[ $status -eq 0 ]]
    [[ -n "$output" ]]
    [[ -f "$output" ]]
}

@test "_cc_lsp_gate output is valid JSON" {
    local gate_file
    gate_file="$(zsh_run "cd '$REAL_DOTFILES_DIR' && _cc_lsp_gate")"
    [[ -n "$gate_file" ]]
    jq -e . "$gate_file" > /dev/null
}

@test "_cc_lsp_gate output contains exactly the 6 LSP plugin keys" {
    local gate_file
    gate_file="$(zsh_run "cd '$REAL_DOTFILES_DIR' && _cc_lsp_gate")"
    [[ -n "$gate_file" ]]

    local key_count
    key_count="$(jq '.enabledPlugins | length' "$gate_file")"
    [[ "$key_count" -eq 6 ]]

    local plugin
    for plugin in "${LSP_PLUGINS[@]}"; do
        jq -e --arg k "$plugin" '.enabledPlugins | has($k)' "$gate_file" > /dev/null
    done
}

@test "_cc_lsp_gate values are booleans not strings" {
    local gate_file
    gate_file="$(zsh_run "cd '$REAL_DOTFILES_DIR' && _cc_lsp_gate")"
    [[ -n "$gate_file" ]]

    local non_bool_count
    non_bool_count="$(jq '[.enabledPlugins | to_entries[] | select(.value | type != "boolean")] | length' "$gate_file")"
    [[ "$non_bool_count" -eq 0 ]]
}

@test "_cc_lsp_gate threshold 999999 disables all LSPs" {
    local gate_file
    gate_file="$(CC_LSP_GATE_THRESHOLD=999999 zsh_run "
export CC_LSP_GATE_THRESHOLD=999999
cd '$REAL_DOTFILES_DIR'
_cc_lsp_gate")"
    [[ -n "$gate_file" ]]

    local enabled_count
    enabled_count="$(jq '[.enabledPlugins | to_entries[] | select(.value == true)] | length' "$gate_file")"
    [[ "$enabled_count" -eq 0 ]]
}

@test "_cc_lsp_gate threshold 1 enables at least one LSP in this repo" {
    local gate_file
    gate_file="$(CC_LSP_GATE_THRESHOLD=1 zsh_run "
export CC_LSP_GATE_THRESHOLD=1
cd '$REAL_DOTFILES_DIR'
_cc_lsp_gate")"
    [[ -n "$gate_file" ]]

    local enabled_count
    enabled_count="$(jq '[.enabledPlugins | to_entries[] | select(.value == true)] | length' "$gate_file")"
    [[ "$enabled_count" -gt 0 ]]
}

@test "_cc_lsp_gate enables bash-language-server for this shell-heavy repo" {
    local gate_file
    gate_file="$(CC_LSP_GATE_THRESHOLD=50 zsh_run "
export CC_LSP_GATE_THRESHOLD=50
cd '$REAL_DOTFILES_DIR'
_cc_lsp_gate")"
    [[ -n "$gate_file" ]]

    local bash_enabled
    bash_enabled="$(jq -r '.enabledPlugins["bash-language-server@claude-code-lsps"]' "$gate_file")"
    [[ "$bash_enabled" == "true" ]]
}

@test "_cc_lsp_gate disables rust-analyzer for this non-Rust repo" {
    local gate_file
    gate_file="$(zsh_run "cd '$REAL_DOTFILES_DIR' && _cc_lsp_gate")"
    [[ -n "$gate_file" ]]

    local rust_enabled
    rust_enabled="$(jq -r '.enabledPlugins["rust-analyzer@claude-code-lsps"]' "$gate_file")"
    [[ "$rust_enabled" == "false" ]]
}

@test "_cc_lsp_gate disables gopls for this non-Go repo" {
    local gate_file
    gate_file="$(zsh_run "cd '$REAL_DOTFILES_DIR' && _cc_lsp_gate")"
    [[ -n "$gate_file" ]]

    local go_enabled
    go_enabled="$(jq -r '.enabledPlugins["gopls@claude-code-lsps"]' "$gate_file")"
    [[ "$go_enabled" == "false" ]]
}

# ── cc wiring ─────────────────────────────────────────────────────────────────

# Direct zsh invocation with explicit env — more reliable than zsh_run for PATH-sensitive tests.
zsh_with_mock() {
    local snippet="$1"
    DOTFILES_DIR="$DOTFILES_DIR" PATH="$MOCK_BIN:$PATH" zsh -c "
source '$REAL_DOTFILES_DIR/zsh/claude.zsh' 2>/dev/null || true
$snippet
" 2>/dev/null
}

@test "cc passes --settings gate file when inside a git repo" {
    local args
    args="$(zsh_with_mock "cd '$REAL_DOTFILES_DIR' && cc --print test")"
    [[ "$args" == *"--settings"* ]]
    [[ "$args" == *"claude-lsp-gate"* ]]
}

@test "cc passes no --settings flag outside a git repo" {
    local args
    args="$(zsh_with_mock "cd /tmp && cc --print test")"
    [[ "$args" != *"claude-lsp-gate"* ]]
}

@test "ccc passes --settings and --continue in a git repo" {
    local args
    args="$(zsh_with_mock "cd '$REAL_DOTFILES_DIR' && ccc")"
    [[ "$args" == *"--settings"* ]]
    [[ "$args" == *"--continue"* ]]
    [[ "$args" == *"claude-lsp-gate"* ]]
}

@test "ccr passes --settings and --resume in a git repo" {
    local args
    args="$(zsh_with_mock "cd '$REAL_DOTFILES_DIR' && ccr")"
    [[ "$args" == *"--settings"* ]]
    [[ "$args" == *"--resume"* ]]
    [[ "$args" == *"claude-lsp-gate"* ]]
}

# ── ccp wiring ────────────────────────────────────────────────────────────────

@test "ccp fe injects gate file before settings-merge.json" {
    local args
    args="$(zsh_with_mock "cd '$REAL_DOTFILES_DIR' && ccp fe")"
    [[ "$args" == *"claude-lsp-gate"* ]]
    # gate comes before the profile settings-merge.json (line order check)
    local gate_line merge_line
    gate_line="$(echo "$args" | grep -n "claude-lsp-gate" | cut -d: -f1 | head -1)"
    merge_line="$(echo "$args" | grep -n "settings-merge.json" | cut -d: -f1 | head -1)"
    [[ -n "$gate_line" && -n "$merge_line" ]]
    [[ "$gate_line" -lt "$merge_line" ]]
}

@test "ccp todo skips gate (profile has full-replace settings.json)" {
    local args
    args="$(zsh_with_mock "cd '$REAL_DOTFILES_DIR' && ccp todo")"
    [[ "$args" != *"claude-lsp-gate"* ]]
}

@test "ccp plugin injects gate (no full-replace settings.json)" {
    local args
    args="$(zsh_with_mock "cd '$REAL_DOTFILES_DIR' && ccp plugin")"
    [[ "$args" == *"claude-lsp-gate"* ]]
}

@test "ccp review injects gate (no full-replace settings.json)" {
    local args
    args="$(zsh_with_mock "cd '$REAL_DOTFILES_DIR' && ccp review")"
    [[ "$args" == *"claude-lsp-gate"* ]]
}

# ── settings-merge.json refactor ──────────────────────────────────────────────

@test "fe/settings-merge.json has no LSP plugin entries" {
    local merge_file="$REAL_DOTFILES_DIR/claude/profiles/fe/settings-merge.json"
    local plugin
    for plugin in "${LSP_PLUGINS[@]}"; do
        run jq --arg k "$plugin" '.enabledPlugins | has($k)' "$merge_file"
        [[ "$output" == "false" ]]
    done
}

@test "plugin/settings-merge.json has no LSP plugin entries" {
    local merge_file="$REAL_DOTFILES_DIR/claude/profiles/plugin/settings-merge.json"
    local plugin
    for plugin in "${LSP_PLUGINS[@]}"; do
        run jq --arg k "$plugin" '.enabledPlugins | has($k)' "$merge_file"
        [[ "$output" == "false" ]]
    done
}

@test "review/settings-merge.json has no LSP plugin entries" {
    local merge_file="$REAL_DOTFILES_DIR/claude/profiles/review/settings-merge.json"
    local plugin
    for plugin in "${LSP_PLUGINS[@]}"; do
        run jq --arg k "$plugin" '.enabledPlugins | has($k)' "$merge_file"
        [[ "$output" == "false" ]]
    done
}

@test "all profile settings-merge.json files are valid JSON" {
    jq -e . "$REAL_DOTFILES_DIR/claude/profiles/fe/settings-merge.json" > /dev/null
    jq -e . "$REAL_DOTFILES_DIR/claude/profiles/plugin/settings-merge.json" > /dev/null
    jq -e . "$REAL_DOTFILES_DIR/claude/profiles/review/settings-merge.json" > /dev/null
}

@test "doc comment describes three-state settings merge behavior" {
    grep -q "preceding settings layer" "$REAL_DOTFILES_DIR/zsh/claude.zsh"
    grep -q "there's no settings.json in the profile" "$REAL_DOTFILES_DIR/zsh/claude.zsh"
}
