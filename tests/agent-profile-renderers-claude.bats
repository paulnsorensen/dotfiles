#!/usr/bin/env bats
#
# Claude native-plugin renderer tests (Task #14 of pr-177-reshape).
# Drives `agent-profile/ap install rust --harness claude` against the
# real `profiles/rust/` tree and asserts the resulting
# .claude/plugins/local/rust/ layout matches the native plugin shape.

load test_helper

setup() {
    setup_test_env
    AP_DIR="$REAL_DOTFILES_DIR/agent-profile"
    TARGET="$BATS_TEST_TMPDIR/target"
    mkdir -p "$TARGET"
}

teardown() {
    teardown_test_env
}

ap_install_rust() {
    DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash "$AP_DIR/ap" install rust --harness claude --target "$TARGET"
}

ap_uninstall_rust() {
    DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash "$AP_DIR/ap" uninstall rust --harness claude --target "$TARGET"
}

@test "claude install: writes plugin.json marker at plugin root" {
    run ap_install_rust
    assert_success
    [[ -f "$TARGET/.claude/plugins/local/rust/plugin.json" ]]
    run jq -r '.name, .version, .description' "$TARGET/.claude/plugins/local/rust/plugin.json"
    assert_success
    assert_output_contains "rust"
    assert_output_contains "1.0.0"
}

@test "claude install: writes .claude-plugin/plugin.json (the one Claude actually reads)" {
    run ap_install_rust
    assert_success
    [[ -f "$TARGET/.claude/plugins/local/rust/.claude-plugin/plugin.json" ]]
    run jq -r '.name' "$TARGET/.claude/plugins/local/rust/.claude-plugin/plugin.json"
    assert_success
    assert_output_contains "rust"
}

@test "claude install: writes plugin-scoped agents/rust-reviewer.md" {
    run ap_install_rust
    assert_success
    [[ -f "$TARGET/.claude/plugins/local/rust/agents/rust-reviewer.md" ]]
    run cat "$TARGET/.claude/plugins/local/rust/agents/rust-reviewer.md"
    assert_output_contains "name: rust-reviewer"
    assert_output_contains "description:"
}

@test "claude install: also writes cross-harness shared .claude/agents/rust-reviewer.md" {
    run ap_install_rust
    assert_success
    [[ -f "$TARGET/.claude/agents/rust-reviewer.md" ]]
    run cat "$TARGET/.claude/agents/rust-reviewer.md"
    assert_output_contains "name: rust-reviewer"
}

@test "claude install: copies skill tree to plugin skills/cargo-workflow/" {
    run ap_install_rust
    assert_success
    [[ -f "$TARGET/.claude/plugins/local/rust/skills/cargo-workflow/SKILL.md" ]]
}

@test "claude install: writes commands/clippy.md" {
    run ap_install_rust
    assert_success
    [[ -f "$TARGET/.claude/plugins/local/rust/commands/clippy.md" ]]
    run cat "$TARGET/.claude/plugins/local/rust/commands/clippy.md"
    assert_output_contains "description:"
}

@test "claude install: copies cargo-check.sh into plugin hooks/ and wires it in plugin.json" {
    run ap_install_rust
    assert_success
    [[ -f "$TARGET/.claude/plugins/local/rust/hooks/cargo-check.sh" ]]
    [[ -x "$TARGET/.claude/plugins/local/rust/hooks/cargo-check.sh" ]]

    run jq -r '.hooks.PreToolUse[0].hooks[0].command' \
        "$TARGET/.claude/plugins/local/rust/.claude-plugin/plugin.json"
    assert_success
    assert_output_contains "\${CLAUDE_PLUGIN_ROOT}/hooks/cargo-check.sh"
}

@test "claude install: settings.json carries permissions.allow array" {
    run ap_install_rust
    assert_success
    [[ -f "$TARGET/.claude/plugins/local/rust/settings.json" ]]
    run jq -r '.permissions.allow[]' "$TARGET/.claude/plugins/local/rust/settings.json"
    assert_success
    assert_output_contains "Bash(cargo:*)"
    assert_output_contains "Bash(rustc:*)"
    assert_output_contains "Bash(rustup:*)"
}

@test "claude install: no .mcp.json when profile defines no MCPs for claude" {
    run ap_install_rust
    assert_success
    # rust profile has no .mcps[] — the plugin .mcp.json should be absent.
    [[ ! -f "$TARGET/.claude/plugins/local/rust/.mcp.json" ]]
}

@test "claude uninstall: removes the entire plugin directory" {
    run ap_install_rust
    assert_success
    [[ -d "$TARGET/.claude/plugins/local/rust" ]]

    run ap_uninstall_rust
    assert_success
    [[ ! -d "$TARGET/.claude/plugins/local/rust" ]]
    # Shared agent file is tracked too, so it goes.
    [[ ! -f "$TARGET/.claude/agents/rust-reviewer.md" ]]
}
