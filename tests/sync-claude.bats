#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
# Tests for the harness sync infrastructure: sync-common.sh (shared kernel),
# agents/mcp/sync.sh (multi-harness MCP sync), claude/plugins/sync.sh.

load test_helper

SYNC_COMMON="$REAL_DOTFILES_DIR/claude/lib/sync-common.sh"
MCP_SYNC="$REAL_DOTFILES_DIR/agents/mcp/sync.sh"
MCP_LIB="$REAL_DOTFILES_DIR/agents/mcp/lib.sh"
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


create_mock_sync_dir() {
    local src_script="$1" name="$2"
    local mock_dir="$TEST_HOME/$name"
    mkdir -p "$mock_dir" "$mock_dir/../lib"
    cp "$SYNC_COMMON" "$mock_dir/../lib/sync-common.sh"
    cp "$src_script" "$mock_dir/sync.sh"
    echo "$mock_dir"
}

# agents/mcp/sync.sh sources ../../claude/lib/sync-common.sh — two levels up
# instead of one. Build the deeper mock tree so the relative source path
# resolves the same way it does in the real repo.
create_mock_mcp_sync_dir() {
    local name="$1"
    local root="$TEST_HOME/$name"
    mkdir -p "$root/agents/mcp" "$root/claude/lib"
    cp "$SYNC_COMMON" "$root/claude/lib/sync-common.sh"
    cp "$MCP_SYNC" "$root/agents/mcp/sync.sh"
    cp "$MCP_LIB"  "$root/agents/mcp/lib.sh"
    echo "$root/agents/mcp"
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
  formatter@official:
    description: Code formatter
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


@test "mcp sync: missing registry file exits with error" {
    local mock_dir
    mock_dir=$(create_mock_mcp_sync_dir "mcp-noreg")
    run bash "$mock_dir/sync.sh" --harness claude
    assert_failure
    assert_output_contains "registry.yaml not found"
}

@test "mcp sync: dry-run shows plan without executing" {
    write_mcp_registry
    local mock_dir
    mock_dir=$(create_mock_mcp_sync_dir "mcp-sync")
    cp "$TEST_HOME/registry.yaml" "$mock_dir/registry.yaml"
    run bash "$mock_dir/sync.sh" --dry-run --harness claude
    assert_success
    assert_output_contains "[dry-run]"
    assert_output_contains "alpha"
    assert_output_contains "beta"
    [ ! -f "$CLAUDE_LOG" ] || ! grep -q "claude mcp add" "$CLAUDE_LOG"
}

@test "mcp sync: adds new MCPs with correct scope and args" {
    write_mcp_registry
    local mock_dir
    mock_dir=$(create_mock_mcp_sync_dir "mcp-add")
    cp "$TEST_HOME/registry.yaml" "$mock_dir/registry.yaml"
    run bash "$mock_dir/sync.sh" --harness claude
    assert_success
    grep -q "claude mcp add -s user alpha -- npx alpha-mcp@latest" "$CLAUDE_LOG"
    grep -q "claude mcp add -s project beta -- node beta-server.js" "$CLAUDE_LOG"
}


write_local_plugin_fixtures() {
    local dotfiles_root="$1"
    local plugin_dir="$dotfiles_root/claude/plugins/local/my-plugin"
    mkdir -p "$plugin_dir/.claude-plugin"
    echo '{"name": "my-plugin"}' > "$plugin_dir/.claude-plugin/plugin.json"

    cat > "$dotfiles_root/claude/plugins/registry.yaml" << 'YAML'
plugins:
  formatter@official:
    description: Code formatter
    scope: user
    load: true
  my-plugin@my-plugin:
    description: Local test plugin
    scope: user
    load: true
    path: claude/plugins/local/my-plugin
YAML

    cat > "$dotfiles_root/claude/settings.json" << 'JSON'
{
  "enabledPlugins": {},
  "extraKnownMarketplaces": {}
}
JSON
}


@test "plugin sync: local marketplace path is resolved from dotfiles root" {
    local dotfiles_root
    dotfiles_root="$(mkdir -p "$TEST_HOME/dotfiles" && cd "$TEST_HOME/dotfiles" && pwd -P)"
    local claude_dir="$dotfiles_root/claude"
    local mock_dir="$claude_dir/plugins"
    mkdir -p "$mock_dir" "$claude_dir/lib"
    cp "$SYNC_COMMON" "$claude_dir/lib/sync-common.sh"
    cp "$PLUGIN_SYNC" "$mock_dir/sync.sh"

    write_local_plugin_fixtures "$dotfiles_root"

    run bash "$mock_dir/sync.sh"
    assert_success

    local actual_path
    actual_path=$(jq -r '.extraKnownMarketplaces["my-plugin"].source.path' "$claude_dir/settings.json")
    [[ "$actual_path" == "$dotfiles_root/claude/plugins/local/my-plugin" ]]
}

@test "plugin sync: local marketplace dry-run does not modify settings" {
    local dotfiles_root
    dotfiles_root="$(mkdir -p "$TEST_HOME/dotfiles" && cd "$TEST_HOME/dotfiles" && pwd -P)"
    local claude_dir="$dotfiles_root/claude"
    local mock_dir="$claude_dir/plugins"
    mkdir -p "$mock_dir" "$claude_dir/lib"
    cp "$SYNC_COMMON" "$claude_dir/lib/sync-common.sh"
    cp "$PLUGIN_SYNC" "$mock_dir/sync.sh"

    write_local_plugin_fixtures "$dotfiles_root"

    run bash "$mock_dir/sync.sh" --dry-run
    assert_success
    assert_output_contains "[dry-run]"
    assert_output_contains "my-plugin"

    local actual_path
    actual_path=$(jq -r '.extraKnownMarketplaces["my-plugin"].source.path // "missing"' "$claude_dir/settings.json")
    [[ "$actual_path" == "missing" ]]
}

@test "plugin sync: local marketplace corrects wrong path" {
    local dotfiles_root
    dotfiles_root="$(mkdir -p "$TEST_HOME/dotfiles" && cd "$TEST_HOME/dotfiles" && pwd -P)"
    local claude_dir="$dotfiles_root/claude"
    local mock_dir="$claude_dir/plugins"
    mkdir -p "$mock_dir" "$claude_dir/lib"
    cp "$SYNC_COMMON" "$claude_dir/lib/sync-common.sh"
    cp "$PLUGIN_SYNC" "$mock_dir/sync.sh"

    write_local_plugin_fixtures "$dotfiles_root"
    # Set a wrong path
    jq '.extraKnownMarketplaces["my-plugin"] = {"source": {"source": "directory", "path": "/Users/wrong/path"}}' \
        "$claude_dir/settings.json" > "$claude_dir/settings.json.tmp" && mv "$claude_dir/settings.json.tmp" "$claude_dir/settings.json"

    run bash "$mock_dir/sync.sh"
    assert_success
    assert_output_contains "Updated my-plugin marketplace"

    local actual_path
    actual_path=$(jq -r '.extraKnownMarketplaces["my-plugin"].source.path' "$claude_dir/settings.json")
    [[ "$actual_path" == "$dotfiles_root/claude/plugins/local/my-plugin" ]]
}

@test "plugin sync: local marketplace skips when path already correct" {
    local dotfiles_root
    dotfiles_root="$(mkdir -p "$TEST_HOME/dotfiles" && cd "$TEST_HOME/dotfiles" && pwd -P)"
    local claude_dir="$dotfiles_root/claude"
    local mock_dir="$claude_dir/plugins"
    mkdir -p "$mock_dir" "$claude_dir/lib"
    cp "$SYNC_COMMON" "$claude_dir/lib/sync-common.sh"
    cp "$PLUGIN_SYNC" "$mock_dir/sync.sh"

    write_local_plugin_fixtures "$dotfiles_root"
    # Set the correct path
    jq --arg p "$dotfiles_root/claude/plugins/local/my-plugin" \
        '.extraKnownMarketplaces["my-plugin"] = {"source": {"source": "directory", "path": $p}}' \
        "$claude_dir/settings.json" > "$claude_dir/settings.json.tmp" && mv "$claude_dir/settings.json.tmp" "$claude_dir/settings.json"

    run bash "$mock_dir/sync.sh"
    assert_success
    assert_output_contains "Local marketplaces up to date"
    assert_output_not_contains "Updated my-plugin"
}


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
    assert_output_contains "formatter@official"
    assert_output_contains "linter@community"
    [ ! -f "$CLAUDE_LOG" ] || ! grep -q "claude plugin install" "$CLAUDE_LOG"
}


