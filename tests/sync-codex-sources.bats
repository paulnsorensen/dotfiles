#!/usr/bin/env bats
# Behavioural tests for the codex chezmoi source assembly
# (sync_codex_chezmoi_sources in .sync-lib.sh) and the config.toml merge script
# (chezmoi/private_dot_codex/modify_private_config.toml) — spec: chezmoi-authoritative-codex.
#
# The load-critical properties, in order of how much they'd cost to get wrong:
#   1. the merge PRESERVES Codex-CLI runtime state (projects trust, hooks.state
#      approval hashes, marketplaces, plugins) — clobbering it re-prompts every
#      hook approval and forgets every trusted project;
#   2. the merge EVICTS an MCP server dropped from the registry (the serena
#      class of bug that install-codex.sh could never fix);
#   3. hooks.json is an object with a `hooks` map and absolute commands;
#   4. the read-only predicate matches the pinned `cheese profile compile`

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    # Public-engine parity is part of the standard gate, not an optional
    # developer-local check. CI provisions the pinned cheese-flow entry from
    # packages/packages.yaml plus jq/yq before invoking Bats; a missing tool
    # must fail the gate instead of silently skipping every parity assertion.
    local prerequisite
    for prerequisite in yq jq cheese; do
        if ! command -v "$prerequisite" >/dev/null 2>&1; then
            printf 'required Codex parity prerequisite missing: %s\n' "$prerequisite" >&2
            return 1
        fi
    done
    MERGE="$REAL_DOTFILES_DIR/chezmoi/private_dot_codex/modify_private_config.toml"
    export MERGE
    export CHEZMOI_SOURCE_DIR="$REAL_DOTFILES_DIR/chezmoi"
}

teardown() { teardown_test_env; }

# ── merge: runtime-state preservation ───────────────────────────────────────

