#!/usr/bin/env bats
#
# Renderer tests for agent-profile/renderers/copilot.sh.
#
# Pattern: source parse.sh + shared_writer.sh + copilot.sh, drive
# `copilot_render` directly with either a hand-crafted merged-manifest
# JSON or the real rust-profile manifest. The `ap` dispatch wiring
# (W1) wires `copilot` into `ALL_HARNESSES`; until then these tests
# exercise the renderer function directly.

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
    # shellcheck source=../agent-profile/renderers/copilot.sh
    source "$AP_DIR/renderers/copilot.sh"

    TARGET="$TEST_HOME/target"
    SRC="$TEST_HOME/src"
    mkdir -p "$TARGET" "$SRC"

    _AP_OUT_FILES=()
}

teardown() {
    teardown_test_env
}

# Build a merged-manifest JSON pointing _source_dir at $SRC.
merged() {
    local body="$1"
    jq -n --arg sd "$SRC" --argjson b "$body" '
        {
          name: "p1", description: "test",
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

# ─── rust profile (acceptance criterion) ────────────────────────────

@test "copilot_render: rust profile produces .github/agents and .github/skills, no MCP file, no AGENTS.md" {
    local m
    m=$(DOTFILES_DIR="$REAL_DOTFILES_DIR" ap_parse_manifest "$REAL_DOTFILES_DIR/profiles/rust")
    run copilot_render "$m" "$TARGET"
    assert_success

    [[ -f "$TARGET/.github/agents/rust-reviewer.agent.md" ]] || { echo "missing agent file" >&2; return 1; }
    [[ -f "$TARGET/.github/skills/cargo-workflow/SKILL.md" ]] || { echo "missing skill file" >&2; return 1; }

    # The rust profile's cargo-check hook is harnesses:[claude] only —
    # copilot must skip it.
    [[ ! -f "$TARGET/.github/hooks/cargo-check.json" ]] || { echo "hook leaked to copilot" >&2; return 1; }

    # The rust profile has no copilot-harnessed MCPs, so no file written.
    [[ ! -f "$TARGET/.copilot/mcp-config.json" ]] || { echo "unexpected mcp-config.json" >&2; return 1; }

    # AGENTS.md is never touched by copilot.
    [[ ! -f "$TARGET/AGENTS.md" ]] || { echo "AGENTS.md leaked" >&2; return 1; }

    # Commands are skipped — `clippy` should warn but not write a file.
    [[ ! -f "$TARGET/.github/commands/clippy.md" ]] || { echo "command leaked" >&2; return 1; }
}

@test "copilot_render: rust agent file contains expected frontmatter + body" {
    local m
    m=$(DOTFILES_DIR="$REAL_DOTFILES_DIR" ap_parse_manifest "$REAL_DOTFILES_DIR/profiles/rust")
    run copilot_render "$m" "$TARGET"
    assert_success

    run cat "$TARGET/.github/agents/rust-reviewer.agent.md"
    assert_output_contains "name: rust-reviewer"
    assert_output_contains "description: Reviews Rust code"
    assert_output_contains "tools: [Read, Grep, Glob, Bash]"
    # Body content from agents/rust-reviewer.md should be present.
    assert_output_contains "idiomatic style"
}

# ─── MCP rendering with mandatory tools: ["*"] ──────────────────────

@test "copilot_render: copilot-harnessed MCP yields mcp-config.json with tools: [\"*\"]" {
    local m
    m=$(merged '{
        "name":"p1",
        "mcps":[{"name":"foo","command":"npx","args":["-y","foo-mcp"],"harnesses":["copilot"]}]
    }')
    run copilot_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.copilot/mcp-config.json" ]] || { echo "missing mcp-config.json" >&2; return 1; }
    run cat "$TARGET/.copilot/mcp-config.json"
    assert_output_contains "\"foo\""
    assert_output_contains "\"command\": \"npx\""
    assert_output_contains "foo-mcp"
    assert_output_contains "\"tools\""
    assert_output_contains "\"*\""
}

@test "copilot_render: MCP harnessed to claude only is excluded" {
    local m
    m=$(merged '{
        "name":"p1",
        "mcps":[{"name":"foo","command":"x","harnesses":["claude"]}]
    }')
    run copilot_render "$m" "$TARGET"
    assert_success
    [[ ! -f "$TARGET/.copilot/mcp-config.json" ]] || { echo "MCP leaked across harnesses" >&2; return 1; }
}

# ─── hooks: 13-event surface, one file per copilot-harnessed hook ────

@test "copilot_render: copilot-harnessed hook gets .github/hooks/<n>.json + script copy" {
    mkdir -p "$SRC/hooks"
    printf '#!/bin/bash\necho hi\n' > "$SRC/hooks/h.sh"
    local m
    m=$(merged '{
        "name":"p1",
        "hooks":[{"event":"PreToolUse","matcher":"Bash","script":"hooks/h.sh","harnesses":["copilot"]}]
    }')
    run copilot_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.github/hooks/h.json" ]] || { echo "missing hook json" >&2; return 1; }
    [[ -f "$TARGET/.github/hooks/h.sh" ]] || { echo "missing hook script" >&2; return 1; }
    run cat "$TARGET/.github/hooks/h.json"
    assert_output_contains "\"event\""
    assert_output_contains "PreToolUse"
    assert_output_contains ".github/hooks/h.sh"
}

@test "copilot_render: hook harnessed only to claude is skipped" {
    mkdir -p "$SRC/hooks"
    echo '#!/bin/bash' > "$SRC/hooks/h.sh"
    local m
    m=$(merged '{
        "name":"p1",
        "hooks":[{"event":"PreToolUse","matcher":"Bash","script":"hooks/h.sh","harnesses":["claude"]}]
    }')
    run copilot_render "$m" "$TARGET"
    assert_success
    [[ ! -f "$TARGET/.github/hooks/h.json" ]] || { echo "hook leaked across harnesses" >&2; return 1; }
}

# ─── models.copilot is ignored (Copilot strips model field) ──────────

@test "copilot_render: models.copilot logs a warning and is stripped from frontmatter" {
    mkdir -p "$SRC/agents"
    echo "BODY" > "$SRC/agents/x.md"
    local m
    m=$(merged '{
        "name":"p1",
        "agents":[{"name":"x","description":"d","body_path":"agents/x.md","models":{"copilot":"gpt-5"}}]
    }')
    run copilot_render "$m" "$TARGET"
    assert_success
    assert_output_contains "Copilot ignores model field"

    run cat "$TARGET/.github/agents/x.agent.md"
    assert_output_contains "name: x"
    # `model:` must NOT appear in frontmatter — we strip the whole models map.
    assert_output_not_contains "model: gpt-5"
    assert_output_not_contains "models:"
    assert_output_contains "BODY"
}

# ─── commands and permissions are skipped ────────────────────────────

@test "copilot_render: commands are skipped with a warning" {
    mkdir -p "$SRC/commands"
    echo "cmd body" > "$SRC/commands/c.md"
    local m
    m=$(merged '{
        "name":"p1",
        "commands":[{"name":"c","description":"d","body_path":"commands/c.md"}]
    }')
    run copilot_render "$m" "$TARGET"
    assert_success
    assert_output_contains "skipping command 'c'"
    [[ ! -d "$TARGET/.github/commands" ]] || { echo "command dir leaked" >&2; return 1; }
}

# ─── _AP_OUT_FILES tracking ──────────────────────────────────────────

@test "copilot_render: tracks every whole-file artefact in _AP_OUT_FILES" {
    mkdir -p "$SRC/agents" "$SRC/skills/k1"
    echo "BODY" > "$SRC/agents/a.md"
    echo "skill" > "$SRC/skills/k1/SKILL.md"
    local m
    m=$(merged '{
        "name":"p1",
        "agents":[{"name":"a","body_path":"agents/a.md"}],
        "skills":[{"name":"k1","path":"skills/k1"}]
    }')
    # Direct call (no `run`) so _AP_OUT_FILES is observable in this shell.
    _AP_OUT_FILES=()
    copilot_render "$m" "$TARGET"

    local joined; joined="${_AP_OUT_FILES[*]}"
    [[ "$joined" == *".github/agents/a.agent.md"* ]] || { echo "agent not tracked: $joined" >&2; return 1; }
    [[ "$joined" == *".github/skills/k1"* ]] || { echo "skill not tracked: $joined" >&2; return 1; }
}

# ─── copilot_clean: surgical MCP entry removal ───────────────────────

@test "copilot_clean: removes our mcp entries but preserves user entries" {
    mkdir -p "$TARGET/.copilot"
    cat > "$TARGET/.copilot/mcp-config.json" <<'EOF'
{"mcpServers": {"foo": {"command": "x", "tools": ["*"]}, "user-mcp": {"command": "y", "tools": ["*"]}}}
EOF
    local m
    m=$(merged '{
        "name":"p1",
        "mcps":[{"name":"foo","command":"x","harnesses":["copilot"]}]
    }')
    run copilot_clean "$m" "$TARGET"
    assert_success
    run cat "$TARGET/.copilot/mcp-config.json"
    assert_output_not_contains "\"foo\""
    assert_output_contains "user-mcp"
}
