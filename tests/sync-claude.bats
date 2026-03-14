#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
# Tests for Claude sync infrastructure (sync-common.sh, mcp/sync.sh, plugins/sync.sh)

load test_helper

SYNC_COMMON="$REAL_DOTFILES_DIR/claude/lib/sync-common.sh"
MCP_SYNC="$REAL_DOTFILES_DIR/claude/mcp/sync.sh"
PLUGIN_SYNC="$REAL_DOTFILES_DIR/claude/plugins/sync.sh"

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    export CLAUDE_LOG="$TEST_HOME/claude.log"
    cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
echo "claude $*" >> "${CLAUDE_LOG:-/dev/null}"
case "$1" in
    mcp)  case "$2" in get) exit 1;; add|remove) exit 0;; esac;;
    plugin) case "$2" in install|remove) exit 0;; esac;;
esac
exit 0
MOCK
    chmod +x "$MOCK_BIN/claude"
    export PATH="$MOCK_BIN:$PATH"
}

teardown() { teardown_test_env; }

# --- Fixture helpers ---

create_mock_sync_dir() {
    local src_script="$1" name="$2"
    local mock_dir="$TEST_HOME/$name"
    mkdir -p "$mock_dir" "$mock_dir/../lib"
    cp "$SYNC_COMMON" "$mock_dir/../lib/sync-common.sh"
    cp "$src_script" "$mock_dir/sync.sh"
    echo "$mock_dir"
}

write_mcp_registry() {
    cat > "$TEST_HOME/registry.yaml" << 'YAML'
mcps:
  alpha:
    command: npx
    args: [alpha-mcp@latest]
    scope: user
    description: Alpha tool
  beta:
    command: node
    args: [beta-server.js]
    scope: project
    description: Beta tool
YAML
}

write_plugin_fixtures() {
    cat > "$TEST_HOME/plugin-registry.yaml" << 'YAML'
plugins:
  hookify@official:
    description: Hook management
    scope: user
    load: true
  linter@community:
    description: Code linter
    scope: user
    load: false
YAML
    cat > "$TEST_HOME/settings.json" << 'JSON'
{ "enabledPlugins": {} }
JSON
}

# --- sync_parse_args ---

@test "sync_parse_args sets DRY_RUN=true with --dry-run" {
    source "$SYNC_COMMON"
    DRY_RUN=false
    sync_parse_args --dry-run
    [[ "$DRY_RUN" == "true" ]]
}

@test "sync_parse_args sets FORCE=true with --force" {
    source "$SYNC_COMMON"
    FORCE=false
    sync_parse_args --force
    [[ "$FORCE" == "true" ]]
}

@test "sync_parse_args --help exits 0 with usage" {
    source "$SYNC_COMMON"
    run sync_parse_args --help
    assert_success
    assert_output_contains "Usage:"
    assert_output_contains "--dry-run"
}

# --- sync_check_deps ---

@test "sync_check_deps fails when claude is missing" {
    rm -f "$MOCK_BIN/claude"
    ln -sf "$(command -v yq)" "$MOCK_BIN/yq"
    ln -sf "$(command -v jq)" "$MOCK_BIN/jq"
    PATH="$MOCK_BIN:/usr/bin:/bin" run bash -c "source '$SYNC_COMMON' && sync_check_deps"
    assert_failure
    assert_output_contains "claude not found"
}

@test "sync_check_deps fails when yq is missing" {
    source "$SYNC_COMMON"
    local d="$TEST_HOME/deps-bin" && mkdir -p "$d"
    cp "$MOCK_BIN/claude" "$d/claude"
    ln -sf "$(command -v jq)" "$d/jq"
    PATH="$d" run sync_check_deps
    assert_failure
    assert_output_contains "yq not found"
}

@test "sync_check_deps fails when jq is missing" {
    source "$SYNC_COMMON"
    local d="$TEST_HOME/deps-bin" && mkdir -p "$d"
    cp "$MOCK_BIN/claude" "$d/claude"
    ln -sf "$(command -v yq)" "$d/yq"
    PATH="$d" run sync_check_deps
    assert_failure
    assert_output_contains "jq not found"
}

@test "sync_check_deps passes when all deps present" {
    source "$SYNC_COMMON"
    run sync_check_deps
    assert_success
}

# --- sync_compute_diff ---

@test "sync_compute_diff correctly computes TO_ADD" {
    source "$SYNC_COMMON"
    DESIRED_NAMES=$'alpha\nbeta\ngamma'; CURRENT_NAMES=$'alpha'
    sync_compute_diff
    [[ "$TO_ADD" == *"beta"* && "$TO_ADD" == *"gamma"* && "$TO_ADD" != *"alpha"* ]]
}

@test "sync_compute_diff correctly computes TO_REMOVE" {
    source "$SYNC_COMMON"
    DESIRED_NAMES=$'alpha'; CURRENT_NAMES=$'alpha\nobsolete'
    sync_compute_diff
    [[ "$TO_REMOVE" == *"obsolete"* && "$TO_REMOVE" != *"alpha"* ]]
}

@test "sync_compute_diff correctly computes EXISTING" {
    source "$SYNC_COMMON"
    DESIRED_NAMES=$'alpha\nbeta'; CURRENT_NAMES=$'alpha\nbeta\nextra'
    sync_compute_diff
    [[ "$EXISTING" == *"alpha"* && "$EXISTING" == *"beta"* ]]
}

