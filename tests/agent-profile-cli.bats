#!/usr/bin/env bats
#
# End-to-end tests for `dots profile` (the bin/dots dispatch invokes
# agent-profile/ap, which is what these drive directly).

load test_helper

setup() {
    setup_test_env

    AP="$REAL_DOTFILES_DIR/agent-profile/ap"

    PROFILE_ROOT="$TEST_HOME/profiles"
    TARGET="$TEST_HOME/target"
    mkdir -p "$PROFILE_ROOT" "$TARGET"
    export AP_EXTRA_SEARCH_PATHS="$PROFILE_ROOT"
    export DOTFILES_DIR="$TEST_HOME"
    cd "$TARGET" || exit
}

teardown() {
    teardown_test_env
}

# Materialize a minimally-useful profile under $PROFILE_ROOT/$1.
make_basic_profile() {
    local name="$1"
    local dir="$PROFILE_ROOT/$name"
    mkdir -p "$dir/agents" "$dir/hooks"
    cat > "$dir/profile.yaml" <<EOF
name: $name
description: Basic test profile
agents_md_path: AGENTS.md
agents:
  - name: reviewer
    description: Reviews code
    body_path: agents/reviewer.md
hooks:
  - event: PreToolUse
    matcher: "Bash"
    script: hooks/h.sh
    harnesses: [claude]
settings:
  permissions_allow:
    - "Bash(${name}:*)"
EOF
    echo "$name AGENTS.md content" > "$dir/AGENTS.md"
    echo "Reviewer body for $name" > "$dir/agents/reviewer.md"
    printf '#!/bin/bash\nexit 0\n' > "$dir/hooks/h.sh"
    chmod +x "$dir/hooks/h.sh"
}

# ─── list / describe / path ─────────────────────────────────────────

@test "ap list: prints discovered profiles" {
    make_basic_profile foo
    make_basic_profile bar
    run "$AP" list
    assert_success
    assert_output_contains "foo"
    assert_output_contains "bar"
}

@test "ap list: empty roots prints a friendly message" {
    run "$AP" list
    assert_success
    assert_output_contains "no profiles found"
}

@test "ap describe: emits resolved manifest as JSON" {
    make_basic_profile foo
    run "$AP" describe foo
    assert_success
    assert_output_contains "\"name\": \"foo\""
    assert_output_contains "\"reviewer\""
}

@test "ap path: nonexistent profile fails with clear error" {
    run "$AP" path nope
    assert_failure
    assert_output_contains "not found"
}

# ─── install / uninstall round-trip ────────────────────────────────

@test "ap install: writes claude, codex and opencode artifacts" {
    make_basic_profile foo
    run "$AP" install foo
    assert_success
    [[ -f "$TARGET/.claude/plugins/local/foo/agents/reviewer.md" ]]
    [[ -f "$TARGET/.claude/plugins/local/foo/hooks/h.sh" ]]
    [[ -f "$TARGET/.claude/plugins/local/foo/settings.json" ]]
    [[ -f "$TARGET/.claude/agents/reviewer.md" ]]
    [[ -f "$TARGET/opencode.json" ]]
    [[ -f "$TARGET/.agent-profile/manifest.json" ]]
}

@test "ap install --harness limits to that harness" {
    make_basic_profile foo
    run "$AP" install foo --harness claude
    assert_success
    [[ -d "$TARGET/.claude" ]]
    [[ ! -d "$TARGET/.opencode" ]]
}

@test "ap install --harness rejects unknown harness" {
    make_basic_profile foo
    run "$AP" install foo --harness bogus
    assert_failure
    assert_output_contains "unknown harness"
}

@test "ap install is idempotent (re-run leaves the same files)" {
    make_basic_profile foo
    "$AP" install foo >/dev/null
    local before; before=$(find "$TARGET" -type f | sort)
    "$AP" install foo >/dev/null
    local after; after=$(find "$TARGET" -type f | sort)
    [[ "$before" == "$after" ]]
}

@test "ap uninstall removes everything install created" {
    make_basic_profile foo
    "$AP" install foo >/dev/null
    run "$AP" uninstall foo
    assert_success
    [[ ! -d "$TARGET/.claude/plugins/local/foo" ]]
    [[ ! -f "$TARGET/.claude/agents/reviewer.md" ]]
}

@test "ap uninstall works even after profile dir is deleted" {
    make_basic_profile foo
    "$AP" install foo >/dev/null
    rm -rf "$PROFILE_ROOT/foo"
    run "$AP" uninstall foo
    assert_success
    [[ ! -d "$TARGET/.claude/plugins/local/foo" ]]
}

# ─── per-repo / global precedence ──────────────────────────────────

@test "per-repo .agent-profiles wins over global profiles" {
    # Reset search paths to default precedence (no AP_EXTRA shortcut).
    unset AP_EXTRA_SEARCH_PATHS
    export DOTFILES_DIR="$TEST_HOME/global-root"
    mkdir -p "$DOTFILES_DIR/profiles/dup"
    cat > "$DOTFILES_DIR/profiles/dup/profile.yaml" <<'EOF'
name: dup
description: global-version
EOF
    mkdir -p "$TARGET/.agent-profiles/dup"
    cat > "$TARGET/.agent-profiles/dup/profile.yaml" <<'EOF'
name: dup
description: local-version
EOF
    cd "$TARGET"
    run "$AP" describe dup
    assert_success
    assert_output_contains "local-version"
    assert_output_not_contains "global-version"
}

# ─── help / errors ──────────────────────────────────────────────────

@test "ap help: prints usage" {
    run "$AP" help
    assert_success
    assert_output_contains "Usage: dots profile"
    assert_output_contains "install"
    assert_output_contains "uninstall"
    assert_output_contains "launch"
}

@test "ap with no args: defaults to help" {
    run "$AP"
    assert_success
    assert_output_contains "Usage:"
}

@test "ap install: profile name required" {
    run "$AP" install
    assert_failure
    assert_output_contains "profile name required"
}
