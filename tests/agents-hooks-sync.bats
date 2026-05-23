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
    [[ "$cmd" == 'bash "$HOME/.codex/hooks/session-start-cheese-flair.sh"' ]]
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
    grep -qF 'command = "bash \"$HOME/.codex/hooks/session-start-cheese-flair.sh\""' "$CODEX_CONFIG_FILE"
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
command = "bash \"$HOME/.codex/hooks/session-start-cheese-flair.sh\""
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

@test "chezmoi run_onchange installer template exists and drives a registry-iterated deploy" {
    # Asserts the *structure* of the template: it must source the registry,
    # iterate per (asset × harness), and hand each pair to the installer +
    # sync.sh. Per-asset literals are NOT asserted here — adding a new hook
    # must be a registry edit, not a template edit. The runtime payload is
    # covered by "chezmoi installer flow deploys every registry asset…".
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_install-hooks.sh.tmpl"
    assert_file_exists "$tmpl"
    grep -qF 'install-shared-assets.sh' "$tmpl"
    grep -qF 'agents/hooks/sync.sh' "$tmpl"
    grep -qF 'agents/hooks/registry.yaml' "$tmpl"
    grep -qF 'yq -p=yaml -o=json' "$tmpl"
    grep -qF 'shared_assets' "$tmpl"
    grep -qF 'Hooks asset hash:' "$tmpl"
    # No hardcoded asset literals — must be derived from the registry.
    ! grep -qF 'session-start-cheese-flair.sh' "$tmpl"
    ! grep -qF 'cheese-flair.md' "$tmpl"
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

@test "hook_filter_for_harness fails loud when the event field is missing" {
    # A typo'd field name ("evnt: SessionStart") would silently default
    # event to SessionStart without this guard, hiding the malformed entry.
    local reg='{"typo":{"script":"x.sh"}}'
    run hook_filter_for_harness claude "$reg"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"missing the required 'event' field"* ]]
    [[ "$output" == *"typo"* ]]
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
    grep -qF 'command = "bash \"$HOME/.codex/hooks/session-start-cheese-flair.sh\""' "$CODEX_CONFIG_FILE"
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
command = "bash \"$HOME/.codex/hooks/session-start-cheese-flair.sh\""
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
command = "bash \"$HOME/.codex/hooks/session-start-cheese-flair.sh\""
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

