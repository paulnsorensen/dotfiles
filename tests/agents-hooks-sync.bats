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

@test "sensitive-file-guard is a claude+codex PreToolUse hook with its lib asset" {
    local entry
    entry=$(yq -o=json '.hooks."sensitive-file-guard"' "$REGISTRY_FILE")
    [[ "$(jq -r '.event'  <<<"$entry")" == "PreToolUse" ]]
    [[ "$(jq -r '.script' <<<"$entry")" == "agents/hooks/sensitive-file-guard.sh" ]]
    [[ "$(jq -r '.shared_assets[0]' <<<"$entry")" == "agents/lib/sensitive-file-guard.js" ]]
    [[ "$(jq -r '.matcher' <<<"$entry")" == *"Bash"* ]]
    [[ "$(jq -r '.matcher' <<<"$entry")" == *"apply_patch"* ]]   # codex file edits
    [[ "$(jq -r '.matcher' <<<"$entry")" == *"mcp__tilth__tilth_write"* ]]
    [[ "$(jq -r '.harnesses | length' <<<"$entry")" == "2" ]]
    [[ "$(jq -r '.harnesses | index("claude")' <<<"$entry")" != "null" ]]
    [[ "$(jq -r '.harnesses | index("codex")'  <<<"$entry")" != "null" ]]
    assert_file_exists "$REAL_DOTFILES_DIR/agents/hooks/sensitive-file-guard.sh"
    assert_file_exists "$REAL_DOTFILES_DIR/agents/lib/sensitive-file-guard.js"
}

@test "sensitive-file-guard is present for both claude and codex after filtering" {
    local c x
    c=$(hook_filter_for_harness claude "$REGISTRY_JSON")
    x=$(hook_filter_for_harness codex  "$REGISTRY_JSON")
    [[ "$(jq -r 'has("sensitive-file-guard")' <<<"$c")" == "true" ]]
    [[ "$(jq -r 'has("sensitive-file-guard")' <<<"$x")" == "true" ]]
}

@test "registry command entries carry no machine-specific absolute paths" {
    # Issue #263: the moshi hooks hardcoded '/home/paul/.local/bin/moshi-hook',
    # so all four fired against a nonexistent path every session on macOS.
    # command: entries must be PATH-resolved (bare) or platform-neutral —
    # never /home/* or /Users/*.
    local cmds
    cmds=$(yq -r '.hooks[] | select(has("command")) | .command' "$REGISTRY_FILE")
    run grep -E '(/home/|/Users/)' <<<"$cmds"
    if [[ "$status" -eq 0 ]]; then
        echo "machine-specific paths in registry commands:" >&2
        echo "$output" >&2
        return 1
    fi
}

@test "moshi registry entries are portable, claude-only, and complete" {
    local entry name
    for name in moshi-session-start moshi-user-prompt-submit moshi-stop moshi-permission-request; do
        entry=$(yq -o=json ".hooks.\"$name\"" "$REGISTRY_FILE")
        [[ "$(jq -r '.command' <<<"$entry")" == "moshi-hook claude-hook" ]]
        [[ "$(jq -r '.harnesses | length' <<<"$entry")" == "1" ]]
        [[ "$(jq -r '.harnesses[0]' <<<"$entry")" == "claude" ]]
    done
    # Synchronous approval hook keeps its 5-minute phone-reach window.
    entry=$(yq -o=json '.hooks."moshi-permission-request"' "$REGISTRY_FILE")
    [[ "$(jq -r '.async' <<<"$entry")" == "false" ]]
    [[ "$(jq -r '.timeout' <<<"$entry")" == "300" ]]
}

@test "macOS gets the moshi-hook binary via packages.yaml" {
    # Issue #263, second half: a portable command still fails if the binary
    # is never provisioned. The registry's moshi hooks rely on the brew
    # package on the Mac (linux uses Moshi's own installer to ~/.local/bin).
    local entry
    entry=$(yq -o=json '.packages[] | select(kind == "map") | to_entries[0] | select(.key == "rjyo/moshi/moshi-hook")' \
        "$REAL_DOTFILES_DIR/packages/packages.yaml")
    [[ -n "$entry" ]]
    [[ "$(jq -r '.value.platform' <<<"$entry")" == "mac" ]]
}