write_gated_plugin_fixtures() {
    local dotfiles_root="$1"
    local plugin_dir="$dotfiles_root/claude/plugins/local/gated-plugin"
    mkdir -p "$plugin_dir/.claude-plugin"
    echo '{"name": "gated-plugin"}' > "$plugin_dir/.claude-plugin/plugin.json"
    cat > "$dotfiles_root/claude/plugins/registry.yaml" << 'YAML'
plugins:
  formatter@official:
    description: Code formatter
    scope: user
    load: true
  gated-plugin@gated-plugin:
    description: Gated test plugin
    scope: user
    load: true
    path: claude/plugins/local/gated-plugin
    gate: TEST_GATE
YAML
    cat > "$dotfiles_root/claude/settings.json" << 'JSON'
{
  "enabledPlugins": {},
  "extraKnownMarketplaces": {}
}
JSON
}

setup_gated_sync_dir() {
    local dotfiles_root="$1"
    local claude_dir="$dotfiles_root/claude"
    local mock_dir="$claude_dir/plugins"
    mkdir -p "$mock_dir" "$claude_dir/lib"
    cp "$SYNC_COMMON" "$claude_dir/lib/sync-common.sh"
    cp "$PLUGIN_SYNC" "$mock_dir/sync.sh"
    write_gated_plugin_fixtures "$dotfiles_root"
}

