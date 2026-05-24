#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2016,SC2034,SC2317
#
# Tests for the Cursor harness:
#   1. chezmoi/lib/install-cursor-plugin.sh — deploys a plugin folder
#      into ~/.cursor/{skills,rules,commands,hooks}/ and merges
#      hooks.json / modes.json. Idempotent, preserves user content,
#      drops items the plugin no longer ships.
#   2. agents/mcp/lib.sh cursor backend — jq-edits ~/.cursor/mcp.json
#      (mcpServers schema). Add/list/remove/signature round-trip.
#
# CURSOR_CONFIG points the MCP backend at a scratch file; CURSOR_HOME
# is forwarded to the installer.

load test_helper

INSTALL_SCRIPT="$REAL_DOTFILES_DIR/chezmoi/lib/install-cursor-plugin.sh"
PLUGIN_SRC="$REAL_DOTFILES_DIR/cursor/plugins/local/cheese-grok"

setup() {
    setup_test_env
    export CURSOR_HOME="$TEST_HOME/.cursor"
    export CURSOR_CONFIG="$TEST_HOME/.cursor/mcp.json"
    mkdir -p "$CURSOR_HOME"

    # Sourced helpers for the MCP backend tests.
    # shellcheck source=../claude/lib/sync-common.sh
    source "$REAL_DOTFILES_DIR/claude/lib/sync-common.sh"
    # shellcheck source=../agents/mcp/lib.sh
    source "$REAL_DOTFILES_DIR/agents/mcp/lib.sh"
}

teardown() {
    teardown_test_env
}

# ─── install-cursor-plugin.sh ───────────────────────────────────────────

@test "install-cursor-plugin: missing source dir exits non-zero" {
    run "$INSTALL_SCRIPT" "$TEST_HOME/nope" "$CURSOR_HOME"
    [[ "$status" -eq 1 ]]
}

@test "install-cursor-plugin: wrong arg count exits 2" {
    run "$INSTALL_SCRIPT"
    [[ "$status" -eq 2 ]]
}

@test "install-cursor-plugin: missing plugin.json exits non-zero" {
    mkdir -p "$TEST_HOME/empty-plugin"
    run "$INSTALL_SCRIPT" "$TEST_HOME/empty-plugin" "$CURSOR_HOME"
    [[ "$status" -eq 1 ]]
    assert_output_contains "plugin.json"
}

@test "install-cursor-plugin: deploys skills/rules/commands/hooks tree" {
    run "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$CURSOR_HOME"
    assert_success

    # Skills land as real directories with SKILL.md inside.
    [[ -f "$CURSOR_HOME/skills/grok-codebase/SKILL.md" ]]
    [[ -f "$CURSOR_HOME/skills/design-doc/SKILL.md" ]]
    [[ -f "$CURSOR_HOME/skills/read-mode-probe/SKILL.md" ]]

    # Rules + commands land as files.
    [[ -f "$CURSOR_HOME/rules/reader-companion.mdc" ]]
    [[ -f "$CURSOR_HOME/commands/hostile-editor.md" ]]
    [[ -f "$CURSOR_HOME/commands/mental-model.md" ]]
    [[ -f "$CURSOR_HOME/commands/reading-probes.md" ]]
    [[ -f "$CURSOR_HOME/commands/tighten.md" ]]

    # Hook scripts are executable.
    [[ -x "$CURSOR_HOME/hooks/block-destructive.sh" ]]
    [[ -x "$CURSOR_HOME/hooks/session-summary.sh" ]]

    # Per-collection manifests stamped with the plugin name.
    grep -Fxq grok-codebase "$CURSOR_HOME/skills/.dotfiles-managed-cheese-grok"
    grep -Fxq reader-companion.mdc "$CURSOR_HOME/rules/.dotfiles-managed-cheese-grok"
}