@test "chezmoi installer iteration handles a synthetic multi-hook registry" {
    # Reimplements the yq|jq pipeline from run_onchange_after_install-hooks.sh.tmpl
    # against a registry with two hooks — one with shared_assets, one without,
    # and one that opts out of codex via `harnesses: [claude]`. Asserts every
    # (asset × harness) pair the template would deploy ends up in the emitted
    # set. Locks the registry contract: adding a new hook must not require
    # touching the installer template.
    local synth="$TEST_HOME/synth-registry.yaml"
    cat > "$synth" <<'YAML'
hooks:
  session-start-cheese-flair:
    event: SessionStart
    script: agents/hooks/session-start-cheese-flair.sh
    shared_assets:
      - agents/lib/cheese-flair.sh
      - agents/reference/cheese-flair.md
    harnesses: [claude, codex]
  user-prompt-cheese-budget:
    event: SessionStart
    script: agents/hooks/user-prompt-cheese-budget.sh
    harnesses: [claude]
YAML
    local pairs
    pairs=$(yq -p=yaml -o=json '.hooks' "$synth" | jq -r '
        to_entries[]
        | .value as $h
        | ($h.harnesses // ["claude","codex"])[] as $harness
        | ([$h.script] + ($h.shared_assets // []))[] as $asset
        | "\($asset)\t\($harness)"
    ' | LC_ALL=C sort -u)

    # cheese-flair: 3 assets × 2 harnesses = 6.  cheese-budget: 1 × 1 = 1.
    [[ "$(wc -l <<<"$pairs" | tr -d ' ')" -eq 7 ]]
    grep -qF $'agents/hooks/session-start-cheese-flair.sh\tclaude' <<<"$pairs"
    grep -qF $'agents/hooks/session-start-cheese-flair.sh\tcodex'  <<<"$pairs"
    grep -qF $'agents/lib/cheese-flair.sh\tclaude'                 <<<"$pairs"
    grep -qF $'agents/lib/cheese-flair.sh\tcodex'                  <<<"$pairs"
    grep -qF $'agents/reference/cheese-flair.md\tclaude'           <<<"$pairs"
    grep -qF $'agents/reference/cheese-flair.md\tcodex'            <<<"$pairs"
    grep -qF $'agents/hooks/user-prompt-cheese-budget.sh\tclaude'  <<<"$pairs"
    # cheese-budget opted out of codex — must NOT appear there.
    ! grep -qF $'agents/hooks/user-prompt-cheese-budget.sh\tcodex' <<<"$pairs"
}

@test "install-shared-assets.sh clears stale +x when source is no longer executable" {
    # A previous deploy left the target executable; the source has since
    # become a plain file (e.g. script demoted to data). cp -f preserves
    # the destination mode, so without an explicit chmod -x the target
    # would keep its old +x bit.
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    local src="$TEST_HOME/now-plain.md"
    echo "# bank" > "$src"
    chmod 644 "$src"
    local target="$TEST_HOME/out/now-plain.md"

    # Pre-existing executable target from a prior deploy.
    mkdir -p "$(dirname "$target")"
    echo "stale" > "$target"
    chmod 755 "$target"
    [[ -x "$target" ]]

    run bash "$installer" "$src" "$target"
    assert_success
    [[ ! -x "$target" ]]
}

# ── codex backend: abort on unparseable user-owned config ──────────────

@test "hook_codex_apply aborts with diagnostic when existing config.toml is unparseable" {
    # A user's broken TOML must not be silently overwritten with the synced
    # block. The previous behaviour fell through to '{}' on parse error,
    # destroying every other top-level key.
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
this is = not valid = TOML at all
[[hooks.SessionStart
TOML
    local before; before=$(cat "$CODEX_CONFIG_FILE")

    run hook_codex_apply session-start-cheese-flair
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"refusing to overwrite unparseable"* ]]
    # File must be untouched.
    [[ "$(cat "$CODEX_CONFIG_FILE")" == "$before" ]]
}

@test "hook_codex_apply treats an empty config.toml as fresh {} (first-time install)" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    : > "$CODEX_CONFIG_FILE"   # zero-byte file
    run hook_codex_apply session-start-cheese-flair
    assert_success
    [[ -s "$CODEX_CONFIG_FILE" ]]
    grep -q 'SessionStart' "$CODEX_CONFIG_FILE"
}

# ── safety guards added in PR #188 ──
# These exercise the round-trip read-back + top-level key-preservation
# checks that protect the user's codex config from silent truncation. The
# refusal paths share the diagnostic "refusing to overwrite" so tests
# match on that plus the file's untouched contents.

@test "hook_codex_apply preserves unrelated top-level keys (approval_policy)" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
approval_policy = "on-request"
sandbox_mode = "read-only"
TOML
    run hook_codex_apply session-start-cheese-flair
    assert_success
    grep -q 'approval_policy' "$CODEX_CONFIG_FILE"
    grep -q 'sandbox_mode' "$CODEX_CONFIG_FILE"
    grep -q 'SessionStart' "$CODEX_CONFIG_FILE"
}

@test "hook_codex_apply preserves [mcp_servers] across the sync" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]
TOML
    run hook_codex_apply session-start-cheese-flair
    assert_success
    grep -q 'mcp_servers' "$CODEX_CONFIG_FILE"
    grep -q 'context7' "$CODEX_CONFIG_FILE"
    grep -q 'SessionStart' "$CODEX_CONFIG_FILE"
}

