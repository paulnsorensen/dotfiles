#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for LSP sync infrastructure: lsp-sync.sh and bin/lsp-status

load test_helper

LSP_SYNC="$REAL_DOTFILES_DIR/claude/plugins/lsp-sync.sh"
LSP_STATUS="$REAL_DOTFILES_DIR/bin/lsp-status"

setup() {
    setup_test_env

    MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN" "$TEST_HOME/.claude"

    write_mock_yq
    ln -sf "$(command -v jq)" "$MOCK_BIN/jq"  # real jq
    write_mock_claude
    write_mock_launchctl
    write_fixture_registry

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    teardown_test_env
}


write_mock_yq() {
    cat > "$MOCK_BIN/yq" <<'MOCKYQ'
#!/bin/bash
# Parse args: skip flags to find query and file
query="" file=""
for arg in "$@"; do
    case "$arg" in
        -*) continue ;;
        *)
            if [[ -z "$query" ]]; then
                query="$arg"
            else
                file="$arg"
            fi
            ;;
    esac
done
[[ -z "$file" ]] && exit 1

# Extract LSP names from YAML (lines like "  name@marketplace:")
extract_names() {
    grep -E '^  [a-zA-Z]' "$file" | grep -v '^\s\s\s' | sed 's/^ *//' | sed 's/:$//'
}

case "$query" in
    '.lsps | keys | .[]')
        extract_names
        ;;
    '.lsps | keys')
        names=$(extract_names)
        printf '[\n'
        first=true
        while IFS= read -r n; do
            [[ -z "$n" ]] && continue
            $first || printf ',\n'
            printf '  "%s"' "$n"
            first=false
        done <<< "$names"
        printf '\n]\n'
        ;;
    .lsps.*)
        echo "test description"
        ;;
esac
MOCKYQ
    chmod +x "$MOCK_BIN/yq"
}

write_mock_claude() {
    printf '#!/bin/bash\necho "claude $*" >> "$HOME/claude.log"\n' > "$MOCK_BIN/claude"
    chmod +x "$MOCK_BIN/claude"
}

write_mock_launchctl() {
    cat > "$MOCK_BIN/launchctl" <<'MOCK'
#!/bin/bash
case "$1" in list) echo '{ "PID" = 12345; }';; print) exit 0;; esac
MOCK
    chmod +x "$MOCK_BIN/launchctl"
}

write_fixture_registry() {
    FIXTURE_REGISTRY="$TEST_HOME/lsp-registry.yaml"
    cat > "$FIXTURE_REGISTRY" <<'YAML'
lsps:
  pyright@claude-code-lsps:
    description: Python type checking
    extensions: [py]
  vtsls@claude-code-lsps:
    description: TypeScript language server
    extensions: [ts, js]
YAML
}

make_patched_sync() {
    local registry="${1:-$FIXTURE_REGISTRY}"
    local patched="$TEST_HOME/lsp-sync-patched.sh"
    local settings="$TEST_HOME/.claude/settings.local.json"
    sed \
        -e "s|REGISTRY_FILE=.*|REGISTRY_FILE=\"$registry\"|" \
        -e "s|LOCAL_SETTINGS=.*|LOCAL_SETTINGS=\"$settings\"|" \
        "$LSP_SYNC" > "$patched"
    chmod +x "$patched"
    echo "$patched"
}

settings_path() { echo "$TEST_HOME/.claude/settings.local.json"; }

run_patched() {
    local patched
    patched=$(make_patched_sync)
    run env PATH="$MOCK_BIN:/usr/bin:/bin" bash "$patched" "$@"
}


@test "lsp-sync --list shows enabled and not-set status" {
    echo '{"enabledPlugins":{"pyright@claude-code-lsps":true}}' \
        > "$(settings_path)"
    run_patched --list
    assert_success
    assert_output_contains "[enabled]"
    assert_output_contains "[not set]"
}

@test "lsp-sync --disable removes LSP keys from settings.local.json" {
    echo '{"enabledPlugins":{"pyright@claude-code-lsps":true,"vtsls@claude-code-lsps":true}}' \
        > "$(settings_path)"
    run_patched --disable
    assert_success

    local remaining
    remaining=$(jq '.enabledPlugins | length' "$(settings_path)")
    [ "$remaining" -eq 0 ]
}

@test "lsp-sync --disable preserves non-LSP settings" {
    echo '{"enabledPlugins":{"pyright@claude-code-lsps":true,"other-plugin":true},"someKey":"value"}' \
        > "$(settings_path)"
    run_patched --disable
    assert_success

    run jq -r '.enabledPlugins["other-plugin"]' "$(settings_path)"
    assert_output_contains "true"
    run jq -r '.someKey' "$(settings_path)"
    assert_output_contains "value"
}