@test "install-cursor-plugin: merges hooks.json with deployed absolute paths" {
    "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$CURSOR_HOME"

    run jq -r '.hooks.beforeShellExecution | length' "$CURSOR_HOME/hooks.json"
    assert_output_contains "1"
    run jq -r '.hooks.stop | length' "$CURSOR_HOME/hooks.json"
    assert_output_contains "1"

    # Command paths rewritten from "./hooks/..." to the absolute deployed path.
    run jq -r '.hooks.beforeShellExecution[0].command' "$CURSOR_HOME/hooks.json"
    assert_output_contains "$CURSOR_HOME/hooks/block-destructive.sh"

    # Every entry tagged with the plugin name for ownership tracking.
    run jq -r '.hooks.beforeShellExecution[0]._plugin' "$CURSOR_HOME/hooks.json"
    assert_output_contains "cheese-grok"
}

@test "install-cursor-plugin: merges modes.json under .modes.<name>" {
    "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$CURSOR_HOME"

    run jq -r '.modes.reader.name' "$CURSOR_HOME/modes.json"
    assert_output_contains "reader"
    run jq -r '.modes.reader._plugin' "$CURSOR_HOME/modes.json"
    assert_output_contains "cheese-grok"
}

@test "install-cursor-plugin: idempotent — re-running produces identical artifacts" {
    "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$CURSOR_HOME" >/dev/null
    local before
    before=$(find "$CURSOR_HOME" -type f -name '*.json' -o -name 'SKILL.md' \
              -o -name '*.mdc' -o -name '*.md' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256)
    "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$CURSOR_HOME" >/dev/null
    local after
    after=$(find "$CURSOR_HOME" -type f -name '*.json' -o -name 'SKILL.md' \
              -o -name '*.mdc' -o -name '*.md' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256)
    [[ "$before" == "$after" ]]
}

@test "install-cursor-plugin: preserves user-authored content at every target" {
    # Pre-seed each target dir with user content.
    mkdir -p "$CURSOR_HOME/skills/user-skill" "$CURSOR_HOME/rules" "$CURSOR_HOME/commands"
    printf '# user skill\n' > "$CURSOR_HOME/skills/user-skill/SKILL.md"
    printf '# user rule\n'  > "$CURSOR_HOME/rules/user.mdc"
    printf '# user cmd\n'   > "$CURSOR_HOME/commands/user.md"
    printf '{"modes": {"user-mode": {"name":"user-mode"}}}\n' > "$CURSOR_HOME/modes.json"
    printf '{"version":1,"hooks":{"sessionStart":[{"command":"/usr/bin/true"}]}}\n' > "$CURSOR_HOME/hooks.json"

    "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$CURSOR_HOME" >/dev/null

    # User content untouched.
    [[ -f "$CURSOR_HOME/skills/user-skill/SKILL.md" ]]
    [[ -f "$CURSOR_HOME/rules/user.mdc" ]]
    [[ -f "$CURSOR_HOME/commands/user.md" ]]

    run jq -r '.modes."user-mode".name' "$CURSOR_HOME/modes.json"
    assert_output_contains "user-mode"
    run jq -r '.hooks.sessionStart[0].command' "$CURSOR_HOME/hooks.json"
    assert_output_contains "/usr/bin/true"

    # Plugin content present.
    [[ -f "$CURSOR_HOME/skills/grok-codebase/SKILL.md" ]]
    run jq -r '.modes.reader.name' "$CURSOR_HOME/modes.json"
    assert_output_contains "reader"
}

@test "install-cursor-plugin: drops items removed from plugin source on re-run" {
    # Scratch plugin we can mutate.
    local scratch="$TEST_HOME/scratch-plugin"
    cp -R "$PLUGIN_SRC" "$scratch"

    "$INSTALL_SCRIPT" "$scratch" "$CURSOR_HOME" >/dev/null
    [[ -f "$CURSOR_HOME/commands/tighten.md" ]]

    # Remove a command from the plugin source.
    rm "$scratch/commands/tighten.md"

    "$INSTALL_SCRIPT" "$scratch" "$CURSOR_HOME" >/dev/null

    # Dropped command is gone from the target.
    [[ ! -e "$CURSOR_HOME/commands/tighten.md" ]]
    # Other commands still present.
    [[ -f "$CURSOR_HOME/commands/reading-probes.md" ]]
}