@test "sensitive-file-guard renders a runnable bash command under both harnesses" {
    local sc sx
    sc=$(hook_desired_signature sensitive-file-guard claude)
    sx=$(hook_desired_signature sensitive-file-guard codex)
    # Must invoke the .sh (bash-runnable under both deploy paths), NOT the
    # .js directly — a `bash <file>.js` command would not execute.
    [[ "$sc" == 'bash "$HOME/.claude/hooks/sensitive-file-guard.sh"'* ]]
    [[ "$sx" == 'bash "$HOME/.codex/hooks/sensitive-file-guard.sh"'* ]]
    [[ "$sc" == *$'\t'"PreToolUse"$'\t'* ]]
    [[ "$sx" == *$'\t'"PreToolUse"$'\t'* ]]
}

@test "hook_filter_for_harness includes the entry for both claude and codex" {
    local c x
    c=$(hook_filter_for_harness claude "$REGISTRY_JSON")
    x=$(hook_filter_for_harness codex  "$REGISTRY_JSON")
    # cheese-flair is registered for both harnesses.
    [[ "$(jq -r '.["session-start-cheese-flair"].event' <<<"$c")" == "SessionStart" ]]
    [[ "$(jq -r '.["session-start-cheese-flair"].event' <<<"$x")" == "SessionStart" ]]
    # The claude-only moshi entries appear for claude but are filtered out for
    # codex — proves the per-entry `harnesses` filter, not just inclusion.
    [[ "$(jq -r 'has("moshi-session-start")' <<<"$c")" == "true"  ]]
    [[ "$(jq -r 'has("moshi-session-start")' <<<"$x")" == "false" ]]
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
    # Signature shape: <resolved-command> <event> <matcher> <timeout> <async>.
    # event so two entries pointing at the same script/command but different
    # event slots don't collide; async claude-only (empty for codex). The
    # cheese-flair entry has no async, so the final field is empty for both.
    [[ "$c" == 'bash "$HOME/.claude/hooks/session-start-cheese-flair.sh"'$'\t'"SessionStart"$'\t'"startup|resume"$'\t'"5"$'\t' ]]
    [[ "$x" == 'bash "$HOME/.codex/hooks/session-start-cheese-flair.sh"'$'\t'"SessionStart"$'\t'"startup|resume"$'\t'"5"$'\t' ]]
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
    [[ "$sig" == $'\t\t\t\t' ]]
}

@test "hook_claude_current_signature reports empty when entry missing" {
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    local sig
    sig=$(hook_claude_current_signature session-start-cheese-flair)
    [[ "$sig" == $'\t\t\t\t' ]]
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
    # 5-field signature ends in <timeout> <async>; cheese-flair has no
    # async on disk, so the trailing field is empty (final tab).
    [[ "$cur" == *$'\t'"99"$'\t' ]]
}

# Scope detection to the single cheese-flair entry so the assertions stay
# decoupled from the registry's entry count (it also carries claude-only
# moshi-* command hooks, which would otherwise show as drift here).
@test "hook_detect_changes (claude): empty when in sync" {
    HARNESS_DESIRED_JSON=$(jq '{"session-start-cheese-flair": .["session-start-cheese-flair"]}' <<<"$HARNESS_DESIRED_JSON")
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply session-start-cheese-flair
    local changed
    changed=$(hook_detect_changes claude)
    [[ -z "$changed" ]]
}

