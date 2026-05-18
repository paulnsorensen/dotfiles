#!/usr/bin/env bats
#
# Renderer tests for agent-profile/renderers/cursor.sh.
#
# Cursor is a "new" target — its dispatch wiring in agent-profile/ap
# lands in W1 after all renderer curds (C1..C5) merge. Until then, these
# tests source the renderer directly and invoke `cursor_render` against
# a merged manifest (rust profile or hand-crafted JSON), then assert on
# the on-disk shape.

load test_helper

setup() {
    setup_test_env

    AP_DIR="$REAL_DOTFILES_DIR/agent-profile"
    # shellcheck source=../agent-profile/lib/parse.sh
    source "$AP_DIR/lib/parse.sh"
    # shellcheck source=../agent-profile/lib/discover.sh
    source "$AP_DIR/lib/discover.sh"
    # shellcheck source=../agent-profile/lib/shared_writer.sh
    source "$AP_DIR/lib/shared_writer.sh"
    # shellcheck source=../agent-profile/renderers/cursor.sh
    source "$AP_DIR/renderers/cursor.sh"

    TARGET="$TEST_HOME/target"
    SRC="$TEST_HOME/src"
    mkdir -p "$TARGET" "$SRC"

    _AP_OUT_FILES=()
}

teardown() {
    teardown_test_env
}

# Build a merged-manifest JSON pointing _source_dir at $SRC, where the
# test can lay down body/script/skill files.
merged() {
    local body="$1"
    jq -n --arg sd "$SRC" --argjson b "$body" '
        {
          name: (.name // "p1"),
          description: "test",
          mcps: [], agents: [], skills: [],
          commands: [], hooks: [],
          settings: {}
        } * ($b + {})
        | .mcps     |= map(. + {_source_dir: $sd})
        | .agents   |= map(. + {_source_dir: $sd})
        | .skills   |= map(. + {_source_dir: $sd})
        | .commands |= map(. + {_source_dir: $sd})
        | .hooks    |= map(. + {_source_dir: $sd})
    '
}

# ─── rust profile end-to-end ─────────────────────────────────────────

@test "cursor_render: rust profile writes .cursor/commands/clippy.md" {
    local m
    m=$(DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash -c "source '$REAL_DOTFILES_DIR/agent-profile/lib/parse.sh'; \
                 source '$REAL_DOTFILES_DIR/agent-profile/lib/discover.sh'; \
                 ap_parse_manifest '$REAL_DOTFILES_DIR/profiles/rust'")
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.cursor/commands/clippy.md" ]]
    run cat "$TARGET/.cursor/commands/clippy.md"
    assert_output_contains "description: Run cargo clippy"
    assert_output_contains "cargo clippy"
}

@test "cursor_render: rust profile emits shared .claude/agents/<n>.md" {
    local m
    m=$(DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash -c "source '$REAL_DOTFILES_DIR/agent-profile/lib/parse.sh'; \
                 source '$REAL_DOTFILES_DIR/agent-profile/lib/discover.sh'; \
                 ap_parse_manifest '$REAL_DOTFILES_DIR/profiles/rust'")
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.claude/agents/rust-reviewer.md" ]]
    run cat "$TARGET/.claude/agents/rust-reviewer.md"
    assert_output_contains "name: rust-reviewer"
    assert_output_contains "Reviews Rust code"
    # No cursor-specific override file — rust profile doesn't set models.cursor.
    [[ ! -f "$TARGET/.cursor/agents/rust-reviewer.md" ]]
}

@test "cursor_render: rust profile copies skill tree to shared .agents/skills/<n>/" {
    local m
    m=$(DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash -c "source '$REAL_DOTFILES_DIR/agent-profile/lib/parse.sh'; \
                 source '$REAL_DOTFILES_DIR/agent-profile/lib/discover.sh'; \
                 ap_parse_manifest '$REAL_DOTFILES_DIR/profiles/rust'")
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ -d "$TARGET/.agents/skills/cargo-workflow" ]]
    [[ -f "$TARGET/.agents/skills/cargo-workflow/SKILL.md" ]]
}