@test "sync_compute_diff sets correct counts" {
    source "$SYNC_COMMON"
    DESIRED_NAMES=$'alpha\nbeta\ngamma'; CURRENT_NAMES=$'beta\ndelta'
    sync_compute_diff
    [[ "$desired_count" -eq 3 && "$current_count" -eq 2 ]]
    [[ "$add_count" -eq 2 && "$remove_count" -eq 1 ]]
}

# --- sync_show_plan ---

@test "sync_show_plan returns 1 when everything in sync" {
    source "$SYNC_COMMON"
    TO_ADD=""; TO_REMOVE=""; EXISTING="alpha"
    desired_count=1; current_count=1
    run sync_show_plan "items"
    assert_failure
    assert_output_contains "Everything in sync"
}

@test "sync_show_plan returns 0 and shows add/remove when diff exists" {
    source "$SYNC_COMMON"
    TO_ADD="newone"; TO_REMOVE="oldone"; EXISTING=""
    desired_count=1; current_count=1; add_count=1; remove_count=1
    get_description() { echo "test desc"; }
    export -f get_description
    run sync_show_plan "items"
    assert_success
    assert_output_contains "To add"
    assert_output_contains "newone"
    assert_output_contains "Not in registry"
    assert_output_contains "oldone"
}

# --- sync_handle_removals ---

@test "sync_handle_removals with force+dry-run shows [dry-run]" {
    source "$SYNC_COMMON"
    FORCE=true; DRY_RUN=true; TO_REMOVE="stale-mcp"
    get_item_scope() { echo "user"; }
    remove_item() { return 0; }
    run sync_handle_removals "MCPs"
    assert_success
    assert_output_contains "[dry-run]"
    assert_output_contains "Would remove"
    assert_output_contains "stale-mcp"
}

@test "sync_handle_removals with force removes items" {
    source "$SYNC_COMMON"
    FORCE=true; DRY_RUN=false; TO_REMOVE="stale-mcp"
    get_item_scope() { echo "user"; }
    remove_item() { return 0; }
    run sync_handle_removals "MCPs"
    assert_success
    assert_output_contains "Removing stale-mcp"
    assert_output_contains "done"
}

@test "sync_handle_removals without force skips in non-interactive" {
    run bash -c "
        source '$SYNC_COMMON'
        FORCE=false; DRY_RUN=false; TO_REMOVE='stale-mcp'
        get_item_scope() { echo 'user'; }
        remove_item() { return 0; }
        echo '' | sync_handle_removals 'MCPs'
    "
    assert_success
    assert_output_contains "Keeping stale-mcp"
}

# --- mcp/sync.sh ---

@test "mcp sync: missing registry file exits with error" {
    local mock_dir
    mock_dir=$(create_mock_sync_dir "$MCP_SYNC" "mcp-noreg")
    run bash "$mock_dir/sync.sh"
    assert_failure
    assert_output_contains "Registry file not found"
}

@test "mcp sync: dry-run shows plan without executing" {
    write_mcp_registry
    local mock_dir
    mock_dir=$(create_mock_sync_dir "$MCP_SYNC" "mcp-sync")
    cp "$TEST_HOME/registry.yaml" "$mock_dir/registry.yaml"
    run bash "$mock_dir/sync.sh" --dry-run
    assert_success
    assert_output_contains "[dry-run]"
    assert_output_contains "alpha"
    assert_output_contains "beta"
    if [[ -f "$CLAUDE_LOG" ]]; then
        ! grep -q "claude mcp add" "$CLAUDE_LOG"
    fi
}

@test "mcp sync: adds new MCPs with correct scope and args" {
    write_mcp_registry
    local mock_dir
    mock_dir=$(create_mock_sync_dir "$MCP_SYNC" "mcp-add")
    cp "$TEST_HOME/registry.yaml" "$mock_dir/registry.yaml"
    run bash "$mock_dir/sync.sh"
    assert_success
    grep -q "claude mcp add -s user alpha -- npx alpha-mcp@latest" "$CLAUDE_LOG"
    grep -q "claude mcp add -s project beta -- node beta-server.js" "$CLAUDE_LOG"
}

# --- plugins/sync.sh ---

@test "plugin sync: missing registry file exits with error" {
    local mock_dir
    mock_dir=$(create_mock_sync_dir "$PLUGIN_SYNC" "plugin-noreg")
    run bash "$mock_dir/sync.sh"
    assert_failure
    assert_output_contains "Registry file not found"
}

@test "plugin sync: dry-run shows plan without executing" {
    write_plugin_fixtures
    local claude_dir="$TEST_HOME/mock-claude"
    local mock_dir="$claude_dir/plugins"
    mkdir -p "$mock_dir" "$claude_dir/lib"
    cp "$SYNC_COMMON" "$claude_dir/lib/sync-common.sh"
    cp "$PLUGIN_SYNC" "$mock_dir/sync.sh"
    cp "$TEST_HOME/plugin-registry.yaml" "$mock_dir/registry.yaml"
    cp "$TEST_HOME/settings.json" "$claude_dir/settings.json"
    run bash "$mock_dir/sync.sh" --dry-run
    assert_success
    assert_output_contains "[dry-run]"
    assert_output_contains "hookify@official"
    assert_output_contains "linter@community"
    if [[ -f "$CLAUDE_LOG" ]]; then
        ! grep -q "claude plugin install" "$CLAUDE_LOG"
    fi
}