@test "plugin sync: gated plugin excluded from enabledPlugins when gate env var unset" {
    local dotfiles_root
    dotfiles_root="$(mkdir -p "$TEST_HOME/dotfiles-gate-off" && cd "$TEST_HOME/dotfiles-gate-off" && pwd -P)"
    setup_gated_sync_dir "$dotfiles_root"

    unset TEST_GATE
    run bash "$dotfiles_root/claude/plugins/sync.sh" --force
    assert_success
    assert_output_not_contains "gated-plugin@gated-plugin"

    local has_gated has_ungated
    has_gated=$(jq '.enabledPlugins | has("gated-plugin@gated-plugin")' "$dotfiles_root/claude/settings.json")
    has_ungated=$(jq '.enabledPlugins | has("formatter@official")' "$dotfiles_root/claude/settings.json")
    [[ "$has_gated" == "false" ]]
    [[ "$has_ungated" == "true" ]]
}

@test "plugin sync: gated plugin included in enabledPlugins when gate env var is true" {
    local dotfiles_root
    dotfiles_root="$(mkdir -p "$TEST_HOME/dotfiles-gate-on" && cd "$TEST_HOME/dotfiles-gate-on" && pwd -P)"
    setup_gated_sync_dir "$dotfiles_root"

    run env TEST_GATE=true bash "$dotfiles_root/claude/plugins/sync.sh" --force
    assert_success
    assert_output_contains "gated-plugin@gated-plugin"

    local has_gated
    has_gated=$(jq '.enabledPlugins | has("gated-plugin@gated-plugin")' "$dotfiles_root/claude/settings.json")
    [[ "$has_gated" == "true" ]]
}

@test "plugin sync: gated-off marketplace entry is removed from extraKnownMarketplaces" {
    local dotfiles_root
    dotfiles_root="$(mkdir -p "$TEST_HOME/dotfiles-gate-cleanup" && cd "$TEST_HOME/dotfiles-gate-cleanup" && pwd -P)"
    setup_gated_sync_dir "$dotfiles_root"

    # First sync with gate on, so the marketplace gets registered.
    run env TEST_GATE=true bash "$dotfiles_root/claude/plugins/sync.sh" --force
    assert_success
    local has_mp
    has_mp=$(jq '.extraKnownMarketplaces | has("gated-plugin")' "$dotfiles_root/claude/settings.json")
    [[ "$has_mp" == "true" ]]

    # Second sync with gate off should remove the stale marketplace entry.
    unset TEST_GATE
    run bash "$dotfiles_root/claude/plugins/sync.sh" --force
    assert_success
    assert_output_contains "Removed gated-plugin marketplace"
    has_mp=$(jq '.extraKnownMarketplaces | has("gated-plugin")' "$dotfiles_root/claude/settings.json")
    [[ "$has_mp" == "false" ]]
}


# ─── codex MCP path + new bug-fix coverage ──────────────────────────────

