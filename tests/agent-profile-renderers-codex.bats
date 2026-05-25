#!/usr/bin/env bats
#
# Codex renderer — verifies the post-reshape native-paths behaviour:
#   .codex/agents/<n>.toml         (subagents, TOML)
#   .agents/skills/<n>/            (cross-harness shared skill dir)
#   .codex/hooks.json              (only when a hook is codex-harnessed)
#   .codex/config.toml             ([mcp_servers] when MCP is codex-harnessed)
#   commands: skipped with warning (deprecated on Codex)
#   AGENTS.md: never touched
#
# The canonical install target is the `rust` profile at $DOTFILES_DIR/profiles/rust.

load test_helper

setup() {
    setup_test_env

    AP_DIR="$REAL_DOTFILES_DIR/agent-profile"
    # shellcheck source=../agent-profile/lib/parse.sh
    source "$AP_DIR/lib/parse.sh"
    # shellcheck source=../agent-profile/lib/discover.sh
    source "$AP_DIR/lib/discover.sh"
    # shellcheck source=../agent-profile/lib/manifest.sh
    source "$AP_DIR/lib/manifest.sh"
    # shellcheck source=../agent-profile/lib/shared_writer.sh
    source "$AP_DIR/lib/shared_writer.sh"
    # shellcheck source=../agent-profile/renderers/codex.sh
    source "$AP_DIR/renderers/codex.sh"

    TARGET="$TEST_HOME/target"
    SRC="$TEST_HOME/src"
    mkdir -p "$TARGET" "$SRC"

    _AP_OUT_FILES=()
}

teardown() {
    teardown_test_env
}

# Build a merged-manifest JSON with _source_dir = $SRC.
merged() {
    local body="$1"
    jq -n --arg sd "$SRC" --argjson b "$body" '
        {
          name: "p1",
          description: "test",
          mcps: [], agents: [], skills: [],
          commands: [], hooks: [],
          settings: {}
        } * $b
        | .mcps     |= map(. + {_source_dir: $sd})
        | .agents   |= map(. + {_source_dir: $sd})
        | .skills   |= map(. + {_source_dir: $sd})
        | .commands |= map(. + {_source_dir: $sd})
        | .hooks    |= map(. + {_source_dir: $sd})
    '
}

# ─── unit-level renderer tests ─────────────────────────────────────────