@test "cursor_render: rust profile's claude-only hook does NOT produce .cursor/hooks.json" {
    local m
    m=$(DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash -c "source '$REAL_DOTFILES_DIR/agent-profile/lib/parse.sh'; \
                 source '$REAL_DOTFILES_DIR/agent-profile/lib/discover.sh'; \
                 ap_parse_manifest '$REAL_DOTFILES_DIR/profiles/rust'")
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ ! -f "$TARGET/.cursor/hooks.json" ]]
}

@test "cursor_render: rust profile never touches AGENTS.md" {
    local m
    m=$(DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash -c "source '$REAL_DOTFILES_DIR/agent-profile/lib/parse.sh'; \
                 source '$REAL_DOTFILES_DIR/agent-profile/lib/discover.sh'; \
                 ap_parse_manifest '$REAL_DOTFILES_DIR/profiles/rust'")
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ ! -f "$TARGET/AGENTS.md" ]]
}

# ─── hand-crafted manifest cases ─────────────────────────────────────

@test "cursor_render: hook with harnesses:[cursor] lands in .cursor/hooks.json" {
    mkdir -p "$SRC/hooks"
    printf '#!/bin/bash\necho hi\n' > "$SRC/hooks/h.sh"
    chmod +x "$SRC/hooks/h.sh"
    local m
    m=$(merged '{
        "name":"p1",
        "hooks":[{"event":"beforeShellExecution","matcher":"","script":"hooks/h.sh","harnesses":["cursor"]}]
    }')
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.cursor/hooks.json" ]]
    [[ -x "$TARGET/.cursor/hooks/h.sh" ]]
    run cat "$TARGET/.cursor/hooks.json"
    assert_output_contains "beforeShellExecution"
    assert_output_contains ".cursor/hooks/h.sh"
}

@test "cursor_render: mcp entries land as {mcpServers:{...}} with command + args" {
    local m
    m=$(merged '{
        "name":"p1",
        "mcps":[{"name":"foo","command":"npx","args":["-y","foo-mcp"],"harnesses":["cursor"]}]
    }')
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.cursor/mcp.json" ]]
    run cat "$TARGET/.cursor/mcp.json"
    assert_output_contains "mcpServers"
    assert_output_contains "\"foo\""
    assert_output_contains "foo-mcp"
}

@test "cursor_render: mcp merge preserves pre-existing user entries" {
    mkdir -p "$TARGET/.cursor"
    cat > "$TARGET/.cursor/mcp.json" <<'EOF'
{"mcpServers": {"user-mcp": {"command": "uvx", "args": ["user-thing"]}}, "extraKey": "preserved"}
EOF
    local m
    m=$(merged '{
        "name":"p1",
        "mcps":[{"name":"foo","command":"npx","args":["-y","foo-mcp"],"harnesses":["cursor"]}]
    }')
    run cursor_render "$m" "$TARGET"
    assert_success
    run cat "$TARGET/.cursor/mcp.json"
    assert_output_contains "user-mcp"
    assert_output_contains "\"foo\""
    assert_output_contains "extraKey"
}

@test "cursor_clean: removes only profile-added mcp entries, preserves user entries" {
    mkdir -p "$TARGET/.cursor"
    cat > "$TARGET/.cursor/mcp.json" <<'EOF'
{"mcpServers": {"foo": {"command": "x"}, "user-mcp": {"command": "y"}}, "extraKey": "preserved"}
EOF
    local m
    m=$(merged '{
        "name":"p1",
        "mcps":[{"name":"foo","command":"x","harnesses":["cursor"]}]
    }')
    run cursor_clean "$m" "$TARGET"
    assert_success
    run cat "$TARGET/.cursor/mcp.json"
    assert_output_not_contains "\"foo\""
    assert_output_contains "user-mcp"
    assert_output_contains "extraKey"
}