@test "hook_detect_changes (claude): names entry when missing" {
    HARNESS_DESIRED_JSON=$(jq '{"session-start-cheese-flair": .["session-start-cheese-flair"]}' <<<"$HARNESS_DESIRED_JSON")
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
    # Apply every desired codex hook so the whole set is in sync (codex now
    # carries session-start AND sensitive-file-guard).
    local name
    while read -r name; do
        [[ -z "$name" ]] && continue
        hook_codex_apply "$name"
    done < <(jq -r 'keys[]' <<<"$HARNESS_DESIRED_JSON")
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
    # Bring the other codex hooks (sensitive-file-guard, git-guard) in sync so
    # only the session-start timeout drift remains to be detected.
    hook_codex_apply sensitive-file-guard
    hook_codex_apply git-guard
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

    # Claude side upserted — the cheese-flair SessionStart entry is present.
    # (Asserted by content, not count: the registry also carries a claude-only
    # moshi-session-start entry, so SessionStart now holds more than one block.)
    [[ "$(jq '[.hooks.SessionStart[] | select((.hooks[0].command // "") | test("session-start-cheese-flair"))] | length' "$CLAUDE_SETTINGS_FILE")" == "1" ]]
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

# ── multi-event support (UserPromptSubmit / PreToolUse / PostToolUse / Stop)
# These tests exercise the parameterized event slot in lib.sh by synthesizing
# a HARNESS_DESIRED_JSON for each new event type. The cheese-flair registry
# entry stays SessionStart-only; these synthetic registries are scoped to
# the tests below so the real registry contract is unchanged.

@test "claude upsert writes UserPromptSubmit slot (no matcher in outer block)" {
    HARNESS_DESIRED_JSON='{"prompt-stamp":{"event":"UserPromptSubmit","script":"agents/hooks/prompt-stamp.sh","timeout":3}}'
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply prompt-stamp

    local cmd timeout matcher
    cmd=$(jq -r     '.hooks.UserPromptSubmit[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    timeout=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].timeout' "$CLAUDE_SETTINGS_FILE")
    matcher=$(jq -r '.hooks.UserPromptSubmit[0].matcher // "MISSING"' "$CLAUDE_SETTINGS_FILE")
    [[ "$cmd"     == 'bash "$HOME/.claude/hooks/prompt-stamp.sh"' ]]
    [[ "$timeout" == "3" ]]
    # UserPromptSubmit on claude has no outer matcher — must be absent.
    [[ "$matcher" == "MISSING" ]]
    # SessionStart slot must NOT have grown.
    [[ "$(jq '.hooks.SessionStart // [] | length' "$CLAUDE_SETTINGS_FILE")" == "0" ]]
}

@test "claude upsert writes PreToolUse slot WITH matcher in outer block" {
    HARNESS_DESIRED_JSON='{"tool-audit":{"event":"PreToolUse","script":"agents/hooks/tool-audit.sh","matcher":"Bash|Edit","timeout":10}}'
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply tool-audit

    local cmd matcher timeout
    cmd=$(jq -r     '.hooks.PreToolUse[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    matcher=$(jq -r '.hooks.PreToolUse[0].matcher'          "$CLAUDE_SETTINGS_FILE")
    timeout=$(jq -r '.hooks.PreToolUse[0].hooks[0].timeout' "$CLAUDE_SETTINGS_FILE")
    [[ "$cmd"     == 'bash "$HOME/.claude/hooks/tool-audit.sh"' ]]
    [[ "$matcher" == "Bash|Edit" ]]
    [[ "$timeout" == "10" ]]
}

@test "claude upsert writes Stop slot (no matcher)" {
    HARNESS_DESIRED_JSON='{"turn-end":{"event":"Stop","script":"agents/hooks/turn-end.sh"}}'
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply turn-end

    local cmd matcher
    cmd=$(jq -r     '.hooks.Stop[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    matcher=$(jq -r '.hooks.Stop[0].matcher // "MISSING"' "$CLAUDE_SETTINGS_FILE")
    [[ "$cmd"     == 'bash "$HOME/.claude/hooks/turn-end.sh"' ]]
    [[ "$matcher" == "MISSING" ]]
}

@test "claude upserts in different event slots coexist (one entry per slot)" {
    HARNESS_DESIRED_JSON='{
      "ss":     {"event":"SessionStart",     "script":"agents/hooks/ss.sh"},
      "ups":    {"event":"UserPromptSubmit", "script":"agents/hooks/ups.sh"},
      "pre":    {"event":"PreToolUse",       "script":"agents/hooks/pre.sh",  "matcher":".*"},
      "post":   {"event":"PostToolUse",      "script":"agents/hooks/post.sh", "matcher":".*"},
      "stop":   {"event":"Stop",             "script":"agents/hooks/stop.sh"}
    }'
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply ss
    hook_claude_apply ups
    hook_claude_apply pre
    hook_claude_apply post
    hook_claude_apply stop

    # Each event slot has exactly one entry.
    for evt in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do
        local n
        n=$(jq --arg e "$evt" '.hooks[$e] | length' "$CLAUDE_SETTINGS_FILE")
        [[ "$n" == "1" ]] || { echo "event $evt has $n entries, expected 1" >&2; return 1; }
    done
}

@test "claude apply at one event slot does not disturb other event slots" {
    HARNESS_DESIRED_JSON='{"ups":{"event":"UserPromptSubmit","script":"agents/hooks/ups.sh"}}'
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash $HOME/.claude/hooks/keep-me.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "bash $HOME/.claude/hooks/turn-end.sh" }] }
    ]
  }
}
JSON
    hook_claude_apply ups

    # Untouched slots still have their pre-existing entries.
    [[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")" == 'bash $HOME/.claude/hooks/keep-me.sh' ]]
    [[ "$(jq -r '.hooks.Stop[0].hooks[0].command'         "$CLAUDE_SETTINGS_FILE")" == 'bash $HOME/.claude/hooks/turn-end.sh' ]]
    # New slot has the upserted entry.
    [[ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")" == 'bash "$HOME/.claude/hooks/ups.sh"' ]]
}

