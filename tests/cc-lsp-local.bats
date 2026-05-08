#!/usr/bin/env bats
# Tests for bin/cc-lsp-local — persistent project-local LSP opt-in.

bats_require_minimum_version 1.5.0

load test_helper

CC_LSP_LOCAL="$REAL_DOTFILES_DIR/bin/cc-lsp-local"

LSP_PLUGINS=(
    "bash-language-server@claude-code-lsps"
    "vtsls@claude-code-lsps"
    "yaml-language-server@claude-code-lsps"
    "rust-analyzer@claude-code-lsps"
    "pyright@claude-code-lsps"
    "gopls@claude-code-lsps"
)

setup() {
    setup_test_env

    # Mock tokei so tests run on Linux CI (tokei is a brew/cargo dep on dev
    # machines but absent from GitHub-hosted runners). Returns a fixed shape:
    # ~100 BASH lines, everything else 0. This lets us drive deterministic
    # threshold assertions without depending on tokei being installed.
    MOCK_BIN="$TEST_HOME/mock-bin"
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/tokei" <<'TOKEI'
#!/bin/bash
echo '{"BASH":{"code":100},"Shell":{"code":0},"Zsh":{"code":0},"JavaScript":{"code":0},"TypeScript":{"code":0},"TSX":{"code":0},"JSX":{"code":0},"YAML":{"code":0},"Rust":{"code":0},"Python":{"code":0},"Go":{"code":0}}'
TOKEI
    chmod +x "$MOCK_BIN/tokei"
    export PATH="$MOCK_BIN:$PATH"

    PROJECT_DIR="$TEST_HOME/project"
    mkdir -p "$PROJECT_DIR"
    git -C "$PROJECT_DIR" init -q
    git -C "$PROJECT_DIR" config user.email "t@t.com"
    git -C "$PROJECT_DIR" config user.name "T"
    git -C "$PROJECT_DIR" commit --allow-empty -q -m "init"
    cd "$PROJECT_DIR" || return 1
}

teardown() {
    teardown_test_env
}

# ── argument parsing ──────────────────────────────────────────────────────────

@test "cc-lsp-local --help exits 0 and prints usage anchored on sentinels" {
    run "$CC_LSP_LOCAL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"cc-lsp-local — Enable LSP plugins"* ]]
    [[ "$output" == *"--dry-run"* ]]
    [[ "$output" == *"--threshold"* ]]
    [[ "$output" == *"--print"* ]]
    # Sentinels themselves must not leak into help output.
    [[ "$output" != *"=== usage-start ==="* ]]
    [[ "$output" != *"=== usage-end ==="* ]]
}

@test "cc-lsp-local rejects unknown flags with exit 1" {
    run "$CC_LSP_LOCAL" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown arg: --bogus"* ]]
}

# ── --print mode ──────────────────────────────────────────────────────────────

@test "cc-lsp-local --print emits valid JSON with the 6 LSP plugin keys" {
    run "$CC_LSP_LOCAL" --print
    [ "$status" -eq 0 ]
    echo "$output" | jq -e . >/dev/null
    for plugin in "${LSP_PLUGINS[@]}"; do
        local got
        got="$(echo "$output" | jq -r --arg k "$plugin" '.enabledPlugins[$k]')"
        [[ "$got" == "true" || "$got" == "false" ]]
    done
}

@test "cc-lsp-local --print does not write settings.local.json" {
    [ ! -f .claude/settings.local.json ]
    run "$CC_LSP_LOCAL" --print
    [ "$status" -eq 0 ]
    [ ! -f .claude/settings.local.json ]
}

# ── --dry-run mode ────────────────────────────────────────────────────────────

@test "cc-lsp-local --dry-run shows merged JSON without writing" {
    [ ! -f .claude/settings.local.json ]
    run "$CC_LSP_LOCAL" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] would write to"* ]]
    [[ "$output" == *"enabledPlugins"* ]]
    [ ! -f .claude/settings.local.json ]
}

# ── default write mode + merge semantics ──────────────────────────────────────

@test "cc-lsp-local writes .claude/settings.local.json in the git root" {
    run "$CC_LSP_LOCAL"
    [ "$status" -eq 0 ]
    [ -f .claude/settings.local.json ]
    jq -e '.enabledPlugins["bash-language-server@claude-code-lsps"] == true' \
        .claude/settings.local.json
}

@test "cc-lsp-local writes to git toplevel even when invoked from a subdir" {
    mkdir -p subdir
    cd subdir || return 1
    run "$CC_LSP_LOCAL"
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_DIR/.claude/settings.local.json" ]
    [ ! -f "$PROJECT_DIR/subdir/.claude/settings.local.json" ]
}

