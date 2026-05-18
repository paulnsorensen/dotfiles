#!/usr/bin/env bats
#
# Tests for agents/hooks/sync.sh + agents/hooks/lib.sh.
#
# Strategy: source sync-common.sh + lib.sh, point the lib at a temp
# settings.json / config.toml, exercise the helpers directly, then drive
# the full sync.sh end-to-end against the same temp state.
#
# shellcheck disable=SC2016,SC2181
#   SC2016: single-quoted $HOME / $? are intentional — these tests assert
#           literal strings that are expanded by the hook runner, not by
#           bash at write-time.
#   SC2181: $? checks against `run` output are the bats-native pattern.

load test_helper

setup() {
    setup_test_env

    export REGISTRY_FILE="$REAL_DOTFILES_DIR/agents/hooks/registry.yaml"

    # Per-test temp paths the lib will write to.
    export CLAUDE_SETTINGS_FILE="$TEST_HOME/claude-settings.json"
    export CODEX_CONFIG_FILE="$TEST_HOME/codex-config.toml"

    # shellcheck source=../claude/lib/sync-common.sh
    source "$REAL_DOTFILES_DIR/claude/lib/sync-common.sh"
    # shellcheck source=../agents/hooks/lib.sh
    source "$REAL_DOTFILES_DIR/agents/hooks/lib.sh"

    # Default REGISTRY_JSON / HARNESS_DESIRED_JSON used by most tests.
    export REGISTRY_JSON
    REGISTRY_JSON=$(yq -o=json '.hooks' "$REGISTRY_FILE")
    export HARNESS_DESIRED_JSON
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness claude "$REGISTRY_JSON")
}

teardown() {
    teardown_test_env
}

# ── registry ───────────────────────────────────────────────────────────

@test "registry.yaml exists and contains session-start-cheese-flair" {
    assert_file_exists "$REGISTRY_FILE"
    local names
    names=$(yq -r '.hooks | keys | .[]' "$REGISTRY_FILE")
    [[ "$names" == *"session-start-cheese-flair"* ]]
}

@test "registry entry declares both harnesses, matcher, timeout, script" {
    local entry
    entry=$(yq -o=json '.hooks."session-start-cheese-flair"' "$REGISTRY_FILE")
    [[ "$(jq -r '.event'     <<<"$entry")" == "SessionStart" ]]
    [[ "$(jq -r '.script'    <<<"$entry")" == "agents/hooks/session-start-cheese-flair.sh" ]]
    [[ "$(jq -r '.matcher'   <<<"$entry")" == "startup|resume" ]]
    [[ "$(jq -r '.timeout'   <<<"$entry")" == "5" ]]
    [[ "$(jq -r '.harnesses[0]' <<<"$entry")" == "claude" ]]
    [[ "$(jq -r '.harnesses[1]' <<<"$entry")" == "codex"  ]]
}

@test "hook_filter_for_harness includes the entry for both claude and codex" {
    local c x
    c=$(hook_filter_for_harness claude "$REGISTRY_JSON")
    x=$(hook_filter_for_harness codex  "$REGISTRY_JSON")
    [[ "$(jq -r 'keys[]' <<<"$c")" == "session-start-cheese-flair" ]]
    [[ "$(jq -r 'keys[]' <<<"$x")" == "session-start-cheese-flair" ]]
}

# ── deployed-path resolver ─────────────────────────────────────────────

@test "hook_deployed_path returns harness-specific \$HOME path" {
    [[ "$(hook_deployed_path claude agents/hooks/session-start-cheese-flair.sh)" == "\$HOME/.claude/hooks/session-start-cheese-flair.sh" ]]
    [[ "$(hook_deployed_path codex  agents/hooks/session-start-cheese-flair.sh)" == "\$HOME/.codex/hooks/session-start-cheese-flair.sh" ]]
}

@test "hook_codex_command builds bash invocation with \$HOME" {
    local cmd
    cmd=$(hook_codex_command agents/hooks/session-start-cheese-flair.sh)
    [[ "$cmd" == 'bash $HOME/.codex/hooks/session-start-cheese-flair.sh' ]]
}

# ── drift signatures ───────────────────────────────────────────────────