@test "codex upsert writes PreToolUse slot WITH matcher" {
    HARNESS_DESIRED_JSON='{"tool-audit":{"event":"PreToolUse","script":"agents/hooks/tool-audit.sh","matcher":"Bash|Edit","timeout":10}}'
    : > "$CODEX_CONFIG_FILE"
    hook_codex_apply tool-audit

    grep -qF '[[hooks.PreToolUse]]'                                                  "$CODEX_CONFIG_FILE"
    grep -qF 'matcher = "Bash|Edit"'                                                 "$CODEX_CONFIG_FILE"
    grep -qF 'command = "bash \"$HOME/.codex/hooks/tool-audit.sh\""'                 "$CODEX_CONFIG_FILE"
    grep -qF 'timeout = 10'                                                          "$CODEX_CONFIG_FILE"
    # SessionStart slot must NOT have been written.
    ! grep -qF '[[hooks.SessionStart]]' "$CODEX_CONFIG_FILE"
}

@test "codex upsert writes Stop slot without matcher (matcher field dropped)" {
    # Registry sets matcher but Stop on codex doesn't use one. The matcher
    # field must NOT land in the TOML — that's the contract enforced by
    # _hook_event_uses_matcher.
    HARNESS_DESIRED_JSON='{"turn-end":{"event":"Stop","script":"agents/hooks/turn-end.sh","matcher":"ignored","timeout":2}}'
    : > "$CODEX_CONFIG_FILE"
    hook_codex_apply turn-end

    grep -qF '[[hooks.Stop]]'                                                        "$CODEX_CONFIG_FILE"
    grep -qF 'command = "bash \"$HOME/.codex/hooks/turn-end.sh\""'                   "$CODEX_CONFIG_FILE"
    grep -qF 'timeout = 2'                                                           "$CODEX_CONFIG_FILE"
    ! grep -qF 'matcher = "ignored"' "$CODEX_CONFIG_FILE"
}

@test "codex multi-event upserts coexist and survive a second sync pass" {
    HARNESS_DESIRED_JSON='{
      "ups":  {"event":"UserPromptSubmit", "script":"agents/hooks/ups.sh"},
      "pre":  {"event":"PreToolUse",       "script":"agents/hooks/pre.sh",  "matcher":"Bash"},
      "stop": {"event":"Stop",             "script":"agents/hooks/stop.sh"}
    }'
    : > "$CODEX_CONFIG_FILE"
    hook_codex_apply ups
    hook_codex_apply pre
    hook_codex_apply stop
    # Second pass — re-running any apply must be a no-op (idempotent).
    hook_codex_apply ups
    hook_codex_apply pre
    hook_codex_apply stop

    for evt in UserPromptSubmit PreToolUse Stop; do
        local n
        n=$(yq -p=toml -o=json ".hooks.${evt} | length" "$CODEX_CONFIG_FILE")
        [[ "$n" == "1" ]] || { echo "event $evt has $n entries, expected 1 after idempotent re-apply" >&2; return 1; }
    done
}

@test "drift detection (claude): catches event slot mismatch" {
    # Registry says UserPromptSubmit, but the on-disk state has the entry
    # under SessionStart with the same command. Drift must be reported so
    # the next apply re-homes the entry. (The misplaced SessionStart entry
    # stays put — clearing arbitrary other-slot entries is out of scope.)
    HARNESS_DESIRED_JSON='{"prompt-stamp":{"event":"UserPromptSubmit","script":"agents/hooks/prompt-stamp.sh"}}'
    cat > "$CLAUDE_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash \"$HOME/.claude/hooks/prompt-stamp.sh\"" }] }
    ]
  }
}
JSON
    local changed
    changed=$(hook_detect_changes claude)
    [[ "$changed" == "prompt-stamp" ]]
}

