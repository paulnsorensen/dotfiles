#!/usr/bin/env bats
#
# opencode renderer (post-reshape) tests.
#
# Pattern: invoke `agent-profile/ap install <profile> --harness opencode
# --target <tmpdir>` end-to-end and assert on the files it leaves behind.
# This exercises the full install pipeline (parse → render → manifest)
# rather than calling `opencode_render` directly, so per-curd refactors
# of the entrypoint show up here.

load test_helper

setup() {
    setup_test_env
    AP="$REAL_DOTFILES_DIR/agent-profile/ap"
    TARGET="$BATS_TEST_TMPDIR/target"
    mkdir -p "$TARGET"
}

teardown() {
    teardown_test_env
}

# Default rust profile install — opencode harness.
@test "opencode: rust install writes .opencode/commands/<n>.md (plural)" {
    run env DOTFILES_DIR="$REAL_DOTFILES_DIR" bash "$AP" \
        install rust --harness opencode --target "$TARGET"
    assert_success
    [[ -f "$TARGET/.opencode/commands/clippy.md" ]]
}

@test "opencode: rust install does NOT create singular .opencode/command/ dir" {
    run env DOTFILES_DIR="$REAL_DOTFILES_DIR" bash "$AP" \
        install rust --harness opencode --target "$TARGET"
    assert_success
    [[ ! -e "$TARGET/.opencode/command" ]]
}

@test "opencode: default install (no models.opencode) writes NO .opencode/agent/ files" {
    run env DOTFILES_DIR="$REAL_DOTFILES_DIR" bash "$AP" \
        install rust --harness opencode --target "$TARGET"
    assert_success
    # `.opencode/agent/` should not exist, or if mkdir'd by something else, be empty.
    if [[ -d "$TARGET/.opencode/agent" ]]; then
        run find "$TARGET/.opencode/agent" -mindepth 1 -maxdepth 1
        [[ -z "$output" ]]
    fi
}

@test "opencode: rust install never writes AGENTS.md into target" {
    run env DOTFILES_DIR="$REAL_DOTFILES_DIR" bash "$AP" \
        install rust --harness opencode --target "$TARGET"
    assert_success
    [[ ! -e "$TARGET/AGENTS.md" ]]
}

@test "opencode: install preserves pre-existing user opencode.json entries; uninstall keeps them" {
    # User has a pre-populated opencode.json with a custom MCP + a custom
    # permission entry. Install should merge ours in; uninstall should
    # remove only ours.
    cat > "$TARGET/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-sonnet-4-5",
  "mcp": {
    "user-mcp": {"type": "local", "enabled": true, "command": ["my-tool"]}
  },
  "permission": {
    "bash": {"npm *": "allow"}
  }
}
EOF

    run env DOTFILES_DIR="$REAL_DOTFILES_DIR" bash "$AP" \
        install rust --harness opencode --target "$TARGET"
    assert_success

    # Post-install: user entries preserved, ours merged in.
    run cat "$TARGET/opencode.json"
    assert_output_contains "user-mcp"
    assert_output_contains "npm *"
    assert_output_contains "cargo *"
    assert_output_contains "claude-sonnet-4-5"

    # Uninstall — ours go, user's stay.
    run env DOTFILES_DIR="$REAL_DOTFILES_DIR" bash "$AP" \
        uninstall rust --harness opencode --target "$TARGET"
    assert_success

    run cat "$TARGET/opencode.json"
    assert_output_contains "user-mcp"
    assert_output_contains "npm *"
    assert_output_not_contains "cargo *"
}

# A fixture profile that pins `models.opencode` on its agent. Lives in
# $BATS_TEST_TMPDIR so the test owns the lifecycle, and is wired into
# `ap` via AP_EXTRA_SEARCH_PATHS (which `ap_search_roots` consults
# before the global library).
_build_models_fixture() {
    local root="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$root/opmodel/agents"
    cat > "$root/opmodel/agents/myagent.md" <<'EOF'
Body of the model-pinned agent.
EOF
    cat > "$root/opmodel/profile.yaml" <<'EOF'
name: opmodel
description: Fixture profile pinning models.opencode on an agent
agents:
  - name: myagent
    description: A model-pinned agent
    body_path: agents/myagent.md
    models:
      opencode: anthropic/claude-opus-4-7
EOF
    echo "$root"
}

@test "opencode: agent with models.opencode override writes .opencode/agent/<n>.md with model frontmatter" {
    local fixture_root
    fixture_root=$(_build_models_fixture)

    run env DOTFILES_DIR="$REAL_DOTFILES_DIR" \
            AP_EXTRA_SEARCH_PATHS="$fixture_root" \
            bash "$AP" install opmodel --harness opencode --target "$TARGET"
    assert_success

    [[ -f "$TARGET/.opencode/agent/myagent.md" ]]
    run cat "$TARGET/.opencode/agent/myagent.md"
    assert_output_contains "model: anthropic/claude-opus-4-7"
    assert_output_contains "Body of the model-pinned agent."

    # The shared `.claude/agents/myagent.md` should NOT be written when
    # the override is active — opencode reads its own override file.
    [[ ! -f "$TARGET/.claude/agents/myagent.md" ]]
}
