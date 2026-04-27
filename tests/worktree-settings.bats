#!/usr/bin/env bats

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
GENERATOR="${DOTFILES_DIR}/claude/worktree-settings.sh"

setup() {
    TMPDIR_TEST="$(mktemp -d "${TMPDIR:-.}/wt-settings.XXXXXX")"
    mkdir -p "${TMPDIR_TEST}/claude/skills/foo" \
             "${TMPDIR_TEST}/claude/skills/bar-baz" \
             "${TMPDIR_TEST}/claude/mcp" \
             "${TMPDIR_TEST}/claude/plugins"
}

teardown() {
    rm -rf "${TMPDIR_TEST}"
}

assert_has_entry() {
    local json="$1" entry="$2"
    jq -e --arg e "$entry" '.permissions.allow | index($e) != null' <<< "$json" >/dev/null || {
        echo "Missing entry: $entry"
        echo "Actual: $(jq -c '.permissions.allow' <<< "$json")"
        return 1
    }
}

assert_no_entry() {
    local json="$1" entry="$2"
    jq -e --arg e "$entry" '.permissions.allow | index($e) == null' <<< "$json" >/dev/null || {
        echo "Unexpected entry: $entry"
        return 1
    }
}

@test "worktree-settings: sandbox enabled with autoAllow" {
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    [[ "$(jq -r '.sandbox.enabled' <<< "$result")" == "true" ]]
    [[ "$(jq -r '.sandbox.autoAllowBashIfSandboxed' <<< "$result")" == "true" ]]
}

@test "worktree-settings: includes static defaults" {
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    assert_has_entry "$result" "Edit"
    assert_has_entry "$result" "Write"
    assert_has_entry "$result" "LSP"
    assert_has_entry "$result" "WebSearch"
    assert_has_entry "$result" "WebFetch"
}

@test "worktree-settings: discovers skills from directories" {
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    assert_has_entry "$result" "Skill(foo)"
    assert_has_entry "$result" "Skill(bar-baz)"
}

@test "worktree-settings: no skill entries when skills dir missing" {
    rm -rf "${TMPDIR_TEST}/claude/skills"
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    count="$(jq '[.permissions.allow[] | select(startswith("Skill("))] | length' <<< "$result")"
    [[ "$count" -eq 0 ]]
}

@test "worktree-settings: discovers MCPs from registry" {
    cat > "${TMPDIR_TEST}/claude/mcp/registry.yaml" <<'YAML'
mcps:
  context7:
    command: npx
    args: [context7-mcp@latest]
    scope: user
  tavily:
    command: npx
    args: [tavily-mcp@latest]
    scope: user
YAML
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    assert_has_entry "$result" "mcp__context7__*"
    assert_has_entry "$result" "mcp__tavily__*"
}

@test "worktree-settings: no MCP entries when registry missing" {
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    count="$(jq '[.permissions.allow[] | select(startswith("mcp__")) | select(startswith("mcp__plugin_") | not) | select(startswith("mcp__claude_ai_") | not)] | length' <<< "$result")"
    [[ "$count" -eq 0 ]]
}

@test "worktree-settings: discovers non-LSP plugins via .mcp.json" {
    # Local plugin with mcpServers wrapper exposing two distinct servers.
    mkdir -p "${TMPDIR_TEST}/plugins/multi-srv"
    cat > "${TMPDIR_TEST}/plugins/multi-srv/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "alpha": {"command": "alpha"},
    "beta":  {"command": "beta"}
  }
}
JSON
    # Local plugin with flat layout (server name = top-level key).
    mkdir -p "${TMPDIR_TEST}/plugins/single-flat"
    cat > "${TMPDIR_TEST}/plugins/single-flat/.mcp.json" <<'JSON'
{
  "single-flat": {"command": "single"}
}
JSON
    cat > "${TMPDIR_TEST}/claude/plugins/registry.yaml" <<YAML
