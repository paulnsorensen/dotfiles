#!/usr/bin/env bats
#
# Renderer tests for agent-profile/renderers/{claude,codex,opencode}.sh.
# Each test invokes a renderer with a hand-crafted merged-manifest JSON
# and asserts on the files produced under $TARGET, plus the per-call
# manifest trackers (_AP_OUT_FILES / _AP_AGENTS_MD_FILES).

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
    # shellcheck source=../agent-profile/lib/agents_md.sh
    source "$AP_DIR/lib/agents_md.sh"
    # shellcheck source=../agent-profile/renderers/claude.sh
    source "$AP_DIR/renderers/claude.sh"
    # shellcheck source=../agent-profile/renderers/codex.sh
    source "$AP_DIR/renderers/codex.sh"
    # shellcheck source=../agent-profile/renderers/opencode.sh
    source "$AP_DIR/renderers/opencode.sh"

    TARGET="$TEST_HOME/target"
    SRC="$TEST_HOME/src"
    mkdir -p "$TARGET" "$SRC"

    _AP_OUT_FILES=()
    _AP_AGENTS_MD_FILES=()
}

teardown() {
    teardown_test_env
}

# Build a merged-manifest JSON pointing _source_dir at $SRC, where the
# test can lay down body/script/skill files.
merged() {
    local body="$1"   # JSON fragments to merge in
    jq -n --arg sd "$SRC" --argjson b "$body" '
        {
          name: (.name // "p1"),
          description: "test",
          agents_md_blocks: [],
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

# ─── claude renderer ────────────────────────────────────────────────

@test "claude_render: writes agent with frontmatter" {
    mkdir -p "$SRC/agents"
    echo "Body of agent" > "$SRC/agents/foo.md"
    local m; m=$(merged '{
        "name":"p1",
        "agents":[{"name":"foo","description":"desc","tools":["Read","Grep"],"body_path":"agents/foo.md"}]
    }')
    run claude_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.claude/agents/p1--foo.md" ]]
    run cat "$TARGET/.claude/agents/p1--foo.md"
    assert_output_contains "name: foo"
    assert_output_contains "description: desc"
    assert_output_contains "tools: Read, Grep"
    assert_output_contains "Body of agent"
}

@test "claude_render: copies skill dir as a whole tree" {
    mkdir -p "$SRC/skills/k1"
    echo "skill body" > "$SRC/skills/k1/SKILL.md"
    echo "ref" > "$SRC/skills/k1/reference.md"
    local m; m=$(merged '{"name":"p1","skills":[{"name":"k1","path":"skills/k1"}]}')
    run claude_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.claude/skills/p1--k1/SKILL.md" ]]
    [[ -f "$TARGET/.claude/skills/p1--k1/reference.md" ]]
}

@test "claude_render: hooks become settings.local.json entries with copied script" {
    mkdir -p "$SRC/hooks"
    printf '#!/bin/bash\necho hi\n' > "$SRC/hooks/h.sh"
    chmod +x "$SRC/hooks/h.sh"
    local m; m=$(merged '{
        "name":"p1",
        "hooks":[{"event":"PreToolUse","matcher":"Bash","script":"hooks/h.sh","harnesses":["claude"]}]
    }')
    run claude_render "$m" "$TARGET"
    assert_success
    [[ -x "$TARGET/.claude/hooks/p1--h.sh" ]]
    run cat "$TARGET/.claude/settings.local.json"
    assert_output_contains "PreToolUse"
    assert_output_contains ".claude/hooks/p1--h.sh"
}

@test "claude_render: hooks scoped only to other harnesses are skipped" {
    mkdir -p "$SRC/hooks"
    echo '#!/bin/bash' > "$SRC/hooks/h.sh"
    local m; m=$(merged '{
        "name":"p1",
        "hooks":[{"event":"PreToolUse","matcher":"Bash","script":"hooks/h.sh","harnesses":["codex"]}]
    }')
    run claude_render "$m" "$TARGET"
    assert_success
    [[ ! -f "$TARGET/.claude/hooks/p1--h.sh" ]]
}

@test "claude_render: permissions merged additively into settings.local.json" {
    mkdir -p "$TARGET/.claude"
    echo '{"permissions":{"allow":["Bash(make:*)"]},"other":"keep"}' > "$TARGET/.claude/settings.local.json"
    local m; m=$(merged '{"name":"p1","settings":{"permissions_allow":["Bash(cargo:*)"]}}')
    run claude_render "$m" "$TARGET"
    assert_success
    run cat "$TARGET/.claude/settings.local.json"
    assert_output_contains "Bash(make:*)"
    assert_output_contains "Bash(cargo:*)"
    assert_output_contains "\"other\": \"keep\""
}

@test "claude_render: .mcp.json gets project-scope MCP entries" {
    local m; m=$(merged '{
        "name":"p1",
        "mcps":[{"name":"foo","command":"npx","args":["-y","foo-mcp"],"harnesses":["claude"]}]
    }')
    run claude_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.mcp.json" ]]
    run cat "$TARGET/.mcp.json"
    assert_output_contains "\"foo\""
    assert_output_contains "foo-mcp"
}

@test "claude_render: AGENTS.md block contains profile body" {
    mkdir -p "$SRC"
    local m
    m=$(jq -n --arg sd "$SRC" '{
        name: "p1", description: "", agents_md_blocks: [{name:"p1",content:"## Hi"}],
        mcps:[],agents:[],skills:[],commands:[],hooks:[], settings:{}
    }')
    run claude_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/AGENTS.md" ]]
    run cat "$TARGET/AGENTS.md"
    assert_output_contains "<!-- agent-profile:p1:begin -->"
    assert_output_contains "## Hi"
}

@test "claude_clean: removes our permissions and hooks but keeps user's" {
    mkdir -p "$TARGET/.claude"
    cat > "$TARGET/.claude/settings.local.json" <<'EOF'
{
  "permissions": {"allow": ["Bash(cargo:*)", "Bash(make:*)"]},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type":"command","command":".claude/hooks/p1--x.sh"}]},
      {"matcher": "Bash", "hooks": [{"type":"command","command":".claude/hooks/userhook.sh"}]}
    ]
  },
  "myKey": "preserved"
}
EOF
    local m; m=$(merged '{"name":"p1","settings":{"permissions_allow":["Bash(cargo:*)"]}}')
    run claude_clean "$m" "$TARGET"
    assert_success
    run cat "$TARGET/.claude/settings.local.json"
    assert_output_contains "Bash(make:*)"
    assert_output_not_contains "Bash(cargo:*)"
    assert_output_contains "userhook.sh"
    assert_output_not_contains "p1--x.sh"
    assert_output_contains "\"myKey\": \"preserved\""
}

@test "claude_clean: removes our mcp entries from .mcp.json by name" {
    cat > "$TARGET/.mcp.json" <<'EOF'
{"mcpServers": {"foo": {"command":"x"}, "user-mcp": {"command":"y"}}}
EOF
    local m; m=$(merged '{"name":"p1","mcps":[{"name":"foo","command":"x","harnesses":["claude"]}]}')
    run claude_clean "$m" "$TARGET"
    assert_success
    run cat "$TARGET/.mcp.json"
    assert_output_not_contains "\"foo\""
    assert_output_contains "user-mcp"
}

# ─── codex renderer ─────────────────────────────────────────────────

@test "codex_render: writes only AGENTS.md block (no agents/skills/hook files)" {
    local m
    m=$(jq -n --arg sd "$SRC" '{
        name:"p1", description:"", agents_md_blocks:[{name:"p1",content:"hello"}],
        mcps:[], agents:[], skills:[], commands:[], hooks:[], settings:{}
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/AGENTS.md" ]]
    [[ ! -d "$TARGET/.claude" ]]
    [[ ! -d "$TARGET/.opencode" ]]
}

@test "codex_render: inline agent gets folded into AGENTS.md block" {
    mkdir -p "$SRC/agents"
    echo "INLINE AGENT BODY" > "$SRC/agents/x.md"
    local m
    m=$(jq -n --arg sd "$SRC" '{
        name:"p1", description:"", agents_md_blocks:[{name:"p1",content:"top"}],
        mcps:[], skills:[], commands:[], hooks:[], settings:{},
        agents:[{name:"x",description:"d",body_path:"agents/x.md",fallback:"inline",_source_dir:$sd}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    run cat "$TARGET/AGENTS.md"
    assert_output_contains "INLINE AGENT BODY"
    assert_output_contains "Agent: x"
}

@test "codex_render: warns and skips slash commands" {
    local m
    m=$(jq -n --arg sd "$SRC" '{
        name:"p1", description:"", agents_md_blocks:[],
        mcps:[], agents:[], skills:[], hooks:[], settings:{},
        commands:[{name:"c",description:"d",body_path:"",_source_dir:$sd}]
    }')
    run codex_render "$m" "$TARGET"
    assert_success
    assert_output_contains "slash commands not supported"
    [[ ! -d "$TARGET/.codex" ]]
}

# ─── opencode renderer ──────────────────────────────────────────────

@test "opencode_render: writes agent under .opencode/agent/" {
    mkdir -p "$SRC/agents"
    echo "OC AGENT BODY" > "$SRC/agents/y.md"
    local m
    m=$(jq -n --arg sd "$SRC" '{
        name:"p1", description:"", agents_md_blocks:[],
        mcps:[], skills:[], commands:[], hooks:[], settings:{},
        agents:[{name:"y",description:"d",body_path:"agents/y.md",_source_dir:$sd}]
    }')
    run opencode_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/.opencode/agent/p1--y.md" ]]
    run cat "$TARGET/.opencode/agent/p1--y.md"
    assert_output_contains "mode: subagent"
    assert_output_contains "OC AGENT BODY"
}

@test "opencode_render: translates Bash(cmd:*) permissions to opencode shell patterns" {
    local m
    m=$(jq -n --arg sd "$SRC" '{
        name:"p1", description:"", agents_md_blocks:[],
        mcps:[], agents:[], skills:[], commands:[], hooks:[],
        settings:{permissions_allow:["Bash(cargo:*)","Bash(go test:*)"]}
    }')
    run opencode_render "$m" "$TARGET"
    assert_success
    [[ -f "$TARGET/opencode.json" ]]
    run cat "$TARGET/opencode.json"
    assert_output_contains "cargo *"
    assert_output_contains "go test *"
    assert_output_not_contains "Bash(cargo"
}

@test "opencode_render: mcp entries land as type: local with command array" {
    local m
    m=$(jq -n --arg sd "$SRC" '{
        name:"p1", description:"", agents_md_blocks:[],
        agents:[], skills:[], commands:[], hooks:[], settings:{},
        mcps:[{name:"foo",command:"npx",args:["-y","foo-mcp"],harnesses:["opencode"]}]
    }')
    run opencode_render "$m" "$TARGET"
    assert_success
    run cat "$TARGET/opencode.json"
    assert_output_contains "\"foo\""
    assert_output_contains "\"type\": \"local\""
    assert_output_contains "npx"
    assert_output_contains "foo-mcp"
}

@test "opencode_clean: preserves user mcp/permission entries" {
    cat > "$TARGET/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-sonnet-4-5",
  "mcp": {"foo": {"type":"local","command":["x"]}, "user-mcp": {"type":"local","command":["y"]}},
  "permission": {"bash": {"cargo *": "allow", "npm *": "allow"}}
}
EOF
    local m
    m=$(jq -n --arg sd "$SRC" '{
        name:"p1", description:"", agents_md_blocks:[],
        agents:[], skills:[], commands:[], hooks:[],
        mcps:[{name:"foo",command:"x",harnesses:["opencode"]}],
        settings:{permissions_allow:["Bash(cargo:*)"]}
    }')
    run opencode_clean "$m" "$TARGET"
    assert_success
    run cat "$TARGET/opencode.json"
    assert_output_contains "user-mcp"
    assert_output_not_contains "\"foo\""
    assert_output_contains "npm *"
    assert_output_not_contains "cargo *"
    assert_output_contains "claude-sonnet"
}