@test "install-cursor-plugin: drops mode dropped from plugin source on re-run" {
    local scratch="$TEST_HOME/scratch-plugin"
    cp -R "$PLUGIN_SRC" "$scratch"

    "$INSTALL_SCRIPT" "$scratch" "$CURSOR_HOME" >/dev/null
    run jq -r '.modes.reader.name' "$CURSOR_HOME/modes.json"
    assert_output_contains "reader"

    # Remove all modes from the plugin source.
    rm -rf "$scratch/modes"

    "$INSTALL_SCRIPT" "$scratch" "$CURSOR_HOME" >/dev/null
    run jq -r '.modes.reader // "absent"' "$CURSOR_HOME/modes.json"
    assert_output_contains "absent"
}

# ─── agents/mcp/lib.sh cursor backend ───────────────────────────────────

@test "mcp_cursor_ensure_config seeds a minimal mcpServers file" {
    [[ ! -e "$CURSOR_CONFIG" ]]
    mcp_cursor_ensure_config
    assert_file_exists "$CURSOR_CONFIG"
    run jq -e '.mcpServers' "$CURSOR_CONFIG"
    assert_success
}

@test "mcp_cursor_ensure_config leaves an existing file untouched" {
    printf '{"mcpServers":{"x":{"command":"y"}},"keep":true}' > "$CURSOR_CONFIG"
    local before after _
    read -r before _ < <(shasum -a 256 "$CURSOR_CONFIG")
    mcp_cursor_ensure_config
    read -r after  _ < <(shasum -a 256 "$CURSOR_CONFIG")
    [[ "$before" == "$after" ]]
}

@test "mcp_cursor_add writes the entry without clobbering sibling keys" {
    printf '{"mcpServers":{},"keep":"sibling"}' > "$CURSOR_CONFIG"
    export HARNESS_DESIRED_JSON='{
      "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
    }'

    run mcp_cursor_add context7
    assert_success

    # Entry shape matches Claude Desktop's mcpServers schema.
    run jq -r '.mcpServers.context7.command' "$CURSOR_CONFIG"
    assert_output_contains "npx"
    run jq -c '.mcpServers.context7.args' "$CURSOR_CONFIG"
    assert_output_contains '["-y","@upstash/context7-mcp"]'

    # Sibling preserved.
    run jq -r '.keep' "$CURSOR_CONFIG"
    assert_output_contains "sibling"
}

@test "mcp_cursor_add resolves \${VAR} env placeholders against live env" {
    export HARNESS_DESIRED_JSON='{
      "tavily": {
        "command": "npx",
        "args": ["-y", "tavily-mcp@latest"],
        "env": {"TAVILY_API_KEY": "${TAVILY_API_KEY}"}
      }
    }'
    export TAVILY_API_KEY="sk-test-rotated"

    run mcp_cursor_add tavily
    assert_success
    run jq -r '.mcpServers.tavily.env.TAVILY_API_KEY' "$CURSOR_CONFIG"
    assert_output_contains "sk-test-rotated"
}

@test "mcp_cursor_add fails loud when a referenced env var is unset" {
    export HARNESS_DESIRED_JSON='{
      "tavily": {
        "command": "npx",
        "args": ["-y", "tavily-mcp@latest"],
        "env": {"TAVILY_API_KEY": "${TAVILY_API_KEY}"}
      }
    }'
    unset TAVILY_API_KEY

    run mcp_cursor_add tavily
    assert_failure
    assert_output_contains "TAVILY_API_KEY"
    [[ ! -e "$CURSOR_CONFIG" ]] || ! jq -e '.mcpServers.tavily' "$CURSOR_CONFIG" >/dev/null
}