@test "hook_desired_signature is stable for both harnesses" {
    local c x
    c=$(hook_desired_signature session-start-cheese-flair claude)
    x=$(hook_desired_signature session-start-cheese-flair codex)
    # Claude path differs from codex; matcher + timeout match.
    [[ "$c" == *"/.claude/hooks/session-start-cheese-flair.sh"$'\t'"startup|resume"$'\t'"5" ]]
    [[ "$x" == *"/.codex/hooks/session-start-cheese-flair.sh"$'\t'"startup|resume"$'\t'"5"  ]]
}

# ── claude backend: idempotent upsert ──────────────────────────────────

@test "claude upsert adds SessionStart entry when missing" {
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{ "permissions": { "allow": ["Edit"] } }
JSON

    hook_claude_apply session-start-cheese-flair
    [[ $? -eq 0 ]]

    local cmd timeout
    cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    timeout=$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$CLAUDE_SETTINGS_FILE")
    [[ "$cmd" == 'bash "$HOME/.claude/hooks/session-start-cheese-flair.sh"' ]]
    [[ "$timeout" == "5" ]]

    # Pre-existing keys must survive.
    [[ "$(jq -r '.permissions.allow[0]' "$CLAUDE_SETTINGS_FILE")" == "Edit" ]]
}

@test "claude upsert is idempotent on second run (no duplicate entries)" {
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{ "hooks": {} }
JSON
    hook_claude_apply session-start-cheese-flair
    hook_claude_apply session-start-cheese-flair
    hook_claude_apply session-start-cheese-flair

    local count
    count=$(jq '.hooks.SessionStart | length' "$CLAUDE_SETTINGS_FILE")
    [[ "$count" == "1" ]]
}

@test "claude upsert preserves unrelated SessionStart entries" {
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash $HOME/other-hook.sh" }] }
    ]
  }
}
JSON
    hook_claude_apply session-start-cheese-flair

    local count first_cmd
    count=$(jq '.hooks.SessionStart | length' "$CLAUDE_SETTINGS_FILE")
    first_cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    [[ "$count" == "2" ]]
    [[ "$first_cmd" == 'bash $HOME/other-hook.sh' ]]
}

# ── claude backend: drift detection ────────────────────────────────────

@test "hook_claude_current_signature reports empty when settings file missing" {
    rm -f "$CLAUDE_SETTINGS_FILE"
    local sig
    sig=$(hook_claude_current_signature session-start-cheese-flair)
    [[ "$sig" == $'\t\t' ]]
}

@test "hook_claude_current_signature reports empty when entry missing" {
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    local sig
    sig=$(hook_claude_current_signature session-start-cheese-flair)
    [[ "$sig" == $'\t\t' ]]
}

@test "hook_claude_current_signature reports drift when timeout differs" {
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash \"$HOME/.claude/hooks/session-start-cheese-flair.sh\"", "timeout": 99 }] }
    ]
  }
}
JSON
    local cur des
    cur=$(hook_claude_current_signature session-start-cheese-flair)
    des=$(hook_desired_signature       session-start-cheese-flair claude)
    [[ "$cur" != "$des" ]]
    [[ "$cur" == *$'\t'"99" ]]
}

@test "hook_detect_changes (claude): empty when in sync" {
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply session-start-cheese-flair
    local changed
    changed=$(hook_detect_changes claude)
    [[ -z "$changed" ]]
}

@test "hook_detect_changes (claude): names entry when missing" {
    rm -f "$CLAUDE_SETTINGS_FILE"
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    local changed
    changed=$(hook_detect_changes claude)
    [[ "$changed" == "session-start-cheese-flair" ]]
}

# ── codex backend: TOML upsert preserving other keys ───────────────────

@test "codex upsert into existing TOML preserves every other top-level key" {
    # Test for codex backend uses its own desired-json filter.
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")

    cat > "$CODEX_CONFIG_FILE" <<'TOML'
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true

[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]
TOML

    hook_codex_apply session-start-cheese-flair

    grep -qF 'approval_policy = "on-request"'         "$CODEX_CONFIG_FILE"
    grep -qF 'sandbox_mode = "workspace-write"'       "$CODEX_CONFIG_FILE"
    grep -qF '[sandbox_workspace_write]'              "$CODEX_CONFIG_FILE"
    grep -qF 'network_access = true'                  "$CODEX_CONFIG_FILE"
    grep -qF '[mcp_servers.context7]'                 "$CODEX_CONFIG_FILE"
    grep -qF '[[hooks.SessionStart]]'                 "$CODEX_CONFIG_FILE"
    grep -qF 'matcher = "startup|resume"'             "$CODEX_CONFIG_FILE"
    grep -qF 'command = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"' "$CODEX_CONFIG_FILE"
    grep -qF 'timeout = 5'                            "$CODEX_CONFIG_FILE"
}