plugins:
  vtsls@claude-code-lsps:
    description: TypeScript LSP
    scope: user
  multi-srv@local:
    description: Multi-server plugin
    scope: user
    path: ${TMPDIR_TEST}/plugins/multi-srv
  single-flat@local:
    description: Flat-layout plugin
    scope: user
    path: ${TMPDIR_TEST}/plugins/single-flat
  no-mcp@claude-plugins-official:
    description: Skill-only plugin (no .mcp.json)
    scope: user
YAML
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    assert_has_entry "$result" "mcp__plugin_multi-srv_alpha__*"
    assert_has_entry "$result" "mcp__plugin_multi-srv_beta__*"
    assert_has_entry "$result" "mcp__plugin_single-flat_single-flat__*"
    # LSP plugins never produce MCP entries.
    assert_no_entry "$result" "mcp__plugin_vtsls_vtsls__*"
    # Skill-only plugins (no .mcp.json) produce no entries.
    assert_no_entry "$result" "mcp__plugin_no-mcp_no-mcp__*"
}

@test "worktree-settings: preserves hyphens in plugin and server names" {
    mkdir -p "${TMPDIR_TEST}/plugins/cheese-flow"
    cat > "${TMPDIR_TEST}/plugins/cheese-flow/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "tilth-edit": {"command": "tilth"}
  }
}
JSON
    cat > "${TMPDIR_TEST}/claude/plugins/registry.yaml" <<YAML
plugins:
  cheese-flow@local:
    description: Hyphenated plugin
    scope: user
    path: ${TMPDIR_TEST}/plugins/cheese-flow
YAML
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    assert_has_entry "$result" "mcp__plugin_cheese-flow_tilth-edit__*"
    # Old (incorrect) hyphen-stripping behavior must not return.
    assert_no_entry "$result" "mcp__plugin_cheese_flow_cheese_flow__*"
}

@test "worktree-settings: pulls claude_ai MCPs from settings.json" {
    cat > "${TMPDIR_TEST}/claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": [
      "Edit",
      "mcp__claude_ai_Gmail__*",
      "mcp__claude_ai_Excalidraw__*",
      "Bash(git:*)"
    ]
  }
}
JSON
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    assert_has_entry "$result" "mcp__claude_ai_Gmail__*"
    assert_has_entry "$result" "mcp__claude_ai_Excalidraw__*"
    # Should NOT pull non-claude_ai entries
    assert_no_entry "$result" "Bash(git:*)"
}

@test "worktree-settings: output is valid JSON" {
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    jq empty <<< "$result"
}

@test "worktree-settings: permissions are sorted" {
    cat > "${TMPDIR_TEST}/claude/mcp/registry.yaml" <<'YAML'
mcps:
  zebra:
    command: zebra-mcp
    scope: user
  alpha:
    command: alpha-mcp
    scope: user
YAML
    result="$(bash "$GENERATOR" "$TMPDIR_TEST")"
    sorted="$(jq -c '.permissions.allow' <<< "$result")"
    resorted="$(jq -c '.permissions.allow | sort' <<< "$result")"
    [[ "$sorted" == "$resorted" ]]
}

@test "worktree-settings: generates from real dotfiles without error" {
    result="$(bash "$GENERATOR" "$DOTFILES_DIR")"
    jq empty <<< "$result"
    count="$(jq '.permissions.allow | length' <<< "$result")"
    # Sanity: real dotfiles should produce at least 20 entries
    (( count >= 20 ))
}

@test "worktree-settings: real output includes known skills" {
    result="$(bash "$GENERATOR" "$DOTFILES_DIR")"
    assert_has_entry "$result" "Skill(scout)"
    assert_has_entry "$result" "Skill(commit)"
    assert_has_entry "$result" "Skill(gh)"
}

@test "worktree-settings: real output includes known MCPs" {
    result="$(bash "$GENERATOR" "$DOTFILES_DIR")"
    # tilth lives in the cheese-flow plugin's .mcp.json (not user-scope).
    assert_has_entry "$result" "mcp__plugin_cheese-flow_tilth__*"
}