@test "mcp_cursor_list_current enumerates configured names sorted" {
    cat > "$CURSOR_CONFIG" <<'JSON'
{
  "mcpServers": {
    "tavily":   {"command": "npx", "args": ["-y", "tavily-mcp"]},
    "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
  }
}
JSON
    run mcp_cursor_list_current
    assert_success
    [[ "${lines[0]}" == "context7" ]]
    [[ "${lines[1]}" == "tavily"   ]]
}

@test "mcp_cursor_current_signature matches mcp_desired_signature when in sync" {
    cat > "$CURSOR_CONFIG" <<'JSON'
{"mcpServers": {"context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}}}
JSON
    export HARNESS_DESIRED_JSON='{
      "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
    }'
    local desired current
    desired=$(mcp_desired_signature         context7 cursor)
    current=$(mcp_cursor_current_signature  context7)
    [[ "$desired" == "$current" ]] || {
        echo "desired=[$desired] current=[$current]" >&2
        return 1
    }
}

@test "mcp_cursor_current_signature flags drift on arg change" {
    cat > "$CURSOR_CONFIG" <<'JSON'
{"mcpServers": {"context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}}}
JSON
    export HARNESS_DESIRED_JSON='{
      "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp@2"]}
    }'
    local desired current
    desired=$(mcp_desired_signature         context7 cursor)
    current=$(mcp_cursor_current_signature  context7)
    [[ "$desired" != "$current" ]]
}

@test "mcp_detect_drift (cursor) returns drifted names with exit 0" {
    cat > "$CURSOR_CONFIG" <<'JSON'
{"mcpServers": {
  "context7": {"command": "npx",   "args": ["-y", "@upstash/context7-mcp"]},
  "tilth":    {"command": "tilth", "args": ["--mcp", "--edit"]}
}}
JSON
    export EXISTING=$'context7\ntilth'
    export HARNESS_DESIRED_JSON='{
      "context7": {"command": "npx",   "args": ["-y", "@upstash/context7-mcp@NEW"]},
      "tilth":    {"command": "tilth", "args": ["--mcp", "--edit"]}
    }'

    run mcp_detect_drift cursor
    assert_success
    assert_output_contains "context7"
    assert_output_not_contains "tilth"
}

@test "mcp_cursor_remove deletes only the named entry" {
    cat > "$CURSOR_CONFIG" <<'JSON'
{
  "extraField": "keep-me",
  "mcpServers": {
    "tavily":   {"command": "npx", "args": ["-y", "tavily-mcp"]},
    "context7": {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]}
  }
}
JSON

    run mcp_cursor_remove tavily
    assert_success

    run jq -e '.mcpServers.tavily // empty' "$CURSOR_CONFIG"
    [[ -z "$output" ]]
    run jq -r '.mcpServers.context7.command' "$CURSOR_CONFIG"
    assert_output_contains "npx"
    run jq -r '.extraField' "$CURSOR_CONFIG"
    assert_output_contains "keep-me"
}

@test "mcp_cursor_remove on a missing file is a no-op (no crash)" {
    [[ ! -e "$CURSOR_CONFIG" ]]
    run mcp_cursor_remove never-existed
    assert_success
    [[ ! -e "$CURSOR_CONFIG" ]]
}

@test "mcp_filter_for_harness defaults to including cursor" {
    local registry; registry=$(cat <<'JSON'
{
  "context7":    {"command": "npx", "args": ["-y", "@upstash/context7-mcp"]},
  "claude-only": {"command": "foo", "harnesses": ["claude"]}
}
JSON
)
    local filtered; filtered=$(mcp_filter_for_harness cursor "$registry")
    run jq -r '.context7.command' <<<"$filtered"
    assert_output_contains "npx"
    run jq -r '."claude-only" // empty' <<<"$filtered"
    [[ -z "$output" ]]
}