# ── command-style (external binary) hooks — Moshi pattern ─────────────
# These entries bypass the deploy path: command is used verbatim and async
# (claude-only) is threaded into the inner hook entry. jq's `//` operator
# treats `false` as a fallback trigger, so async:false would silently drop
# without the has("async") guard in lib.sh — these tests pin that.

@test "claude command-style entry writes literal command (no deploy path)" {
    # Build the desired JSON via jq so the literal command — including its
    # embedded single quotes and absolute path (the Moshi registry shape) —
    # round-trips without shell-quoting hazards. The lib must write it verbatim.
    local cmd_literal="'/home/paul/.local/bin/moshi-hook' claude-hook"
    HARNESS_DESIRED_JSON=$(jq -nc --arg c "$cmd_literal" \
        '{"moshi-ss":{event:"SessionStart",command:$c,async:true,harnesses:["claude"]}}')
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply moshi-ss

    local cmd async
    cmd=$(jq -r   '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
    async=$(jq -r '.hooks.SessionStart[0].hooks[0].async'   "$CLAUDE_SETTINGS_FILE")
    [[ "$cmd"   == "$cmd_literal" ]]
    [[ "$async" == "true" ]]
    # No `bash` wrapper, no $HOME/.claude/hooks deployed path.
    [[ "$cmd" != bash* ]]
    [[ "$cmd" != *".claude/hooks"* ]]
}

@test "claude command-style entry preserves async:false (jq // bug regression)" {
    # async: false is the canary for the has("async") guard. jq's `// empty`
    # would drop it; has("async") preserves it. The PermissionRequest case
    # synchronous approval, must be `false` on the wire.
    HARNESS_DESIRED_JSON='{"moshi-pr":{"event":"PermissionRequest","command":"/bin/true","async":false,"timeout":300,"harnesses":["claude"]}}'
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply moshi-pr

    [[ "$(jq -r '.hooks.PermissionRequest[0].hooks[0].async'   "$CLAUDE_SETTINGS_FILE")" == "false" ]]
    [[ "$(jq -r '.hooks.PermissionRequest[0].hooks[0].timeout' "$CLAUDE_SETTINGS_FILE")" == "300" ]]
    [[ "$(jq -r '.hooks.PermissionRequest[0].hooks[0].type'    "$CLAUDE_SETTINGS_FILE")" == "command" ]]
}

@test "claude command-style entry omits async when registry doesn't set it" {
    HARNESS_DESIRED_JSON='{"bare":{"event":"SessionStart","command":"/bin/true","harnesses":["claude"]}}'
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply bare

    [[ "$(jq -r '.hooks.SessionStart[0].hooks[0].async // "ABSENT"' "$CLAUDE_SETTINGS_FILE")" == "ABSENT" ]]
}

@test "codex command-style entry writes literal command (no $HOME wrapper)" {
    # Codex doesn't carry async, but otherwise the command-vs-script
    # branch must work the same way.
    HARNESS_DESIRED_JSON='{"ext":{"event":"SessionStart","command":"/usr/local/bin/external-hook codex","matcher":"startup","timeout":5,"harnesses":["codex"]}}'
    : > "$CODEX_CONFIG_FILE"
    hook_codex_apply ext

    grep -qF 'command = "/usr/local/bin/external-hook codex"' "$CODEX_CONFIG_FILE"
    grep -qF 'matcher = "startup"' "$CODEX_CONFIG_FILE"
    grep -qF 'timeout = 5' "$CODEX_CONFIG_FILE"
    # No "bash \"$HOME..." prefix.
    ! grep -qF 'bash' "$CODEX_CONFIG_FILE"
}

@test "command-style entry: signature stable across desired+current after apply" {
    HARNESS_DESIRED_JSON='{"moshi-pr":{"event":"PermissionRequest","command":"/bin/true","async":false,"timeout":300,"harnesses":["claude"]}}'
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    hook_claude_apply moshi-pr
    local des cur
    des=$(hook_desired_signature       moshi-pr claude)
    cur=$(hook_claude_current_signature moshi-pr)
    [[ "$des" == "$cur" ]]
    # Resolved command in field 1 is the literal command, not a bash wrapper.
    [[ "$des" == /bin/true$'\t'"PermissionRequest"$'\t'$'\t'"300"$'\t'"false" ]]
}

@test "drift detection (claude): same script, different events => both reported" {
    # The signature includes `event`, so a script duplicated across event
    # slots is two distinct entries — drift must fire for both, not one.
    HARNESS_DESIRED_JSON='{
      "a": {"event":"SessionStart",     "script":"agents/hooks/dup.sh"},
      "b": {"event":"UserPromptSubmit", "script":"agents/hooks/dup.sh"}
    }'
    echo '{}' > "$CLAUDE_SETTINGS_FILE"
    local changed
    changed=$(hook_detect_changes claude | sort)
    [[ "$(echo "$changed" | wc -l | tr -d ' ')" == "2" ]]
    [[ "$changed" == *"a"* ]]
    [[ "$changed" == *"b"* ]]
}

