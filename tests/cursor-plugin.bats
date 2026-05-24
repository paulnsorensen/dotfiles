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

    # Machine-level manifest records relpaths under the plugin key
    # (replacing the old per-dir .dotfiles-managed-<plugin> markers).
    local manifest="$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    [[ -f "$manifest" ]]
    jq -e '.["cheese-grok"].files | index("skills/grok-codebase")' "$manifest"
    jq -e '.["cheese-grok"].files | index("rules/reader-companion.mdc")' "$manifest"
    jq -e '.["cheese-grok"].files | index("commands/tighten.md")' "$manifest"
    jq -e '.["cheese-grok"].files | index("hooks/block-destructive.sh")' "$manifest"

    # Per-dir markers are gone (migrated to the manifest).
    [[ ! -e "$CURSOR_HOME/skills/.dotfiles-managed-cheese-grok" ]]
    [[ ! -e "$CURSOR_HOME/rules/.dotfiles-managed-cheese-grok" ]]
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

# ─── target guard (B) ───────────────────────────────────────────────────

@test "install-cursor-plugin: refuses deploy into the dotfiles repo root" {
    run "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$REAL_DOTFILES_DIR"
    [[ "$status" -ne 0 ]]
    assert_output_contains "refusing to deploy into the dotfiles repo"
    # Wrote nothing into the repo.
    [[ ! -e "$REAL_DOTFILES_DIR/.dotfiles-cursor-manifest.json" ]]
}

@test "install-cursor-plugin: refuses deploy into a subpath of the repo" {
    local target="$REAL_DOTFILES_DIR/nonexistent-deploy-target"
    run "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$target"
    [[ "$status" -ne 0 ]]
    assert_output_contains "refusing to deploy into the dotfiles repo"
    [[ ! -e "$target" ]]
}

# ─── merge integrity: validated_mv (C) ──────────────────────────────────

@test "validated_mv: refuses a merge that would drop a pre-existing top-level key" {
    source "$INSTALL_SCRIPT"
    local dst="$TEST_HOME/d.json" tmp="$TEST_HOME/t.json"
    printf '{"version":1,"hooks":{},"userKey":true}\n' > "$dst"
    # tmp drops "userKey" and "version" — the silent-truncation class.
    printf '{"hooks":{"a":[]}}\n' > "$tmp"

    run validated_mv "$tmp" "$dst"
    [[ "$status" -ne 0 ]]
    assert_output_contains "would drop top-level keys"

    # Destination left intact.
    run jq -r '.userKey' "$dst"; assert_output_contains "true"
    run jq -r '.version' "$dst"; assert_output_contains "1"
}

@test "validated_mv: allows a nested-only change that keeps every top-level key" {
    source "$INSTALL_SCRIPT"
    local dst="$TEST_HOME/d.json" tmp="$TEST_HOME/t.json"
    printf '{"version":1,"hooks":{"a":[1]}}\n' > "$dst"
    printf '{"version":1,"hooks":{"a":[1,2,3]}}\n' > "$tmp"

    run validated_mv "$tmp" "$dst"
    assert_success
    run jq -c '.hooks.a' "$dst"
    assert_output_contains "[1,2,3]"
}

@test "validated_mv: refuses to mv a tmp file that is not valid JSON" {
    source "$INSTALL_SCRIPT"
    local dst="$TEST_HOME/d.json" tmp="$TEST_HOME/t.json"
    printf '{"version":1}\n' > "$dst"
    printf 'not json{' > "$tmp"

    run validated_mv "$tmp" "$dst"
    [[ "$status" -ne 0 ]]
    assert_output_contains "not valid JSON"

    # Destination untouched — a bad merge never reaches disk.
    run jq -r '.version' "$dst"; assert_output_contains "1"
}

# ─── collision guard (D) ─────────────────────────────────────────────────

@test "install-cursor-plugin: warns and skips a foreign same-named skill" {
    # Pre-seed a foreign skill dir claimed by no manifest (gh-installed style).
    mkdir -p "$CURSOR_HOME/skills/grok-codebase"
    printf '# foreign\n' > "$CURSOR_HOME/skills/grok-codebase/SKILL.md"

    run "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$CURSOR_HOME"
    assert_success
    assert_output_contains "skipping skills/grok-codebase"

    # Foreign content survives untouched (not clobbered by the plugin copy).
    run cat "$CURSOR_HOME/skills/grok-codebase/SKILL.md"
    assert_output_contains "# foreign"

    # Skipped item was NOT recorded as ours.
    run jq -r '.["cheese-grok"].files | index("skills/grok-codebase") // "absent"' \
        "$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    assert_output_contains "absent"

    # A non-colliding plugin skill still deployed and recorded.
    [[ -f "$CURSOR_HOME/skills/design-doc/SKILL.md" ]]
    run jq -e '.["cheese-grok"].files | index("skills/design-doc")' \
        "$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    assert_success
}