@test "lsp-sync --dry-run prints preview without writing" {
    rm -f "$(settings_path)"
    run_patched --dry-run
    assert_success
    assert_output_contains "dry-run"
    [ ! -f "$(settings_path)" ]
}

@test "ensure_local_settings creates file with {} if missing" {
    rm -f "$(settings_path)"
    run_patched
    assert_success
    assert_file_exists "$(settings_path)"
    run jq '.' "$(settings_path)"
    assert_success
}

@test "get_local_status returns true for enabled LSPs" {
    echo '{"enabledPlugins":{"pyright@claude-code-lsps":true}}' > "$(settings_path)"
    run_patched --list
    assert_success
    assert_output_contains "[enabled]"
    assert_output_contains "pyright"
}

@test "get_local_status treats false same as not-set (jq // operator)" {
    # jq's // alternative operator treats false as falsy, so false → "not set"
    echo '{"enabledPlugins":{"pyright@claude-code-lsps":false}}' \
        > "$(settings_path)"
    run_patched --list
    assert_success
    # Both false and missing show as [not set] due to jq // semantics
    assert_output_contains "[not set]"
}

@test "get_local_status returns not set for missing LSPs" {
    echo '{}' > "$(settings_path)"
    run_patched --list
    assert_success
    assert_output_contains "[not set]"
}

@test "enable mode merges LSP entries without clobbering existing settings" {
    echo '{"enabledPlugins":{"other-plugin":true},"customKey":42}' > "$(settings_path)"
    run_patched
    assert_success

    run jq -r '.enabledPlugins["pyright@claude-code-lsps"]' "$(settings_path)"
    assert_output_contains "true"
    run jq -r '.enabledPlugins["other-plugin"]' "$(settings_path)"
    assert_output_contains "true"
    run jq -r '.customKey' "$(settings_path)"
    assert_output_contains "42"
}

@test "missing lsp-registry.yaml exits with error" {
    local patched
    patched=$(make_patched_sync "$TEST_HOME/nonexistent.yaml")
    run env PATH="$MOCK_BIN:/usr/bin:/bin" bash "$patched"
    assert_failure
    assert_output_contains "registry not found"
}

@test "missing yq dependency exits with error" {
    rm -f "$MOCK_BIN/yq"
    local patched
    patched=$(make_patched_sync)
    run env PATH="$MOCK_BIN:/usr/bin:/bin" bash "$patched" --list
    assert_failure
    assert_output_contains "yq not found"
}

@test "missing jq dependency exits with error" {
    rm -f "$MOCK_BIN/jq"
    # Use PATH with only mock bin (no jq) plus bare essentials
    run env PATH="$MOCK_BIN:/bin" bash "$(make_patched_sync)" --list
    assert_failure
    assert_output_contains "jq not found"
}


@test "lsp-status shows binary discovery results" {
    cat > "$MOCK_BIN/pyright-langserver" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_BIN/pyright-langserver"
    run bash "$LSP_STATUS"
    assert_success
    assert_output_contains "Binaries"
}

@test "lsp-status excludes dotfiles/bin wrappers from binary search" {
    # Place a "binary" only in dotfiles/bin (which should be excluded)
    mkdir -p "$TEST_HOME/dotfiles/bin"
    cat > "$TEST_HOME/dotfiles/bin/typescript-language-server" <<'EOF'
#!/bin/bash
echo "wrapper"
EOF
    chmod +x "$TEST_HOME/dotfiles/bin/typescript-language-server"
    # Ensure dotfiles/bin is on PATH; lsp-status should filter it out
    PATH="$TEST_HOME/dotfiles/bin:$MOCK_BIN:/usr/bin:/bin" run bash "$LSP_STATUS"
    assert_success
    # typescript-language-server only exists in dotfiles/bin (filtered out),
    # so it should NOT appear as a found binary
    assert_output_not_contains "typescript-language-server"
}

@test "lsp-status shows plugin list from settings" {
    run bash "$LSP_STATUS"
    assert_success
    assert_output_contains "Plugins"
}

@test "lsp-status handles missing settings.local.json gracefully" {
    rm -f "$TEST_HOME/.claude/settings.local.json"
    run bash "$LSP_STATUS"
    assert_success
}

@test "lsp-status lspmux: detected when running" {
    cat > "$MOCK_BIN/lspmux" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$MOCK_BIN/lspmux"
    run bash "$LSP_STATUS"
    assert_success
    assert_output_contains "lspmux"
}

@test "lsp-status lspmux: not-found when absent" {
    rm -f "$MOCK_BIN/lspmux"
    run env PATH="$MOCK_BIN:/usr/bin:/bin" bash "$LSP_STATUS"
    assert_success
    assert_output_contains "not installed"
}