@test "hook_codex_apply refuses to overwrite when emitted TOML is empty (sanity)" {
    # Stub yq inside this test only — the json→toml emit step produces empty
    # output but exits 0, so the temp file written back is empty. The
    # post-image read-back then fails on `keys` of the null doc, which is the
    # branch this test pins.
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
approval_policy = "on-request"
TOML
    local before; before=$(cat "$CODEX_CONFIG_FILE")
    # Resolve the real yq before PATH is shadowed, so the stub can delegate
    # every non-emit call to it on any platform (Homebrew Intel/ARM, Linux CI).
    local real_yq; real_yq=$(command -v yq)
    local stub_bin="$BATS_TEST_TMPDIR/stub-bin"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/yq" <<STUB
#!/bin/bash
# Pass through for everything except the json→toml emit step, which we
# silently truncate to exercise the post-image validation.
for arg in "\$@"; do
    if [[ "\$arg" == "-p=json" ]]; then
        # consume stdin so the pipeline doesn't SIGPIPE the caller
        cat >/dev/null
        # produce empty output
        exit 0
    fi
done
exec "$real_yq" "\$@"
STUB
    chmod +x "$stub_bin/yq"
    PATH="$stub_bin:$PATH" run hook_codex_apply session-start-cheese-flair
    [[ "$status" -ne 0 ]]
    # Must fail on the post-image read-back, not the pre-image read. Matching
    # the specific diagnostic prevents a regression to the earlier branch
    # (which emits "refusing to overwrite unparseable") from passing silently.
    [[ "$output" == *"failed to read back"* ]]
    # Original file must be untouched.
    [[ "$(cat "$CODEX_CONFIG_FILE")" == "$before" ]]
}

# ── end-to-end: installer + sync mirror chezmoi run_onchange behaviour ──
# Reimplements the registry-driven iteration the chezmoi template runs
# against a fake $HOME, then asserts every (asset × harness) pair landed
# at the expected path with the right mode and the Codex TOML carries the
# expected matcher/command/timeout. Locks acceptance criterion #1 at the
# integration level — a regression in the iteration logic, INSTALLER
# resolution, or sync.sh upsert would fail this test.
@test "chezmoi installer flow deploys every registry asset and writes the expected Codex TOML block" {
    local installer="$REAL_DOTFILES_DIR/chezmoi/lib/install-shared-assets.sh"
    local sync_script="$REAL_DOTFILES_DIR/agents/hooks/sync.sh"
    local source_root="$REAL_DOTFILES_DIR"
    local registry="$source_root/agents/hooks/registry.yaml"

    # Mirror run_onchange_after_install-hooks.sh.tmpl: iterate every
    # (asset × harness) pair declared in the registry.
    local pairs deployed_count
    pairs=$(yq -p=yaml -o=json '.hooks' "$registry" | jq -r '
        to_entries[]
        | .value as $h
        | ($h.harnesses // ["claude","codex"])[] as $harness
        | ([$h.script] + ($h.shared_assets // []))[] as $asset
        | "\($asset)\t\($harness)"
    ' | LC_ALL=C sort -u)
    deployed_count=0
    while IFS=$'\t' read -r asset harness; do
        [[ -z "$asset" ]] && continue
        local rel="${asset#agents/}"
        local target="$HOME/.$harness/$rel"
        bash "$installer" "$source_root/$asset" "$target"
        [[ -f "$target" ]]
        # The hook script lives under hooks/ and must stay executable;
        # everything else (lib, reference bank) must be plain.
        case "$rel" in
            hooks/*) [[ -x "$target" ]] ;;
            *)       [[ ! -x "$target" ]] ;;
        esac
        deployed_count=$((deployed_count + 1))
    done <<<"$pairs"

    # cheese-flair entry contributes 3 assets × 2 harnesses = 6 today.
    # The assertion is bounded but the iteration is generic: adding a
    # second hook will increase the count without breaking the test.
    [[ "$deployed_count" -ge 6 ]]

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
    [[ "$cmd"     == '"bash \"$HOME/.codex/hooks/session-start-cheese-flair.sh\""' ]]
    [[ "$timeout" == "5" ]]

    # Claude side mirror — the sync wrote a SessionStart entry into the fake
    # settings file pointing at the deployed hook.
    [[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$fake_claude")" == 'bash "$HOME/.claude/hooks/session-start-cheese-flair.sh"' ]]
    [[ "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$fake_claude")" == "5" ]]
}