@test "codex upsert is idempotent (re-run produces no new SessionStart blocks)" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    : > "$CODEX_CONFIG_FILE"

    hook_codex_apply session-start-cheese-flair
    hook_codex_apply session-start-cheese-flair
    hook_codex_apply session-start-cheese-flair

    local count
    count=$(yq -p=toml -o=json '.hooks.SessionStart | length' "$CODEX_CONFIG_FILE")
    [[ "$count" == "1" ]]
}

@test "codex upsert creates config.toml when it does not exist" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    export CODEX_CONFIG_FILE="$TEST_HOME/.codex/config.toml"
    [[ ! -e "$CODEX_CONFIG_FILE" ]]

    hook_codex_apply session-start-cheese-flair

    [[ -f "$CODEX_CONFIG_FILE" ]]
    grep -qF '[[hooks.SessionStart]]' "$CODEX_CONFIG_FILE"
}

@test "hook_detect_changes (codex): empty when in sync" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    : > "$CODEX_CONFIG_FILE"
    hook_codex_apply session-start-cheese-flair
    local changed
    changed=$(hook_detect_changes codex)
    [[ -z "$changed" ]]
}

@test "hook_detect_changes (codex): names entry on drift (command path moved)" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
[[hooks.SessionStart]]
matcher = "startup|resume"

[[hooks.SessionStart.hooks]]
type = "command"
command = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"
timeout = 99
TOML
    local changed
    changed=$(hook_detect_changes codex)
    [[ "$changed" == "session-start-cheese-flair" ]]
}

# ── full sync.sh end-to-end ────────────────────────────────────────────

@test "sync.sh --dry-run on an in-sync state reports no changes" {
    # First apply, then dry-run.
    bash "$REAL_DOTFILES_DIR/agents/hooks/sync.sh" >/dev/null

    run bash "$REAL_DOTFILES_DIR/agents/hooks/sync.sh" --dry-run
    assert_success
    assert_output_contains "Everything in sync!"
}

@test "sync.sh --dry-run on a missing entry reports the upsert" {
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    : > "$CODEX_CONFIG_FILE"

    run bash "$REAL_DOTFILES_DIR/agents/hooks/sync.sh" --dry-run
    assert_success
    assert_output_contains "To upsert"
    assert_output_contains "session-start-cheese-flair"
}

@test "sync.sh --harness=claude does not touch codex config" {
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    : > "$CODEX_CONFIG_FILE"

    run bash "$REAL_DOTFILES_DIR/agents/hooks/sync.sh" --harness=claude
    assert_success

    # Claude side upserted.
    [[ "$(jq '.hooks.SessionStart | length' "$CLAUDE_SETTINGS_FILE")" == "1" ]]
    # Codex side untouched (file still empty).
    [[ ! -s "$CODEX_CONFIG_FILE" ]]
}

@test "sync.sh --harness=codex does not touch claude settings" {
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{ "permissions": { "allow": ["Edit"] } }
JSON
    : > "$CODEX_CONFIG_FILE"

    local before
    before=$(shasum -a 256 "$CLAUDE_SETTINGS_FILE" | awk '{print $1}')

    run bash "$REAL_DOTFILES_DIR/agents/hooks/sync.sh" --harness=codex
    assert_success

    local after
    after=$(shasum -a 256 "$CLAUDE_SETTINGS_FILE" | awk '{print $1}')
    [[ "$before" == "$after" ]]
    grep -qF '[[hooks.SessionStart]]' "$CODEX_CONFIG_FILE"
}

# ── chezmoi installer ──────────────────────────────────────────────────

@test "chezmoi/lib/install-shared-assets.sh exists and is executable" {
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    assert_file_exists "$installer"
    [[ -x "$installer" ]]
}

@test "install-shared-assets.sh copies an executable to multiple targets and preserves +x" {
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    local src="$TEST_HOME/source.sh"
    cat > "$src" <<'SH'
#!/usr/bin/env bash
echo hello
SH
    chmod +x "$src"

    local t1="$TEST_HOME/target-a/foo.sh"
    local t2="$TEST_HOME/target-b/foo.sh"

    run bash "$installer" "$src" "$t1" "$t2"
    assert_success
    [[ -x "$t1" && -x "$t2" ]]
    diff -q "$src" "$t1"
    diff -q "$src" "$t2"
}