@test "codex_render: writes subagent at .codex/agents/<n>.toml with TOML fields" {
    mkdir -p "$SRC/agents"
    cat > "$SRC/agents/reviewer.md" <<'EOF'
Review code for issues.
Be terse.
EOF
    local m; m=$(merged '{
        "agents":[{
            "name":"reviewer",
            "description":"Reviews code.",
            "body_path":"agents/reviewer.md"
        }]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.codex/agents/reviewer.toml" ]]
    run cat "$TARGET/.codex/agents/reviewer.toml"
    assert_output_contains 'name = "reviewer"'
    assert_output_contains 'description = "Reviews code."'
    assert_output_contains 'developer_instructions = """'
    assert_output_contains 'Review code for issues.'
}

@test "codex_render: subagent TOML round-trips through yq" {
    mkdir -p "$SRC/agents"
    printf 'A "quoted" body with backslash \\\\ and newline\n' > "$SRC/agents/r.md"
    local m; m=$(merged '{
        "agents":[{"name":"r","description":"d","body_path":"agents/r.md"}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    run yq -p=toml -o=json '.' "$TARGET/.codex/agents/r.toml"
    assert_success
    assert_output_contains '"name": "r"'
    assert_output_contains '"description": "d"'
}

@test "codex_render: subagent gets model field when models.codex is set" {
    mkdir -p "$SRC/agents"
    echo "body" > "$SRC/agents/r.md"
    local m; m=$(merged '{
        "agents":[{"name":"r","description":"d","body_path":"agents/r.md","models":{"codex":"gpt-5"}}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    run cat "$TARGET/.codex/agents/r.toml"
    assert_output_contains 'model = "gpt-5"'
}

@test "codex_render: no model field when models.codex absent" {
    mkdir -p "$SRC/agents"
    echo "body" > "$SRC/agents/r.md"
    local m; m=$(merged '{
        "agents":[{"name":"r","description":"d","body_path":"agents/r.md","models":{"claude":"opus"}}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    run cat "$TARGET/.codex/agents/r.toml"
    assert_output_not_contains "model ="
}

@test "codex_render: skill copies tree to shared .agents/skills/<n>/" {
    mkdir -p "$SRC/skills/k1"
    echo "skill body" > "$SRC/skills/k1/SKILL.md"
    echo "ref" > "$SRC/skills/k1/reference.md"
    local m; m=$(merged '{"skills":[{"name":"k1","path":"skills/k1"}]}')
    run codex_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.agents/skills/k1/SKILL.md" ]]
    [[ -f "$TARGET/.agents/skills/k1/reference.md" ]]
    # Verify NOT written to any codex-only skill path.
    [[ ! -d "$TARGET/.codex/skills" ]]
}

@test "codex_render: hook with harnesses [codex] writes .codex/hooks.json + copied script" {
    mkdir -p "$SRC/hooks"
    printf '#!/bin/bash\necho hi\n' > "$SRC/hooks/h.sh"
    chmod +x "$SRC/hooks/h.sh"
    local m; m=$(merged '{
        "hooks":[{
            "event":"PreToolUse",
            "matcher":"Bash",
            "script":"hooks/h.sh",
            "harnesses":["codex"]
        }]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.codex/hooks.json" ]]
    [[ -x "$TARGET/.codex/hooks/h.sh" ]]
    run cat "$TARGET/.codex/hooks.json"
    assert_output_contains "PreToolUse"
    assert_output_contains ".codex/hooks/h.sh"
}

@test "codex_render: hook with harnesses [claude] does NOT write .codex/hooks.json" {
    mkdir -p "$SRC/hooks"
    echo '#!/bin/bash' > "$SRC/hooks/h.sh"
    local m; m=$(merged '{
        "hooks":[{
            "event":"PreToolUse",
            "matcher":"Bash",
            "script":"hooks/h.sh",
            "harnesses":["claude"]
        }]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    [[ ! -f "$TARGET/.codex/hooks.json" ]]
    [[ ! -d "$TARGET/.codex/hooks" ]]
}

@test "codex_render: MCP with harnesses [codex] merges into .codex/config.toml [mcp_servers]" {
    local m; m=$(merged '{
        "mcps":[{"name":"foo","command":"npx","args":["-y","foo-mcp"],"harnesses":["codex"]}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.codex/config.toml" ]]
    run yq -p=toml -o=json '.mcp_servers.foo' "$TARGET/.codex/config.toml"
    assert_success
    assert_output_contains '"command": "npx"'
    assert_output_contains 'foo-mcp'
}

@test "codex_render: MCP scoped only to claude is NOT written to .codex/config.toml" {
    local m; m=$(merged '{
        "mcps":[{"name":"foo","command":"x","harnesses":["claude"]}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    [[ ! -f "$TARGET/.codex/config.toml" ]]
}

@test "codex_render: MCP merge preserves pre-existing keys in .codex/config.toml" {
    mkdir -p "$TARGET/.codex"
    cat > "$TARGET/.codex/config.toml" <<'EOF'
approval_policy = "untrusted"
sandbox_mode = "workspace-write"

[mcp_servers.user-tool]
command = "user-cmd"
EOF
    local m; m=$(merged '{
        "mcps":[{"name":"foo","command":"npx","args":["-y","foo-mcp"],"harnesses":["codex"]}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    run yq -p=toml '.' "$TARGET/.codex/config.toml"
    assert_output_contains "approval_policy"
    assert_output_contains "user-tool"
    assert_output_contains "foo"
    assert_output_contains "foo-mcp"
}

@test "codex_render: slash commands are skipped with warning, no .codex/commands written" {
    mkdir -p "$SRC/commands"
    echo "body" > "$SRC/commands/c.md"
    local m; m=$(merged '{
        "commands":[{"name":"c","description":"d","body_path":"commands/c.md"}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    assert_output_contains "skipping command 'c'"
    assert_output_contains "deprecated"
    [[ ! -d "$TARGET/.codex/commands" ]]
}

@test "codex_render: never writes AGENTS.md" {
    mkdir -p "$SRC/agents" "$SRC/skills/k1"
    echo "body" > "$SRC/agents/r.md"
    echo "skill" > "$SRC/skills/k1/SKILL.md"
    local m; m=$(merged '{
        "agents":[{"name":"r","description":"d","body_path":"agents/r.md"}],
        "skills":[{"name":"k1","path":"skills/k1"}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    [[ ! -f "$TARGET/AGENTS.md" ]]
}

# ─── _AP_OUT_FILES tracking ────────────────────────────────────────────

@test "codex_render: _AP_OUT_FILES tracks the agent TOML and skill dir" {
    mkdir -p "$SRC/agents" "$SRC/skills/k1"
    echo "body" > "$SRC/agents/r.md"
    echo "skill" > "$SRC/skills/k1/SKILL.md"
    local m; m=$(merged '{
        "agents":[{"name":"r","description":"d","body_path":"agents/r.md"}],
        "skills":[{"name":"k1","path":"skills/k1"}]
    }')
    codex_render "$m" "$TARGET"
    local tracked="${_AP_OUT_FILES[*]}"
    [[ "$tracked" == *".codex/agents/r.toml"* ]]
    [[ "$tracked" == *".agents/skills/k1"* ]]
}

# ─── codex_clean ───────────────────────────────────────────────────────

@test "codex_clean: removes our [mcp_servers] entries but keeps user's" {
    mkdir -p "$TARGET/.codex"
    cat > "$TARGET/.codex/config.toml" <<'EOF'
approval_policy = "untrusted"

[mcp_servers.foo]
command = "npx"

[mcp_servers.user-tool]
command = "user-cmd"
EOF
    local m; m=$(merged '{
        "mcps":[{"name":"foo","command":"npx","harnesses":["codex"]}]
    }')
    run codex_clean "$m" "$TARGET"
    assert_success
    run cat "$TARGET/.codex/config.toml"
    assert_output_contains "user-tool"
    assert_output_contains "approval_policy"
    assert_output_not_contains 'mcp_servers.foo]'
}

@test "codex_clean: missing config.toml is a no-op" {
    local m; m=$(merged '{"mcps":[{"name":"foo","command":"x","harnesses":["codex"]}]}')
    run codex_clean "$m" "$TARGET"
    assert_success
    [[ ! -f "$TARGET/.codex/config.toml" ]]
}

# ─── end-to-end against the canonical rust profile ─────────────────────

@test "end-to-end: dots profile install rust --harness codex produces expected artifacts" {
    mkdir -p "$TARGET"
    run env DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash "$REAL_DOTFILES_DIR/agent-profile/ap" \
            install rust --harness codex --target "$TARGET"
    assert_success
    [[ -f "$TARGET/.codex/agents/rust-reviewer.toml" ]]
    [[ -f "$TARGET/.agents/skills/cargo-workflow/SKILL.md" ]]
    # The rust profile's cargo-check hook is harnesses: [claude].
    [[ ! -f "$TARGET/.codex/hooks.json" ]]
    [[ ! -d "$TARGET/.codex/hooks" ]]
    # AGENTS.md must never appear.
    [[ ! -f "$TARGET/AGENTS.md" ]]
    # No MCPs in the rust profile.
    [[ ! -f "$TARGET/.codex/config.toml" ]]
}

@test "end-to-end: uninstall rust --harness codex removes all written files" {
    mkdir -p "$TARGET"
    env DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash "$REAL_DOTFILES_DIR/agent-profile/ap" \
            install rust --harness codex --target "$TARGET"
    [[ -f "$TARGET/.codex/agents/rust-reviewer.toml" ]]

    run env DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        bash "$REAL_DOTFILES_DIR/agent-profile/ap" \
            uninstall rust --harness codex --target "$TARGET"
    assert_success
    [[ ! -f "$TARGET/.codex/agents/rust-reviewer.toml" ]]
    [[ ! -d "$TARGET/.agents/skills/cargo-workflow" ]]
}

# ─── bash 3.2 compatibility regression ─────────────────────────────────

@test "bash 3.2: renderer runs under /bin/bash without local -n / declare -A" {
    [[ -x /bin/bash ]] || skip "/bin/bash not available"
    mkdir -p "$TARGET"
    run /bin/bash -c "
        DOTFILES_DIR='$REAL_DOTFILES_DIR' \
        /bin/bash '$REAL_DOTFILES_DIR/agent-profile/ap' \
            install rust --harness codex --target '$TARGET'
    "
    assert_success
    [[ -f "$TARGET/.codex/agents/rust-reviewer.toml" ]]
    [[ -f "$TARGET/.agents/skills/cargo-workflow/SKILL.md" ]]
    # Sanity: no 'local -n' error in output.
    assert_output_not_contains "local -n"
    assert_output_not_contains "declare -A"
    assert_output_not_contains "nameref"
}

@test "bash 3.2: report the bash version we tested under" {
    [[ -x /bin/bash ]] || skip "/bin/bash not available"
    run /bin/bash -c 'echo "$BASH_VERSION"'
    assert_success
    # macOS ships 3.2.x as the default; if a newer one is in /bin/bash,
    # the compatibility test still passes — this is informational.
    [[ -n "$output" ]]
}