@test "install-cursor-plugin: collision guard also covers commands (not just skills)" {
    # Proves claim_or_skip is wired through deploy_files, not only
    # deploy_skills: a foreign command file claimed by no manifest is
    # skipped, never clobbered.
    mkdir -p "$CURSOR_HOME/commands"
    printf '# foreign cmd\n' > "$CURSOR_HOME/commands/tighten.md"

    run "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$CURSOR_HOME"
    assert_success
    assert_output_contains "skipping commands/tighten.md"

    # Foreign content survives, and was not recorded as ours.
    run cat "$CURSOR_HOME/commands/tighten.md"
    assert_output_contains "# foreign cmd"
    run jq -r '.["cheese-grok"].files | index("commands/tighten.md") // "absent"' \
        "$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    assert_output_contains "absent"

    # A non-colliding command still deployed.
    [[ -f "$CURSOR_HOME/commands/reading-probes.md" ]]
}

# ─── machine-level manifest (#181 pattern) ──────────────────────────────

@test "manifest: diff-clean keeps a path another plugin still claims (ref-count)" {
    source "$INSTALL_SCRIPT"
    cursor_home="$CURSOR_HOME"
    MANIFEST="$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    mkdir -p "$CURSOR_HOME/skills/shared"
    printf '{"p1":{"files":["skills/shared"]},"p2":{"files":["skills/shared"]}}\n' > "$MANIFEST"

    # p1 drops skills/shared; p2 still claims it.
    manifest_diff_clean p1 '[]'
    [[ -d "$CURSOR_HOME/skills/shared" ]]
}

@test "manifest: diff-clean removes a path no other plugin claims" {
    source "$INSTALL_SCRIPT"
    cursor_home="$CURSOR_HOME"
    MANIFEST="$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    mkdir -p "$CURSOR_HOME/skills/solo"
    printf '{"p1":{"files":["skills/solo"]}}\n' > "$MANIFEST"

    manifest_diff_clean p1 '[]'
    [[ ! -e "$CURSOR_HOME/skills/solo" ]]
}

@test "install-cursor-plugin: corrupt manifest fails loud on read" {
    printf 'not json at all' > "$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    run "$INSTALL_SCRIPT" "$PLUGIN_SRC" "$CURSOR_HOME"
    [[ "$status" -ne 0 ]]
    assert_output_contains "manifest corrupt"
}

@test "manifest_validate: rejects a non-object top-level (valid JSON array)" {
    source "$INSTALL_SCRIPT"
    MANIFEST="$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    printf '[]\n' > "$MANIFEST"
    run manifest_validate
    [[ "$status" -ne 0 ]]
    assert_output_contains "top-level must be an object"
}

@test "manifest_validate: rejects an entry missing its files[] array" {
    source "$INSTALL_SCRIPT"
    MANIFEST="$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    printf '{"cheese-grok":{"nope":true}}\n' > "$MANIFEST"
    run manifest_validate
    [[ "$status" -ne 0 ]]
    assert_output_contains "missing files"
}

@test "install-cursor-plugin: drops a skill removed from plugin source on re-run" {
    local scratch="$TEST_HOME/scratch-plugin"
    cp -R "$PLUGIN_SRC" "$scratch"

    "$INSTALL_SCRIPT" "$scratch" "$CURSOR_HOME" >/dev/null
    [[ -d "$CURSOR_HOME/skills/tour" ]]

    rm -rf "$scratch/skills/tour"
    "$INSTALL_SCRIPT" "$scratch" "$CURSOR_HOME" >/dev/null

    # Dropped skill gone from disk and from the manifest.
    [[ ! -e "$CURSOR_HOME/skills/tour" ]]
    run jq -r '.["cheese-grok"].files | index("skills/tour") // "absent"' \
        "$CURSOR_HOME/.dotfiles-cursor-manifest.json"
    assert_output_contains "absent"
    # Survivors intact.
    [[ -d "$CURSOR_HOME/skills/design-doc" ]]
}

# ─── .gitignore: deploy outputs ignored, plugin source tracked (B1) ─────

@test "gitignore: cursor deploy outputs are ignored but plugin source is tracked" {
    # A deploy mis-pointed at the repo would recreate the ~/.cursor outputs
    # under cursor/. The .gitignore stanza keeps them out of version control
    # while leaving cursor/plugins/ (the tracked source) committable.
    local d
    for d in commands hooks rules skills; do
        run git -C "$REAL_DOTFILES_DIR" check-ignore "cursor/$d/anything"
        assert_success   # exit 0 == path is ignored
    done
    local f
    for f in hooks.json mcp.json modes.json; do
        run git -C "$REAL_DOTFILES_DIR" check-ignore "cursor/$f"
        assert_success
    done

    # The tracked plugin source must NOT be ignored.
    run git -C "$REAL_DOTFILES_DIR" check-ignore \
        "cursor/plugins/local/cheese-grok/.cursor-plugin/plugin.json"
    assert_failure   # exit 1 == not ignored
}

# ─── /cursor skill discovery (A, criterion 1) ───────────────────────────

@test "skills/cursor: frontmatter name is 'cursor' so it loads as /cursor" {
    # Skill discovery keys on the frontmatter name; a rename here silently
    # breaks the /cursor command after dots sync.
    local skill="$REAL_DOTFILES_DIR/skills/cursor/SKILL.md"
    [[ -f "$skill" ]]
    run grep -qE '^name:[[:space:]]+cursor[[:space:]]*$' "$skill"
    assert_success
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