@test "cc-lsp-local merge preserves pre-existing non-LSP keys" {
    mkdir -p .claude
    cat > .claude/settings.local.json <<'JSON'
{
  "permissions": {"allow": ["Bash(echo:*)", "Bash(jq:*)"]},
  "env": {"FOO": "bar"},
  "someCustomKey": 42
}
JSON
    run "$CC_LSP_LOCAL"
    [ "$status" -eq 0 ]
    # Non-LSP keys survive the merge.
    [[ "$(jq -r '.permissions.allow[0]' .claude/settings.local.json)" == "Bash(echo:*)" ]]
    [[ "$(jq -r '.permissions.allow[1]' .claude/settings.local.json)" == "Bash(jq:*)" ]]
    [[ "$(jq -r '.env.FOO' .claude/settings.local.json)" == "bar" ]]
    [[ "$(jq -r '.someCustomKey' .claude/settings.local.json)" == "42" ]]
    # And enabledPlugins now exists.
    jq -e '.enabledPlugins | type == "object"' .claude/settings.local.json
}

@test "cc-lsp-local merge replaces a stale enabledPlugins block, not append" {
    mkdir -p .claude
    cat > .claude/settings.local.json <<'JSON'
{
  "enabledPlugins": {"old-plugin@somewhere": true}
}
JSON
    run "$CC_LSP_LOCAL"
    [ "$status" -eq 0 ]
    # Stale entry gone.
    [[ "$(jq -r '.enabledPlugins["old-plugin@somewhere"] // "missing"' .claude/settings.local.json)" == "missing" ]]
    # Fresh entries present.
    jq -e '.enabledPlugins["bash-language-server@claude-code-lsps"]' .claude/settings.local.json
}

# ── --threshold flag ──────────────────────────────────────────────────────────

@test "cc-lsp-local --threshold 999999 disables every LSP" {
    run "$CC_LSP_LOCAL" --threshold 999999
    [ "$status" -eq 0 ]
    for plugin in "${LSP_PLUGINS[@]}"; do
        [[ "$(jq -r --arg k "$plugin" '.enabledPlugins[$k]' .claude/settings.local.json)" == "false" ]]
    done
}

@test "cc-lsp-local --threshold 1 enables at least one LSP for shell-heavy repo" {
    run "$CC_LSP_LOCAL" --threshold 1
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.enabledPlugins["bash-language-server@claude-code-lsps"]' .claude/settings.local.json)" == "true" ]]
}

@test "CC_LSP_GATE_THRESHOLD env var overrides the default threshold" {
    CC_LSP_GATE_THRESHOLD=999999 run "$CC_LSP_LOCAL"
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.enabledPlugins["bash-language-server@claude-code-lsps"]' .claude/settings.local.json)" == "false" ]]
}

# ── failure-path guards ───────────────────────────────────────────────────────

@test "cc-lsp-local refuses to overwrite when settings.local.json is unreadable" {
    mkdir -p .claude
    cat > .claude/settings.local.json <<'JSON'
{"permissions": {"allow": ["important"]}}
JSON
    chmod 000 .claude/settings.local.json

    run --separate-stderr "$CC_LSP_LOCAL"
    chmod 644 .claude/settings.local.json
    [ "$status" -eq 1 ]
    # Message must be on stderr, not stdout — exit code alone is too easy
    # to satisfy by accident from an unrelated set -e tripwire.
    [[ "$stderr" == *"refusing to overwrite"* ]]
    [[ "$output" != *"refusing to overwrite"* ]]
    # Original content is intact (would have been '{}' if guard had failed).
    [[ "$(jq -r '.permissions.allow[0]' .claude/settings.local.json)" == "important" ]]
}

# ── mock-vs-gate-library contract ─────────────────────────────────────────────

@test "mock tokei shape covers every language bucket lsp_gate_compute reads" {
    # Guard against silent drift: if a new language is added to lsp-gate.sh,
    # the mock must be extended too. jq's `//0` default would otherwise
    # silently treat the new language as zero, hiding broken assertions.
    local gate_lib="$REAL_DOTFILES_DIR/claude/lib/lsp-gate.sh"
    local langs
    langs="$(grep -oE '\.[A-Z][A-Za-z]+\.code' "$gate_lib" \
        | sed 's/^\.//; s/\.code$//' | sort -u)"
    [ -n "$langs" ]

    local mock_json
    mock_json="$("$MOCK_BIN/tokei" --output json)"

    local missing=()
    while IFS= read -r lang; do
        if ! echo "$mock_json" | jq -e --arg k "$lang" 'has($k)' >/dev/null; then
            missing+=("$lang")
        fi
    done <<< "$langs"

    [ "${#missing[@]}" -eq 0 ] || {
        echo "Mock tokei is missing language buckets referenced by $gate_lib:" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        return 1
    }
}