@test "install-shared-assets.sh replaces an existing symlink at the target" {
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    local src="$TEST_HOME/source.txt"
    echo "new content" > "$src"

    local target="$TEST_HOME/target/foo.txt"
    mkdir -p "$(dirname "$target")"
    ln -s /tmp/some-other-file "$target"
    [[ -L "$target" ]]

    run bash "$installer" "$src" "$target"
    assert_success
    [[ ! -L "$target" ]]
    [[ -f "$target" ]]
    grep -qF "new content" "$target"
}

@test "chezmoi run_onchange installer template exists and invokes the sync script" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_install-hooks.sh.tmpl"
    assert_file_exists "$tmpl"
    grep -qF 'install-shared-assets.sh' "$tmpl"
    grep -qF 'agents/hooks/sync.sh' "$tmpl"
    grep -qF '.claude/hooks/session-start-cheese-flair.sh' "$tmpl"
    grep -qF '.codex/hooks/session-start-cheese-flair.sh' "$tmpl"
    grep -qF '.claude/lib/cheese-flair.sh' "$tmpl"
    grep -qF '.codex/lib/cheese-flair.sh' "$tmpl"
    grep -qF '.claude/reference/cheese-flair.md' "$tmpl"
    grep -qF '.codex/reference/cheese-flair.md' "$tmpl"
    grep -qF 'Hooks asset hash:' "$tmpl"
}

# ── hardening: filter honors per-entry harnesses list ──────────────────

@test "hook_filter_for_harness excludes entries whose harnesses list omits the target" {
    local reg='{"claude-only":{"event":"SessionStart","script":"x.sh","harnesses":["claude"]}}'
    local for_claude for_codex
    for_claude=$(hook_filter_for_harness claude "$reg")
    for_codex=$(hook_filter_for_harness codex  "$reg")
    [[ "$(jq -r 'keys | length' <<<"$for_claude")" == "1" ]]
    [[ "$(jq -r 'keys | length' <<<"$for_codex")"  == "0" ]]
}

@test "hook_filter_for_harness includes entries that omit the harnesses field (default both)" {
    local reg='{"shared":{"event":"SessionStart","script":"x.sh"}}'
    local for_claude for_codex
    for_claude=$(hook_filter_for_harness claude "$reg")
    for_codex=$(hook_filter_for_harness codex  "$reg")
    [[ "$(jq -r 'keys | length' <<<"$for_claude")" == "1" ]]
    [[ "$(jq -r 'keys | length' <<<"$for_codex")"  == "1" ]]
}

@test "hook_filter_for_harness fails loud when an entry has event != SessionStart" {
    # Asserts the only-SessionStart-wired guard in lib.sh. Adding a hook
    # with event: PostToolUse without first wiring backends for that slot
    # would silently land it under SessionStart — this test catches that.
    local reg='{"future":{"event":"PostToolUse","script":"x.sh"}}'
    run hook_filter_for_harness claude "$reg"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"event != SessionStart"* ]]
    [[ "$output" == *"future"* ]]
}

# ── hardening: codex backend parity with claude on preservation + drift

@test "codex upsert preserves unrelated SessionStart entries from other hooks" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
[[hooks.SessionStart]]
matcher = "startup"

[[hooks.SessionStart.hooks]]
type = "command"
command = "bash $HOME/other-hook.sh"
timeout = 10
TOML
    hook_codex_apply session-start-cheese-flair

    # Both blocks must survive: the unrelated other-hook one AND ours.
    local count
    count=$(yq -p=toml -o=json '.hooks.SessionStart | length' "$CODEX_CONFIG_FILE")
    [[ "$count" == "2" ]]
    grep -qF 'command = "bash $HOME/other-hook.sh"' "$CODEX_CONFIG_FILE"
    grep -qF 'command = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"' "$CODEX_CONFIG_FILE"
}

@test "codex upsert preserves entries under other event types (UserPromptSubmit)" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
[[hooks.UserPromptSubmit]]
matcher = ".*"