@test "cursor_render: models.cursor=inherit emits no .cursor/agents override file" {
    mkdir -p "$SRC/agents"
    echo "agent body" > "$SRC/agents/a.md"
    local m
    m=$(merged '{
        "name":"p1",
        "agents":[{"name":"a","description":"d","body_path":"agents/a.md","models":{"cursor":"inherit"}}]
    }')
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.claude/agents/a.md" ]]
    [[ ! -f "$TARGET/.cursor/agents/a.md" ]]
}

@test "cursor_render: models.cursor=<value> emits .cursor/agents override with model frontmatter" {
    mkdir -p "$SRC/agents"
    echo "agent body" > "$SRC/agents/a.md"
    local m
    m=$(merged '{
        "name":"p1",
        "agents":[{"name":"a","description":"d","body_path":"agents/a.md","models":{"cursor":"sonnet-4-5"}}]
    }')
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.claude/agents/a.md" ]]
    [[ -f "$TARGET/.cursor/agents/a.md" ]]
    run cat "$TARGET/.cursor/agents/a.md"
    assert_output_contains "model: sonnet-4-5"
    assert_output_contains "agent body"
}

@test "cursor_render: command with models.cursor=<value> includes model in frontmatter" {
    mkdir -p "$SRC/commands"
    echo "command body" > "$SRC/commands/c.md"
    local m
    m=$(merged '{
        "name":"p1",
        "commands":[{"name":"c","description":"runs","body_path":"commands/c.md","models":{"cursor":"haiku"}}]
    }')
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.cursor/commands/c.md" ]]
    run cat "$TARGET/.cursor/commands/c.md"
    assert_output_contains "description: runs"
    assert_output_contains "model: haiku"
    assert_output_contains "command body"
}

@test "cursor_render: command with models.cursor=inherit omits model frontmatter line" {
    mkdir -p "$SRC/commands"
    echo "command body" > "$SRC/commands/c.md"
    local m
    m=$(merged '{
        "name":"p1",
        "commands":[{"name":"c","description":"runs","body_path":"commands/c.md","models":{"cursor":"inherit"}}]
    }')
    run cursor_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.cursor/commands/c.md" ]]
    run cat "$TARGET/.cursor/commands/c.md"
    assert_output_not_contains "model:"
}

@test "cursor_render: permissions in profile are skipped with warning, no files written" {
    local m
    m=$(merged '{
        "name":"p1",
        "settings":{"permissions_allow":["Bash(cargo:*)"]}
    }')
    run cursor_render "$m" "$TARGET"
    assert_success
    assert_output_contains "permissions are UI-only"
    # No cursor-side permission artefact.
    [[ ! -f "$TARGET/.cursor/permissions.json" ]]
    [[ ! -f "$TARGET/.cursor/settings.json" ]]
}

@test "cursor_render: tracks all written files in _AP_OUT_FILES" {
    mkdir -p "$SRC/agents" "$SRC/commands" "$SRC/skills/sk"
    echo "agent" > "$SRC/agents/a.md"
    echo "cmd"   > "$SRC/commands/c.md"
    echo "skill" > "$SRC/skills/sk/SKILL.md"
    local m
    m=$(merged '{
        "name":"p1",
        "agents":[{"name":"a","description":"","body_path":"agents/a.md"}],
        "commands":[{"name":"c","description":"","body_path":"commands/c.md"}],
        "skills":[{"name":"sk","path":"skills/sk"}]
    }')
    _AP_OUT_FILES=()
    cursor_render "$m" "$TARGET"
    # Verify each artefact is tracked.
    local tracked="${_AP_OUT_FILES[*]}"
    [[ "$tracked" == *".claude/agents/a.md"* ]]
    [[ "$tracked" == *".cursor/commands/c.md"* ]]
    [[ "$tracked" == *".agents/skills/sk"* ]]
}