@test "drift detection (codex): catches event slot mismatch" {
    HARNESS_DESIRED_JSON='{"tool-audit":{"event":"PreToolUse","script":"agents/hooks/tool-audit.sh","matcher":"Bash"}}'
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
[[hooks.SessionStart]]
matcher = "startup"

[[hooks.SessionStart.hooks]]
type = "command"
command = "bash \"$HOME/.codex/hooks/tool-audit.sh\""
TOML
    local changed
    changed=$(hook_detect_changes codex)
    [[ "$changed" == "tool-audit" ]]
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

# The standalone run_onchange_after_install-hooks chezmoi template was
# retired in curd 7: hook deployment now flows through the base-profile
# render (ap → claude/codex renderers, which copy the hook script + its
# shared_assets). The hooks sync.sh lib still backs the `hook-sync` alias
# and is exercised by the upsert/idempotence tests above; the rendered
# deploy payload is covered by agent-profile's renderer tests and
# tests/install-base-profile.bats.

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

@test "hook_filter_for_harness fails loud when an entry has an unsupported event" {
    # The whitelist HOOK_EVENTS_VALID gates what events the backends know
    # how to write. Anything outside that set must abort the sync, not
    # silently fall through to SessionStart.
    local reg='{"future":{"event":"NotAnEvent","script":"x.sh"}}'
    run hook_filter_for_harness claude "$reg"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"unsupported event"* ]]
    [[ "$output" == *"NotAnEvent"* ]]
    [[ "$output" == *"future"* ]]
}

@test "hook_filter_for_harness accepts every event in the whitelist" {
    # Locks the contract that all six whitelisted events round-trip
    # through the filter without erroring. Adding a seventh event needs
    # both HOOK_EVENTS_VALID and this test updated together.
    for evt in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop PermissionRequest; do
        local reg
        reg=$(jq -n --arg e "$evt" '{(("entry-" + $e)): {event: $e, script: "x.sh"}}')
        run hook_filter_for_harness claude "$reg"
        assert_success
        [[ "$(jq -r 'keys | length' <<<"$output")" == "1" ]]
    done
}

@test "hook_filter_for_harness rejects entries with both script and command" {
    # Mutually exclusive: script → deployed path; command → literal external.
    local reg='{"bad":{"event":"SessionStart","script":"x.sh","command":"/bin/true"}}'
    run hook_filter_for_harness claude "$reg"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"both 'script' and 'command'"* ]]
    [[ "$output" == *"bad"* ]]
}

@test "hook_filter_for_harness rejects entries with neither script nor command" {
    local reg='{"empty":{"event":"SessionStart"}}'
    run hook_filter_for_harness claude "$reg"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"neither 'script' nor 'command'"* ]]
    [[ "$output" == *"empty"* ]]
}

@test "hook_filter_for_harness accepts a command-only entry" {
    local reg='{"moshi":{"event":"SessionStart","command":"/usr/local/bin/moshi-hook claude-hook"}}'
    run hook_filter_for_harness claude "$reg"
    assert_success
    [[ "$(jq -r '.moshi.command' <<<"$output")" == "/usr/local/bin/moshi-hook claude-hook" ]]
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
    [[ "$sig" == $'\t\t\t\t' ]]
}

@test "hook_codex_current_signature reports empty when SessionStart entry missing" {
    HARNESS_DESIRED_JSON=$(hook_filter_for_harness codex "$REGISTRY_JSON")
    cat > "$CODEX_CONFIG_FILE" <<'TOML'
approval_policy = "on-request"
TOML
    local sig
    sig=$(hook_codex_current_signature session-start-cheese-flair)
    [[ "$sig" == $'\t\t\t\t' ]]
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
    # Signature ends in: <event> <current-matcher> <timeout> <async>.
    # async is empty for codex (claude-only); ends with a trailing tab.
    [[ "$cur" == *$'\t'"SessionStart"$'\t'"something-else"$'\t'"5"$'\t' ]]
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
    # Bring the other codex hooks (sensitive-file-guard, git-guard) in sync so
    # only the session-start matcher drift remains to be detected.
    hook_codex_apply sensitive-file-guard
    hook_codex_apply git-guard
    local changed
    changed=$(hook_detect_changes codex)
    [[ "$changed" == "session-start-cheese-flair" ]]
}

