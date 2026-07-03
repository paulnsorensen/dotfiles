#!/usr/bin/env bats
# Behavioural tests for claude/plugins/sync.sh — the plugin install/remove +
# local-marketplace registration script.
#
# Post-single-writer ownership split: sync.sh writes NOTHING to settings.json
# (chezmoi/dot_claude/modify_settings.json owns enabledPlugins /
# extraKnownMarketplaces). Removal candidates come from user-scoped keys of
# ~/.claude/plugins/installed_plugins.json (seam: CLAUDE_INSTALLED_PLUGINS_FILE),
# NOT settings.json — so installed-but-disabled plugins are removal candidates
# and project-scoped plugins are never touched.
#
# `claude` is mocked on $PATH (logs its args, exits 0); the real repo registry
# (claude/plugins/registry.yaml) is used since sync.sh hardcodes SCRIPT_DIR.

load test_helper

SYNC="$REAL_DOTFILES_DIR/claude/plugins/sync.sh"

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    # Deterministic gates: all local plugin gates closed unless a test opens one.
    unset TODOIST CHEESE_FLOW VAUDEVILLE
    mk_claude_mock
    MANIFEST="$TEST_HOME/installed_plugins.json"
    export CLAUDE_INSTALLED_PLUGINS_FILE="$MANIFEST"
}

teardown() { teardown_test_env; }

# Mock `claude`: append the full argv to $CLAUDE_LOG, succeed.
mk_claude_mock() {
    local bindir="$TEST_HOME/bin"
    mkdir -p "$bindir"
    export CLAUDE_LOG="$TEST_HOME/claude-calls.log"
    : > "$CLAUDE_LOG"
    cat > "$bindir/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CLAUDE_LOG"
exit 0
EOF
    chmod +x "$bindir/claude"
    export PATH="$bindir:$PATH"
}

# Write $1 as the installed_plugins.json content.
write_manifest() {
    printf '%s\n' "$1" > "$MANIFEST"
}

# A manifest with the 5 registry plugins + an orphan user-scope plugin
# (claude-hud) + a project-scope plugin (hallouminate).
manifest_with_orphans() {
    write_manifest '{
      "version": 2,
      "plugins": {
        "claude-md-management@claude-plugins-official": [{"scope":"user"}],
        "playwright@claude-plugins-official":           [{"scope":"user"}],
        "frontend-design@claude-plugins-official":      [{"scope":"user"}],
        "plugin-dev@claude-plugins-official":           [{"scope":"user"}],
        "skill-creator@claude-plugins-official":        [{"scope":"user"}],
        "claude-hud@claude-hud":                        [{"scope":"user"}],
        "hallouminate@hallouminate":                    [{"scope":"project","projectPath":"/somewhere"}]
      }
    }'
}

@test "sync.sh: never writes settings.json (dry-run leaves it byte-identical)" {
    manifest_with_orphans
    local settings="$TEST_HOME/.claude/settings.json"
    mkdir -p "$TEST_HOME/.claude"
    printf '%s\n' '{"sentinel":"do-not-touch","enabledPlugins":{"x@y":true}}' > "$settings"
    local before; before=$(cat "$settings")
    run bash "$SYNC" --dry-run
    [ "$status" -eq 0 ]
    [ "$(cat "$settings")" = "$before" ]
}

@test "sync.sh: never writes settings.json (mocked --force run leaves it byte-identical)" {
    manifest_with_orphans
    local settings="$TEST_HOME/.claude/settings.json"
    mkdir -p "$TEST_HOME/.claude"
    printf '%s\n' '{"sentinel":"do-not-touch","enabledPlugins":{"x@y":true}}' > "$settings"
    local before; before=$(cat "$settings")
    run bash "$SYNC" --force
    [ "$status" -eq 0 ]
    [ "$(cat "$settings")" = "$before" ]
}

@test "sync.sh: removal diff flags an orphan user-scope plugin, never a project-scope one" {
    manifest_with_orphans
    run bash "$SYNC" --dry-run
    [ "$status" -eq 0 ]
    # Orphan installed at user scope, not in the (gate-closed) registry → removal.
    [[ "$output" == *"claude-hud@claude-hud"* ]]
    [[ "$output" == *"Would prompt to remove: claude-hud@claude-hud"* ]]
    # Project-scoped plugin is excluded from CURRENT_NAMES → never a candidate.
    [[ "$output" != *"hallouminate"* ]]
}

@test "sync.sh: missing manifest yields no removals of desired plugins" {
    # No manifest file at all → CURRENT_NAMES empty → nothing to remove.
    [ ! -f "$MANIFEST" ]
    run bash "$SYNC" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" != *"Would prompt to remove"* ]]
}

@test "sync.sh: registers the local marketplace via the CLI for a gate-open local plugin" {
    # Gate open → todoist-flow (path claude/plugins/local/todoist-flow, which
    # exists in the repo) should be registered with `claude plugin marketplace add`.
    manifest_with_orphans
    run env TODOIST=true bash "$SYNC" --force
    [ "$status" -eq 0 ]
    # The marketplace add was invoked with the resolved absolute path.
    run cat "$CLAUDE_LOG"
    [[ "$output" == *"plugin marketplace add "*"/claude/plugins/local/todoist-flow"* ]]
}

@test "sync.sh: gate-closed local plugin is NOT registered" {
    manifest_with_orphans
    run bash "$SYNC" --force
    [ "$status" -eq 0 ]
    run cat "$CLAUDE_LOG"
    [[ "$output" != *"marketplace add"*"todoist-flow"* ]]
}