@test "modify_config.toml preserves Codex-CLI runtime state" {
    local live="$TEST_HOME/live.toml"
    cat >"$live" <<'EOF'
model = "stale-model"
model_instructions_file = "/home/u/.codex/preamble.md"

[projects."/home/u/Dev/thing"]
trust_level = "trusted"

[hooks.state."/home/u/.codex/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:deadbeef"

[marketplaces.hallouminate]
source_type = "local"

[plugins."hallouminate@hallouminate"]
enabled = true

[tui]
model_availability_nux = { "gpt-5.5" = 4 }
EOF

    run --separate-stderr sh "$MERGE" <"$live"
    [ "$status" -eq 0 ]
    local out="$TEST_HOME/out.toml"
    printf '%s' "$output" >"$out"

    # Every runtime table survives untouched.
    [ "$(yq -p=toml -oy -r '.projects."/home/u/Dev/thing".trust_level' "$out")" = "trusted" ]
    [ "$(yq -p=toml -oy -r '.hooks.state."/home/u/.codex/hooks.json:pre_tool_use:0:0".trusted_hash' "$out")" = "sha256:deadbeef" ]
    [ "$(yq -p=toml -oy -r '.marketplaces.hallouminate.source_type' "$out")" = "local" ]
    [ "$(yq -p=toml -oy -r '.plugins."hallouminate@hallouminate".enabled' "$out")" = "true" ]
    # tui is DEEP-merged: the declared input_mode lands without evicting the
    # CLI's own nux counters.
    [ "$(yq -p=toml -oy -r '.tui.input_mode' "$out")" = "vim" ]
    [ "$(yq -p=toml -oy -r '.tui.model_availability_nux."gpt-5.5"' "$out")" = "4" ]
    # An undeclared root scalar owned by another sync leg is preserved.
    [ "$(yq -p=toml -oy -r '.model_instructions_file' "$out")" = "/home/u/.codex/preamble.md" ]
    # Declared routing and protected execution policy stay exact.
    [ "$(yq -p=toml -oy -r '.model' "$out")" = "gpt-5.6-terra" ]
    [ "$(yq -p=toml -oy -r '.model_reasoning_effort' "$out")" = "medium" ]
    [ "$(yq -p=toml -oy -r '.approval_policy' "$out")" = "on-request" ]
    [ "$(yq -p=toml -oy -r '.approvals_reviewer' "$out")" = "guardian_subagent" ]
    [ "$(yq -p=toml -oy -r '.sandbox_mode' "$out")" = "workspace-write" ]
    [ "$(yq -p=toml -oy -r '.sandbox_workspace_write.network_access' "$out")" = "true" ]
    [ "$(yq -p=toml -oy -r '.service_tier' "$out")" = "default" ]
    # A declared key overrides live drift.
    [ "$(yq -p=toml -oy -r '.model' "$out")" != "stale-model" ]
}

@test "modify_config.toml bounds runtime agents without colliding with selected agents" {
    local live="$TEST_HOME/live.toml"
    cat >"$live" <<'EOF'
[agents]
max_threads = 64
max_depth = 4
custom_runtime_key = "keep"
EOF

    run --separate-stderr sh "$MERGE" <"$live"
    [ "$status" -eq 0 ]
    printf '%s' "$output" >"$TEST_HOME/out.toml"
    [ "$(yq -p=toml -oy -r '.agents.max_threads' "$TEST_HOME/out.toml")" = "32" ]
    [ "$(yq -p=toml -oy -r '.agents.max_depth' "$TEST_HOME/out.toml")" = "1" ]
    [ "$(yq -p=toml -oy -r '.agents.custom_runtime_key' "$TEST_HOME/out.toml")" = "keep" ]
    [ "$(yq -oy -r '.codex.agents | type' "$CHEZMOI_SOURCE_DIR/.chezmoidata/codex.yaml")" = "!!seq" ]
    [ "$(yq -p=toml -oy -r '.model_context_window // "ABSENT"' "$TEST_HOME/out.toml")" = "ABSENT" ]
    [ "$(yq -p=toml -oy -r '.model_auto_compact_token_limit // "ABSENT"' "$TEST_HOME/out.toml")" = "ABSENT" ]
}

@test "modify_config.toml evicts an MCP server absent from the registry" {
    local live="$TEST_HOME/live.toml"
    cat >"$live" <<'EOF'
[mcp_servers.serena]
command = "serena"
args = ["start-mcp-server"]

[mcp_servers.tilth]
command = "tilth"
EOF

    run --separate-stderr sh "$MERGE" <"$live"
    [ "$status" -eq 0 ]
    local out="$TEST_HOME/out.toml"
    printf '%s' "$output" >"$out"

    # The registry does not declare serena -> it must be gone, not backfilled.
    [ "$(yq -p=toml -oy -r '.mcp_servers.serena // "ABSENT"' "$out")" = "ABSENT" ]
    [ "$(yq -p=toml -oy -r '.mcp_servers.tilth.command' "$out")" = "tilth" ]
}

@test "modify_config.toml seeds a fresh machine from empty stdin" {
    run --separate-stderr sh "$MERGE" </dev/null
    [ "$status" -eq 0 ]
    local out="$TEST_HOME/out.toml"
    printf '%s' "$output" >"$out"
    [ "$(yq -p=toml -oy -r '.approval_policy' "$out")" = "on-request" ]
    [ "$(yq -p=toml -oy -r '.mcp_servers.tilth.command' "$out")" = "tilth" ]
}

@test "modify_config.toml leaves an unparseable live file untouched" {
    local live="$TEST_HOME/bad.toml"
    printf 'this is [not valid = toml\n' >"$live"
    run --separate-stderr sh "$MERGE" <"$live"
    # Fail safe: emit the original bytes rather than a partial document that
    # would cost the user their trust state.
    [ "$status" -eq 0 ]
    [[ "$output" == *"this is [not valid = toml"* ]]
    [[ "$stderr" == *"not parseable TOML"* ]]
}

@test "modify_config.toml pins npx MCP args (no floats)" {
    run --separate-stderr sh "$MERGE" </dev/null
    [ "$status" -eq 0 ]
    printf '%s' "$output" >"$TEST_HOME/out.toml"
    local args
    args=$(yq -p=toml -oj '.mcp_servers | to_entries' "$TEST_HOME/out.toml")
    # No entry may float on @latest or an unversioned npm package.
    run bash -c "printf '%s' '$args' | grep -c '@latest' || true"
    [ "$output" = "0" ]
}

@test "modify_config.toml removes managed legacy hooks without touching runtime or user hooks" {
    local live="$TEST_HOME/live.toml"
    cat >"$live" <<'EOF'
[hooks.state."/home/u/.codex/hooks.json:session_start:0:0"]
trusted_hash = "sha256:deadbeef"

[[hooks.SessionStart]]
matcher = "startup|resume"
[[hooks.SessionStart.hooks]]
type = "command"
command = "bash $HOME/.codex/hooks/session-start-cheese-flair.sh"
timeout = 5

[[hooks.SessionStart]]
matcher = "resume"
[[hooks.SessionStart.hooks]]
type = "command"
command = "bash \"$HOME/.codex/hooks/session-start-cheese-flair.sh\""

[[hooks.SessionStart]]
matcher = "startup"
[[hooks.SessionStart.hooks]]
type = "command"
command = "bash /opt/user/custom-startup.sh"

[[hooks.PreToolUse]]
matcher = "Bash"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "bash \"$HOME/.codex/hooks/git-guard.sh\""

[[hooks.PreToolUse]]
matcher = "Read"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "bash /opt/user/custom-pre-tool.sh"
EOF

    run --separate-stderr sh "$MERGE" <"$live"
    [ "$status" -eq 0 ]
    printf '%s' "$output" >"$TEST_HOME/out.toml"
    [ "$(yq -p=toml -oy -r '.hooks.state."/home/u/.codex/hooks.json:session_start:0:0".trusted_hash' "$TEST_HOME/out.toml")" = "sha256:deadbeef" ]
    [ "$(yq -p=toml -oy -r '.hooks.SessionStart | length' "$TEST_HOME/out.toml")" = "1" ]
    [ "$(yq -p=toml -oy -r '.hooks.SessionStart[0].hooks[0].command' "$TEST_HOME/out.toml")" = "bash /opt/user/custom-startup.sh" ]
    [ "$(yq -p=toml -oy -r '.hooks.PreToolUse | length' "$TEST_HOME/out.toml")" = "1" ]
    [ "$(yq -p=toml -oy -r '.hooks.PreToolUse[0].hooks[0].command' "$TEST_HOME/out.toml")" = "bash /opt/user/custom-pre-tool.sh" ]
}

# ── assembly: hooks.json shape ──────────────────────────────────────────────

@test "assembled hooks.json is an object with a hooks map, not a flat array" {
    source "$REAL_DOTFILES_DIR/.sync-lib.sh"
    run _cz_codex_hooks_json "$REAL_DOTFILES_DIR/agents/hooks/registry.yaml" "/h/.codex/hooks"
    [ "$status" -eq 0 ]
    # Codex rejects a flat array even though it parses as JSON.
    [ "$(printf '%s' "$output" | jq -r 'type')" = "object" ]
    [ "$(printf '%s' "$output" | jq -r '.hooks | type')" = "object" ]
    [ "$(printf '%s' "$output" | jq -r '.hooks.PreToolUse | type')" = "array" ]
}

@test "assembled hooks.json uses absolute commands and only codex hooks" {
    source "$REAL_DOTFILES_DIR/.sync-lib.sh"
    run _cz_codex_hooks_json "$REAL_DOTFILES_DIR/agents/hooks/registry.yaml" "/h/.codex/hooks"
    [ "$status" -eq 0 ]
    # Codex runs hook commands from the session cwd, so a relative path never
    # resolves — every command must be absolute.
    local relatives
    relatives=$(printf '%s' "$output" | jq -r '[.hooks[][].hooks[].command | select(startswith("bash /") | not)] | length')
    [ "$relatives" -eq 0 ]
    # tool-reroute is harnesses:[claude] (5f78a0f) and must not leak into codex.
    run bash -c "printf '%s' '$output' | grep -c tool-reroute || true"
    [ "$output" = "0" ]
}

# ── assembly: read-only predicate parity ────────────────────────────────────

@test "codex read-only predicate matches cheese profile compile output" {
    # cheese is required by setup; parity never silently skips.
    source "$REAL_DOTFILES_DIR/.sync-lib.sh"
    local baseline="$TEST_HOME/cheese-profile-baseline"
    local output_root
    output_root=$(mktemp -d "${TEST_HOME}.cheese-profile.XXXXXX")
    mkdir -p "$baseline"

    # Profile resolution requires every git-backed plugin cache boundary and
    # marketplace declaration to exist. Empty plugin payloads are sufficient
    # because this parity test compares dotfiles-owned agent sandbox
    # projections, not external plugin content.
    local plugin plugin_root
    while IFS= read -r plugin; do
        plugin_root="$HOME/.cache/cheese-flow/plugins/$plugin"
        mkdir -p "$plugin_root/.claude-plugin"
        jq -n --arg name "$plugin" '{name: $name, plugins: [{name: $name, source: "./"}]}' > "$plugin_root/.claude-plugin/marketplace.json"
    done < <(
        yq -r '.plugins | to_entries[] | select(.value.git and (.value.path == null)) | .key' \
            "$REAL_DOTFILES_DIR/agents/plugins/registry.yaml"
    )

    # The engine's published generation is the behavioral ground truth. The
    # source root is explicit; baseline and publication are independent
    # control trees, matching the public compile contract.
    run cheese profile compile live --source-root "$REAL_DOTFILES_DIR" --baseline "$baseline" --output "$output_root"
    [ "$status" -eq 0 ] || {
        echo "$output" >&2
        return 1
    }

    local manifest="$output_root/manifest.json"
    assert_file_exists "$manifest"
    local generation
    generation=$(jq -r '.generation // empty' "$manifest")
    [ -n "$generation" ]

    local reg="$REAL_DOTFILES_DIR/agents/registry.yaml"
    local codex_reg="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/codex.yaml"
    local name fragment engine_toml expected_toml engine_mode expected_mode
    while read -r name; do
        [ -z "$name" ] && continue
        fragment=$(jq -r --arg name "$name" '
            .files[]
            | select(
                .harness == "codex"
                and .destination_path == (".codex/agents/" + $name + ".toml")
            )
            | .fragment_path
        ' "$manifest")
        [ -n "$fragment" ] || {
            echo "cheese profile compile emitted no Codex fragment for $name" >&2
            return 1
        }
        engine_toml="$output_root/$fragment"
        assert_file_exists "$engine_toml"

        expected_toml="$TEST_HOME/$name.toml"
        _cz_render_codex_agent "$reg" "$name" "$REAL_DOTFILES_DIR" "$expected_toml"
        engine_mode=$(yq -p=toml -oy -r '.sandbox_mode // "none"' "$engine_toml")
        expected_mode=$(yq -p=toml -oy -r '.sandbox_mode // "none"' "$expected_toml")
        [ "$engine_mode" = "$expected_mode" ] || {
            echo "read-only drift for $name: cheese=$engine_mode bash=$expected_mode" >&2
            return 1
        }
    done < <(yq -r '.codex.agents // [] | .[]' "$codex_reg")
    rm -rf "$output_root"
}

@test "an agent keeping tilth_write is not sandboxed read-only" {
    source "$REAL_DOTFILES_DIR/.sync-lib.sh"
    local reg="$REAL_DOTFILES_DIR/agents/registry.yaml"
    # coder bans Edit/Write/NotebookEdit but mutates the tree through
    # mcp__tilth__tilth_write — sandboxing it read-only breaks its whole job.
    _cz_render_codex_agent "$reg" coder "$REAL_DOTFILES_DIR" "$TEST_HOME/coder.toml"
    [ "$(yq -p=toml -oy -r '.sandbox_mode // "none"' "$TEST_HOME/coder.toml")" = "none" ]
    # whey-drainer's [Bash, Read] whitelist grants no writer at all.
    _cz_render_codex_agent "$reg" whey-drainer "$REAL_DOTFILES_DIR" "$TEST_HOME/wd.toml"
    [ "$(yq -p=toml -oy -r '.sandbox_mode' "$TEST_HOME/wd.toml")" = "read-only" ]
}

@test "designated read-only agents render with Codex read-only sandboxes" {
    source "$REAL_DOTFILES_DIR/.sync-lib.sh"
    local reg="$REAL_DOTFILES_DIR/agents/registry.yaml"
    local name
    for name in ghostbuster nih-scanner; do
        _cz_render_codex_agent "$reg" "$name" "$REAL_DOTFILES_DIR" "$TEST_HOME/$name.toml"
        [ "$(yq -p=toml -oy -r '.sandbox_mode' "$TEST_HOME/$name.toml")" = "read-only" ]
    done
}

@test "rendered codex agent carries the registry model and a TOML body" {
    source "$REAL_DOTFILES_DIR/.sync-lib.sh"
    local reg="$REAL_DOTFILES_DIR/agents/registry.yaml"
    _cz_render_codex_agent "$reg" whey-drainer "$REAL_DOTFILES_DIR" "$TEST_HOME/wd.toml"
    local expected
    expected=$(yq -oy -r '.agents.whey-drainer.models.codex' "$reg")
    [ "$(yq -p=toml -oy -r '.model' "$TEST_HOME/wd.toml")" = "$expected" ]
    [ "$(yq -p=toml -oy -r '.name' "$TEST_HOME/wd.toml")" = "whey-drainer" ]
    # The instruction body rides through as a TOML string, escaping intact.
    [ -n "$(yq -p=toml -oy -r '.developer_instructions' "$TEST_HOME/wd.toml")" ]
}

@test "assembly fails loud when the registry selects an unknown agent" {
    source "$REAL_DOTFILES_DIR/.sync-lib.sh"
    local root="$TEST_HOME/dotfiles"
    mkdir -p "$root/chezmoi/.chezmoidata" "$root/agents/hooks"
    cp "$REAL_DOTFILES_DIR/agents/registry.yaml" "$root/agents/registry.yaml"
    cp "$REAL_DOTFILES_DIR/agents/hooks/registry.yaml" "$root/agents/hooks/registry.yaml"
    printf 'codex:\n  agents:\n    - no-such-agent\n' >"$root/chezmoi/.chezmoidata/codex.yaml"

    run sync_codex_chezmoi_sources "$root" "$root/chezmoi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown agent"* ]]
}