# ── post-migration: SessionStart wiring lives in the plugin tree ───────
#
# The committed `claude/settings.json` was retired in favor of the
# chezmoi-seeded `~/.claude/settings.json` + ap-rendered plugin tree.
# The SessionStart hook is now declared by the plugin's `plugin.json`
# (rendered by `ap install global` into
# `~/.claude/plugins/local/global/.claude-plugin/plugin.json`), not by a
# hand-written entry in the user settings file.
#
# The two old tests here ("carries the SessionStart entry with timeout 5"
# and "sync against itself is a no-op") locked the OLD behavior against
# the in-repo `claude/settings.json`. With that file gone, their
# assertions are replaced by:
#
#   - `chezmoi-wiring.bats: claude settings.json: seed has NO legacy SessionStart hook entry`
#   - `cheese-flair.bats: hook script self-locates lib + bank when ~/.claude/hooks is a directory symlink`
#   - `cheese-flair.bats: hook script output shape matches across both harnesses`
#
# which together prove the new wiring fires correctly and the seed is
# clean. Keep them mentioned here as breadcrumbs for git-blame archaeology.

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
        | (($h.script // empty), ($h.shared_assets // [])[]) as $asset
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
        | (($h.script // empty), ($h.shared_assets // [])[]) as $asset
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
    # settings file pointing at the deployed hook. Select by content, not
    # index: claude SessionStart also holds the claude-only moshi entry, so
    # position [0] is not guaranteed to be cheese-flair.
    local ss_cmd ss_timeout
    ss_cmd=$(jq -r '.hooks.SessionStart[] | select((.hooks[0].command // "") | test("session-start-cheese-flair.sh")) | .hooks[0].command' "$fake_claude")
    ss_timeout=$(jq -r '.hooks.SessionStart[] | select((.hooks[0].command // "") | test("session-start-cheese-flair.sh")) | .hooks[0].timeout' "$fake_claude")
    [[ "$ss_cmd"     == 'bash "$HOME/.claude/hooks/session-start-cheese-flair.sh"' ]]
    [[ "$ss_timeout" == "5" ]]
}

# ─── jmux-attention Stop hook (enveloped from PR #185) ───────────────────
@test "jmux attention registry entry declares Stop event for both harnesses" {
    local entry
    entry=$(yq -o=json '.hooks."jmux-attention"' "$REGISTRY_FILE")
    [[ "$(jq -r '.event'     <<<"$entry")" == "Stop" ]]
    [[ "$(jq -r '.script'    <<<"$entry")" == "agents/hooks/jmux-attention.sh" ]]
    [[ "$(jq -r '.timeout'   <<<"$entry")" == "5" ]]
    [[ "$(jq -r '.harnesses[0]' <<<"$entry")" == "claude" ]]
    [[ "$(jq -r '.harnesses[1]' <<<"$entry")" == "codex"  ]]
}

@test "jmux attention hook no-ops outside tmux" {
    local marker="$TEST_HOME/tmux-called"
    local fake_bin="$TEST_HOME/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$marker"
SH
    chmod +x "$fake_bin/tmux"

    TMUX='' PATH="$fake_bin:$PATH" run bash "$REAL_DOTFILES_DIR/agents/hooks/jmux-attention.sh"

    assert_success
    [[ "$output" == "" ]]
    [[ ! -e "$marker" ]]
}

@test "jmux attention hook marks tmux session when TMUX is set" {
    local marker="$TEST_HOME/tmux-called"
    local fake_bin="$TEST_HOME/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" > "$marker"
SH
    chmod +x "$fake_bin/tmux"

    TMUX=/tmp/fake-tmux PATH="$fake_bin:$PATH" run bash "$REAL_DOTFILES_DIR/agents/hooks/jmux-attention.sh"

    assert_success
    [[ "$output" == "" ]]
    [[ "$(< "$marker")" == "set-option -q @jmux-attention 1" ]]
}