[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "echo prompt"
TOML
    hook_codex_apply session-start-cheese-flair

    # SessionStart block added without disturbing UserPromptSubmit.
    [[ "$(yq -p=toml -o=json '.hooks.SessionStart | length'      "$CODEX_CONFIG_FILE")" == "1" ]]
    [[ "$(yq -p=toml -o=json '.hooks.UserPromptSubmit | length' "$CODEX_CONFIG_FILE")" == "1" ]]
    grep -qF 'command = "echo prompt"' "$CODEX_CONFIG_FILE"
}

@test "hook_codex_current_signature reports empty when config file missing" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    rm -f "$CODEX_CONFIG_FILE"
    local sig
    sig=$(hook_codex_current_signature session-start-cheese-flair)
    [[ "$sig" == $'\t\t' ]]
}

@test "hook_codex_current_signature reports empty when SessionStart entry missing" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
approval_policy = "on-request"
TOML
    local sig
    sig=$(hook_codex_current_signature session-start-cheese-flair)
    [[ "$sig" == $'\t\t' ]]
}

@test "hook_codex_current_signature reports drift when matcher differs" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
[[hooks.SessionStart]]
matcher = "something-else"

[[hooks.SessionStart.hooks]]
type = "command"
command = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"
timeout = 5
TOML
    local cur des
    cur=$(hook_codex_current_signature session-start-cheese-flair)
    des=$(hook_desired_signature       session-start-cheese-flair codex)
    [[ "$cur" != "$des" ]]
    [[ "$cur" == *$'\t'"something-else"$'\t'"5" ]]
}

@test "hook_detect_changes (codex): names entry on matcher drift" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
[[hooks.SessionStart]]
matcher = "wrong"

[[hooks.SessionStart.hooks]]
type = "command"
command = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"
timeout = 5
TOML
    local changed
    changed=$(hook_detect_changes codex)
    [[ "$changed" == "session-start-cheese-flair" ]]
}

# ── hardening: in-repo claude/settings.json content lock ───────────────