write_mcp_registry_multi_harness() {
    # alpha → both harnesses; beta → claude only; gamma → codex only; delta
    # → both, but gated_unless GATE_VAR=true (claude-only gate).
    cat > "$TEST_HOME/registry.yaml" << 'YAML'
mcps:
  alpha:
    command: npx
    args: [alpha-mcp@latest]
    scope: user
    description: Both harnesses
  beta:
    command: node
    args: [beta-server.js]
    scope: project
    harnesses: [claude]
    description: Claude only
  gamma:
    command: gamma
    args: [--start]
    harnesses: [codex]
    description: Codex only
  delta:
    command: delta
    args: []
    gate_unless: GATE_VAR
    description: Gated for claude only
YAML
}

install_mock_codex() {
    # Mock `codex mcp list --json` returns nothing by default; tests that need
    # a populated harness can re-write the mock to emit canned JSON.
    export CODEX_LOG="$TEST_HOME/codex.log"
    cat > "$MOCK_BIN/codex" << 'MOCK'
#!/bin/bash
echo "codex $*" >> "${CODEX_LOG:-/dev/null}"
case "$1" in
    mcp)
        case "$2" in
            list)
                # --json present? emit empty array; else emit nothing
                for a in "$@"; do [[ "$a" == "--json" ]] && { echo '[]'; exit 0; }; done
                exit 0 ;;
            add|remove) exit 0 ;;
        esac ;;
esac
exit 0
MOCK
    chmod +x "$MOCK_BIN/codex"
}

@test "mcp sync: --harness codex skips when codex CLI missing" {
    write_mcp_registry_multi_harness
    local mock_dir; mock_dir=$(create_mock_mcp_sync_dir "mcp-codex-missing")
    cp "$TEST_HOME/registry.yaml" "$mock_dir/registry.yaml"
    # Isolate PATH so a real `codex` binary on the dev machine doesn't satisfy `command -v codex`.
    PATH="$MOCK_BIN:/usr/bin:/bin:/opt/homebrew/bin" run bash "$mock_dir/sync.sh" --harness codex
    assert_success
    assert_output_contains "Skipping codex"
}

@test "mcp sync: codex add wires --env, --, and command/args correctly" {
    install_mock_codex
    write_mcp_registry_multi_harness
    local mock_dir; mock_dir=$(create_mock_mcp_sync_dir "mcp-codex-add")
    cp "$TEST_HOME/registry.yaml" "$mock_dir/registry.yaml"
    run bash "$mock_dir/sync.sh" --harness codex
    assert_success
    # alpha is both-harness; gamma is codex-only; beta is claude-only and must
    # NOT appear in the codex log; delta has no `harnesses:` so it also flows
    # to codex (gate_unless is claude-only).
    grep -q "codex mcp add alpha -- npx alpha-mcp@latest" "$CODEX_LOG"
    grep -q "codex mcp add gamma -- gamma --start" "$CODEX_LOG"
    grep -q "codex mcp add delta -- delta" "$CODEX_LOG"
    ! grep -q "codex mcp add beta" "$CODEX_LOG"
}

@test "mcp sync: codex harness filter excludes claude-only entries" {
    install_mock_codex
    write_mcp_registry_multi_harness
    local mock_dir; mock_dir=$(create_mock_mcp_sync_dir "mcp-codex-filter")
    cp "$TEST_HOME/registry.yaml" "$mock_dir/registry.yaml"
    run bash "$mock_dir/sync.sh" --dry-run --harness codex
    assert_success
    assert_output_contains "alpha"
    assert_output_contains "gamma"
    assert_output_contains "delta"
    assert_output_not_contains "beta"
}

@test "mcp sync: gate_unless does NOT apply to codex (claude-only gate)" {
    install_mock_codex
    write_mcp_registry_multi_harness
    local mock_dir; mock_dir=$(create_mock_mcp_sync_dir "mcp-codex-gate")
    cp "$TEST_HOME/registry.yaml" "$mock_dir/registry.yaml"
    # GATE_VAR=true would suppress delta for claude, but codex must still install it.
    run env GATE_VAR=true bash "$mock_dir/sync.sh" --harness codex
    assert_success
    grep -q "codex mcp add delta" "$CODEX_LOG"
}

@test "mcp sync: failed add bubbles up as non-zero exit" {
    write_mcp_registry_multi_harness
    local mock_dir; mock_dir=$(create_mock_mcp_sync_dir "mcp-fail-exit")
    cp "$TEST_HOME/registry.yaml" "$mock_dir/registry.yaml"
    # Re-mock claude so `mcp add` fails.
    cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
echo "claude $*" >> "${CLAUDE_LOG:-/dev/null}"
case "$1" in
    mcp)  case "$2" in get) exit 1;; add) echo "boom" >&2; exit 7;; remove) exit 0;; esac;;
esac
exit 0
MOCK
    chmod +x "$MOCK_BIN/claude"
    run bash "$mock_dir/sync.sh" --harness claude
    assert_failure
    assert_output_contains "add failure"
}

@test "mcp_load_dotenv strips quotes, normalises indentation, rejects bad identifiers" {
    source "$MCP_LIB"
    local envf="$TEST_HOME/.env-mixed"
    cat > "$envf" <<'ENV'
# comment
   # indented comment
GOOD_KEY=plain-value
QUOTED_KEY="quoted with spaces"
SINGLE='single-quoted'
  INDENTED_KEY=indented-value
NAME WITH SPACE=ignored
1BAD_LEADING_DIGIT=also-ignored
export EXPORTED=exported-value
ENV
    unset GOOD_KEY QUOTED_KEY SINGLE INDENTED_KEY EXPORTED \
          "NAME WITH SPACE" 1BAD_LEADING_DIGIT 2>/dev/null || true
    mcp_load_dotenv "$envf"
    [[ "${GOOD_KEY:-}"     == "plain-value" ]]
    [[ "${QUOTED_KEY:-}"   == "quoted with spaces" ]]
    [[ "${SINGLE:-}"       == "single-quoted" ]]
    # Indented keys parse correctly (no crash under set -euo pipefail).
    [[ "${INDENTED_KEY:-}" == "indented-value" ]]
    [[ "${EXPORTED:-}"     == "exported-value" ]]
    # Malformed identifiers are silently skipped.
    ! env | grep -q '^1BAD_LEADING_DIGIT='
}

@test "mcp_claude_get_scope anchors on Scope: field, ignores arg text" {
    source "$MCP_LIB"
    # Mock claude that simulates an MCP whose Args block contains "user"
    cat > "$MOCK_BIN/claude" << 'MOCK'
#!/bin/bash
if [[ "$1" == "mcp" && "$2" == "get" ]]; then
    cat <<INFO
  Scope: project
  Command: /opt/tool
  Args: --user-agent custom-ua --user-data-dir /tmp/user
INFO
fi
exit 0
MOCK
    chmod +x "$MOCK_BIN/claude"
    result=$(mcp_claude_get_scope some-mcp)
    [[ "$result" == "project" ]]
}

@test "mcp_resolve_env_value expands \${VAR} references" {
    source "$MCP_LIB"
    export DRIFT_TEST_KEY=resolved-secret
    # `\$` inside double quotes is a literal $, so the function gets the
    # unexpanded reference and does the expansion itself (what we're testing).
    [[ "$(mcp_resolve_env_value "\${DRIFT_TEST_KEY}")" == "resolved-secret" ]]
    [[ "$(mcp_resolve_env_value "plain-string")" == "plain-string" ]]
    [[ "$(mcp_resolve_env_value "\${UNSET_DRIFT_KEY}")" == "" ]]
}

@test "mcp_filter_for_harness honors per-entry harnesses list" {
    source "$MCP_LIB"
    local json='{"a":{"command":"x"},"b":{"command":"y","harnesses":["claude"]},"c":{"command":"z","harnesses":["codex"]}}'
    local claude_out codex_out
    claude_out=$(mcp_filter_for_harness claude "$json" | jq -r 'keys | sort | join(",")')
    codex_out=$(mcp_filter_for_harness  codex  "$json" | jq -r 'keys | sort | join(",")')
    [[ "$claude_out" == "a,b" ]]
    [[ "$codex_out"  == "a,c" ]]
}

@test "mcp_filter_for_harness applies gate_unless for claude only" {
    source "$MCP_LIB"
    local json='{"gated":{"command":"x","gate_unless":"GATE_ON"}}'
    # `export` is required: jq's `env[$g]` only sees exported vars, and the
    # mcp_filter_for_harness call forks a child jq process. A bare `GATE_ON=
    # true` would only set a shell-local var that jq cannot read.
    export GATE_ON=true
    local claude_keys codex_keys
    claude_keys=$(mcp_filter_for_harness claude "$json" | jq -r 'keys | length')
    codex_keys=$( mcp_filter_for_harness codex  "$json" | jq -r 'keys | length')
    unset GATE_ON
    [[ "$claude_keys" == "0" ]]   # claude gated off
    [[ "$codex_keys"  == "1" ]]   # codex ignores gate_unless
}