@test "claude/settings.json carries the SessionStart entry with timeout 5" {
    local settings="$REAL_DOTFILES_DIR/claude/settings.json"
    # Locks acceptance criteria #1 (Claude side path/timeout) against the
    # real file — not a mock — so a future refactor that drops the entry
    # or changes the path is caught immediately.
    [[ "$(jq -r '.hooks.SessionStart | length' "$settings")" -ge 1 ]]
    local cmd timeout
    cmd=$(jq -r '
        .hooks.SessionStart
        | map(select(((.hooks // [])[0].command // "") | test("session-start-cheese-flair.sh")))
        | .[0].hooks[0].command
    ' "$settings")
    timeout=$(jq -r '
        .hooks.SessionStart
        | map(select(((.hooks // [])[0].command // "") | test("session-start-cheese-flair.sh")))
        | .[0].hooks[0].timeout
    ' "$settings")
    [[ "$cmd" == *'.claude/hooks/session-start-cheese-flair.sh'* ]]
    [[ "$timeout" == "5" ]]
}

@test "claude/settings.json sync against itself is a no-op" {
    # Run sync against the real in-repo settings file (copied) and assert
    # the produced state matches byte-for-byte after a re-run — locks the
    # contract that the registry and the checked-in settings agree.
    cp "$REAL_DOTFILES_DIR/claude/settings.json" "$CLAUDE_SETTINGS_FILE"
    local before
    before=$(jq -S . "$CLAUDE_SETTINGS_FILE")
    hook_claude_apply session-start-cheese-flair
    local after
    after=$(jq -S . "$CLAUDE_SETTINGS_FILE")
    [[ "$before" == "$after" ]]
}

# ── hardening: installer argument errors ───────────────────────────────

@test "install-shared-assets.sh exits 2 with usage when called with no args" {
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    run bash "$installer"
    [[ "$status" -eq 2 ]]
    assert_output_contains "Usage:"
}

@test "install-shared-assets.sh exits 2 with usage when given source only (no targets)" {
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    local src="$TEST_HOME/src.sh"
    echo "x" > "$src"
    run bash "$installer" "$src"
    [[ "$status" -eq 2 ]]
    assert_output_contains "Usage:"
}

@test "install-shared-assets.sh exits 1 with diagnostic when source is missing" {
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    run bash "$installer" "$TEST_HOME/does-not-exist" "$TEST_HOME/target"
    [[ "$status" -eq 1 ]]
    assert_output_contains "source not found"
}

@test "install-shared-assets.sh does NOT mark non-executable source +x at target" {
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    local src="$TEST_HOME/plain.md"
    echo "# bank" > "$src"
    chmod 644 "$src"
    local target="$TEST_HOME/out/plain.md"

    run bash "$installer" "$src" "$target"
    assert_success
    [[ -f "$target" ]]
    [[ ! -x "$target" ]]
}

# ── end-to-end: installer + sync mirror chezmoi run_onchange behaviour ──
# Walks the same sequence the chezmoi template uses (six install-shared-assets.sh
# copies + one agents/hooks/sync.sh) against a fake $HOME, then asserts the
# six deployed files exist with the right modes and the Codex TOML carries
# the expected matcher/command/timeout. Locks acceptance criterion #1 at
# the integration level — a unit grep against the template source would
# miss a regression where INSTALLER paths drift or sync.sh stops upserting.
@test "chezmoi installer flow deploys six files and writes the expected Codex TOML block" {
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    local sync_script="$REAL_DOTFILES_DIR/agents/hooks/sync.sh"
    local source_root="$REAL_DOTFILES_DIR"

    # Mirror run_onchange_install-hooks.sh.tmpl: copy the trio into both
    # ~/.claude/ and ~/.codex/ subtrees under TEST_HOME.
    bash "$installer" "$source_root/agents/hooks/session-start-cheese-flair.sh" \
        "$HOME/.claude/hooks/session-start-cheese-flair.sh" \
        "$HOME/.codex/hooks/session-start-cheese-flair.sh"

    bash "$installer" "$source_root/agents/lib/cheese-flair.sh" \
        "$HOME/.claude/lib/cheese-flair.sh" \
        "$HOME/.codex/lib/cheese-flair.sh"

    bash "$installer" "$source_root/agents/reference/cheese-flair.md" \
        "$HOME/.claude/reference/cheese-flair.md" \
        "$HOME/.codex/reference/cheese-flair.md"

    # All six deployed files exist; the hook scripts are executable, the
    # lib + bank are not (they get sourced/read, not exec'd).
    [[ -f "$HOME/.claude/hooks/session-start-cheese-flair.sh" ]]
    [[ -f "$HOME/.codex/hooks/session-start-cheese-flair.sh"  ]]
    [[ -x "$HOME/.claude/hooks/session-start-cheese-flair.sh" ]]
    [[ -x "$HOME/.codex/hooks/session-start-cheese-flair.sh"  ]]
    [[ -f "$HOME/.claude/lib/cheese-flair.sh"  ]]
    [[ -f "$HOME/.codex/lib/cheese-flair.sh"   ]]
    [[ -f "$HOME/.claude/reference/cheese-flair.md" ]]
    [[ -f "$HOME/.codex/reference/cheese-flair.md"  ]]

    # Then run the sync against the fake codex config (claude side untouched
    # — we point CLAUDE_SETTINGS_FILE at a temp file so the real in-repo
    # settings is not mutated).
    local fake_claude="$HOME/claude-settings.json"
    echo '{}' > "$fake_claude"
    local fake_codex="$HOME/.codex/config.toml"

    CLAUDE_SETTINGS_FILE="$fake_claude" \
    CODEX_CONFIG_FILE="$fake_codex" \
        run bash "$sync_script"
    assert_success

    # Codex TOML must contain the expected block with matcher/command/timeout.
    [[ -f "$fake_codex" ]]
    local matcher cmd timeout
    matcher=$(yq -p=toml -o=json '.hooks.SessionStart[0].matcher'              "$fake_codex")
    cmd=$(    yq -p=toml -o=json '.hooks.SessionStart[0].hooks[0].command'     "$fake_codex")
    timeout=$(yq -p=toml -o=json '.hooks.SessionStart[0].hooks[0].timeout'     "$fake_codex")
    [[ "$matcher" == '"startup|resume"' ]]
    [[ "$cmd"     == '"bash $HOME/.codex/hooks/session-start-cheese-flair.sh"' ]]
    [[ "$timeout" == "5" ]]

    # Claude side mirror — the sync wrote a SessionStart entry into the fake
    # settings file pointing at the deployed hook.
    [[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$fake_claude")" == 'bash "$HOME/.claude/hooks/session-start-cheese-flair.sh"' ]]
    [[ "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$fake_claude")" == "5" ]]
}
