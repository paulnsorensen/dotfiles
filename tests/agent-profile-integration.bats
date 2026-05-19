#!/usr/bin/env bats
#
# Integration tests for agent-profile/ap — the cross-curd / cross-renderer
# seams produced by the PR #177 reshape. Per-renderer behaviour is locked
# in the per-renderer .bats files; this file targets the *interactions*:
#
#   • dispatch table wiring across all 5 harnesses in one install
#   • _AP_OUT_FILES accumulation + dedup of cross-harness shared paths
#     (`.claude/agents/<n>.md`, `.agents/skills/<n>/`) across multiple
#     renderers writing the same path in a single install run
#   • ap_manifest_diff_and_clean wired into cmd_install: re-install
#     orphan cleanup actually runs end-to-end
#   • Multi-profile install + uninstall via cmd_install: shared paths
#     ref-counted on uninstall (not the isolated manifest helper test)
#   • Manifest shape preserved across the full dispatch loop (no entry
#     duplication, files list deduped)
#
# Pre-existing failures listed in the press scope (#13 ap path, #21
# settings.local.json, #34/#36 ap_find_profile_dir TMPDIR) are out of
# scope for this file — /age will recommend fixes, /cure will apply.

load test_helper

setup() {
    setup_test_env

    AP="$REAL_DOTFILES_DIR/agent-profile/ap"

    PROFILE_ROOT="$TEST_HOME/profiles"
    TARGET="$TEST_HOME/target"
    mkdir -p "$PROFILE_ROOT" "$TARGET"
    export AP_EXTRA_SEARCH_PATHS="$PROFILE_ROOT"
    export DOTFILES_DIR="$TEST_HOME"
    cd "$TARGET" || exit 1
}

teardown() {
    teardown_test_env
}

# A profile that touches every renderer surface so we exercise the full
# 5-harness dispatch:
#   - 1 agent (writes shared .claude/agents/<n>.md from claude+cursor+
#              opencode; .codex/agents/<n>.toml from codex;
#              .github/agents/<n>.agent.md from copilot)
#   - 1 skill (shared .agents/skills/<n>/ from codex+opencode+cursor;
#              plugin skills/<n>/ from claude;
#              .github/skills/<n>/ from copilot)
#   - 1 command (only claude + opencode + cursor have a surface)
#   - 1 MCP scoped to every harness
make_full_profile() {
    local name="${1:-multi}"
    local dir="$PROFILE_ROOT/$name"
    mkdir -p "$dir/agents" "$dir/skills/widget" "$dir/commands"
    cat > "$dir/profile.yaml" <<EOF
name: $name
description: full-surface integration profile
agents:
  - name: shared-agent
    description: cross-harness agent
    body_path: agents/shared-agent.md
skills:
  - name: widget
    path: skills/widget
commands:
  - name: do-thing
    description: does a thing
    body_path: commands/do-thing.md
mcps:
  - name: omni
    command: /bin/true
    harnesses: [claude, codex, opencode, cursor, copilot]
EOF
    echo "shared agent body" > "$dir/agents/shared-agent.md"
    cat > "$dir/skills/widget/SKILL.md" <<EOF
---
name: widget
description: do widget things
---
widget body
EOF
    echo "do-thing body" > "$dir/commands/do-thing.md"
}

# ─── dispatch table wiring (all 5 harnesses in one install) ─────────

@test "integration: default install dispatches to all 5 renderers" {
    make_full_profile

    run "$AP" install multi
    assert_success

    # Claude — native plugin layout
    [[ -f "$TARGET/.claude/plugins/local/multi/.claude-plugin/plugin.json" ]]
    [[ -f "$TARGET/.claude/plugins/local/multi/agents/shared-agent.md" ]]

    # Codex — TOML subagent + shared skill
    [[ -f "$TARGET/.codex/agents/shared-agent.toml" ]]

    # opencode — slash command at plural path
    [[ -f "$TARGET/.opencode/commands/do-thing.md" ]]

    # Cursor — slash command
    [[ -f "$TARGET/.cursor/commands/do-thing.md" ]]

    # Copilot — .agent.md + .github/skills
    [[ -f "$TARGET/.github/agents/shared-agent.agent.md" ]]
    [[ -d "$TARGET/.github/skills/widget" ]]

    # Cross-harness shared paths — written exactly once each
    [[ -f "$TARGET/.claude/agents/shared-agent.md" ]]
    [[ -d "$TARGET/.agents/skills/widget" ]]
}

@test "integration: every renderer name in dispatch case maps to a defined function" {
    # If a curd added a renderer to the case-statement but forgot to
    # source the file in `ap`, this test would catch it because
    # `declare -F` returns nonzero on missing functions.
    (
        cd "$REAL_DOTFILES_DIR/agent-profile"
        # shellcheck source=../../agent-profile/lib/parse.sh
        source lib/parse.sh
        source lib/discover.sh
        source lib/manifest.sh
        source lib/shared_writer.sh
        source renderers/claude.sh
        source renderers/codex.sh
        source renderers/opencode.sh
        source renderers/cursor.sh
        source renderers/copilot.sh
        declare -F claude_render   >/dev/null || { echo "claude_render not defined"; exit 1; }
        declare -F codex_render    >/dev/null || { echo "codex_render not defined"; exit 1; }
        declare -F opencode_render >/dev/null || { echo "opencode_render not defined"; exit 1; }
        declare -F cursor_render   >/dev/null || { echo "cursor_render not defined"; exit 1; }
        declare -F copilot_render  >/dev/null || { echo "copilot_render not defined"; exit 1; }
        declare -F claude_clean    >/dev/null || { echo "claude_clean not defined"; exit 1; }
        declare -F codex_clean     >/dev/null || { echo "codex_clean not defined"; exit 1; }
        declare -F opencode_clean  >/dev/null || { echo "opencode_clean not defined"; exit 1; }
        declare -F cursor_clean    >/dev/null || { echo "cursor_clean not defined"; exit 1; }
        declare -F copilot_clean   >/dev/null || { echo "copilot_clean not defined"; exit 1; }
    )
}

# ─── _AP_OUT_FILES dedup of cross-harness shared paths ──────────────

@test "integration: shared .claude/agents/<n>.md appears once per profile in manifest" {
    # Three renderers (claude, opencode, cursor) all call
    # ap_write_shared_claude_agent for the same name. The manifest's
    # files list must contain `.claude/agents/shared-agent.md` exactly
    # once for this profile — duplicates would mean uninstall logic
    # walks it multiple times (harmless but a smell) and worse, would
    # bloat the manifest unbounded over repeated installs.
    make_full_profile

    "$AP" install multi >/dev/null
    local mpath="$TARGET/.agent-profile/manifest.json"
    local count
    count=$(jq --arg p "multi" '
        [.[$p].files[] | select(. == ".claude/agents/shared-agent.md")] | length
    ' "$mpath")
    [[ "$count" -eq 1 ]] || {
        echo "expected .claude/agents/shared-agent.md once, got $count" >&2
        jq '.' "$mpath" >&2
        return 1
    }
}

@test "integration: shared .agents/skills/<n>/ appears once per profile in manifest" {
    # codex, opencode, cursor each call ap_copy_shared_skill for the
    # same skill name. Manifest must list `.agents/skills/widget`
    # exactly once.
    make_full_profile

    "$AP" install multi >/dev/null
    local mpath="$TARGET/.agent-profile/manifest.json"
    local count
    count=$(jq --arg p "multi" '
        [.[$p].files[] | select(. == ".agents/skills/widget")] | length
    ' "$mpath")
    [[ "$count" -eq 1 ]] || {
        echo "expected .agents/skills/widget once, got $count" >&2
        jq '.' "$mpath" >&2
        return 1
    }
}

@test "integration: all manifest file entries are unique" {
    # General invariant: regardless of which renderer wrote which path,
    # the per-profile files list must be `unique`. The jq -s unique
    # call in cmd_install enforces this; this test locks it down.
    make_full_profile

    "$AP" install multi >/dev/null
    local mpath="$TARGET/.agent-profile/manifest.json"
    local total uniq
    total=$(jq --arg p "multi" '.[$p].files | length' "$mpath")
    uniq=$(jq --arg p "multi" '.[$p].files | unique | length' "$mpath")
    [[ "$total" -eq "$uniq" ]] || {
        echo "manifest files list has duplicates: $total entries, $uniq unique" >&2
        jq --arg p "multi" '.[$p].files' "$mpath" >&2
        return 1
    }
}

# ─── ap_manifest_diff_and_clean wired into cmd_install ──────────────

@test "integration: re-install after dropping an agent removes the orphaned shared file" {
    # Install a profile that defines two agents, then modify the
    # profile to drop one agent, re-install, and verify the orphaned
    # `.claude/agents/<dropped>.md` is removed from disk and from the
    # manifest. This is the cmd_install → ap_manifest_diff_and_clean
    # integration path (the isolated helper is tested in core.bats).
    local dir="$PROFILE_ROOT/twoagent"
    mkdir -p "$dir/agents"
    cat > "$dir/profile.yaml" <<EOF
name: twoagent
agents:
  - name: keep-me
    body_path: agents/keep-me.md
  - name: drop-me
    body_path: agents/drop-me.md
EOF
    echo "keep body" > "$dir/agents/keep-me.md"
    echo "drop body" > "$dir/agents/drop-me.md"

    "$AP" install twoagent --harness claude >/dev/null

    [[ -f "$TARGET/.claude/agents/keep-me.md" ]]
    [[ -f "$TARGET/.claude/agents/drop-me.md" ]]
    [[ -f "$TARGET/.claude/plugins/local/twoagent/agents/drop-me.md" ]]

    # Drop the second agent.
    cat > "$dir/profile.yaml" <<EOF
name: twoagent
agents:
  - name: keep-me
    body_path: agents/keep-me.md
EOF

    "$AP" install twoagent --harness claude >/dev/null

    [[ -f "$TARGET/.claude/agents/keep-me.md" ]]
    [[ ! -e "$TARGET/.claude/agents/drop-me.md" ]]
    [[ ! -e "$TARGET/.claude/plugins/local/twoagent/agents/drop-me.md" ]]

    # And the manifest no longer references drop-me anywhere.
    local mpath="$TARGET/.agent-profile/manifest.json"
    run jq --arg p "twoagent" '[.[$p].files[] | select(test("drop-me"))] | length' "$mpath"
    assert_success
    [[ "$output" == "0" ]] || {
        echo "manifest still references drop-me: $output" >&2
        jq '.' "$mpath" >&2
        return 1
    }
}

# ─── multi-profile install + uninstall via cmd_install ──────────────

@test "integration: two profiles sharing .agents/skills/widget — uninstall A keeps it (B still claims)" {
    # Two profiles both define a skill called `widget` at the same
    # shared path. After installing both and uninstalling profile A,
    # the shared `.agents/skills/widget/` directory must still exist
    # because profile B's manifest still claims it.
    local dir_a="$PROFILE_ROOT/alpha"
    local dir_b="$PROFILE_ROOT/beta"
    mkdir -p "$dir_a/skills/widget" "$dir_b/skills/widget"
    cat > "$dir_a/profile.yaml" <<EOF
name: alpha
skills:
  - name: widget
    path: skills/widget
EOF
    cat > "$dir_b/profile.yaml" <<EOF
name: beta
skills:
  - name: widget
    path: skills/widget
EOF
    echo "alpha widget" > "$dir_a/skills/widget/SKILL.md"
    echo "beta widget"  > "$dir_b/skills/widget/SKILL.md"

    "$AP" install alpha --harness codex >/dev/null
    "$AP" install beta  --harness codex >/dev/null

    [[ -d "$TARGET/.agents/skills/widget" ]]
    # Beta wrote last, so its content is on disk.
    run cat "$TARGET/.agents/skills/widget/SKILL.md"
    assert_output_contains "beta widget"

    # Uninstall alpha — beta still claims `.agents/skills/widget`.
    "$AP" uninstall alpha --harness codex >/dev/null

    [[ -d "$TARGET/.agents/skills/widget" ]]
    run cat "$TARGET/.agents/skills/widget/SKILL.md"
    assert_output_contains "beta widget"

    # Now uninstall beta — last claimant gone, dir removed.
    "$AP" uninstall beta --harness codex >/dev/null

    [[ ! -e "$TARGET/.agents/skills/widget" ]]
}

@test "integration: two profiles sharing .claude/agents/<n>.md — uninstall A keeps it (B still claims)" {
    # Same shape as the skill test but for the other shared path the
    # reshape introduced. Catches a regression where claude.sh or
    # cursor.sh drops ref-counting on the shared agent file.
    local dir_a="$PROFILE_ROOT/alpha"
    local dir_b="$PROFILE_ROOT/beta"
    mkdir -p "$dir_a/agents" "$dir_b/agents"
    cat > "$dir_a/profile.yaml" <<EOF
name: alpha
agents:
  - name: shared
    body_path: agents/shared.md
EOF
    cat > "$dir_b/profile.yaml" <<EOF
name: beta
agents:
  - name: shared
    body_path: agents/shared.md
EOF
    echo "alpha shared agent" > "$dir_a/agents/shared.md"
    echo "beta shared agent"  > "$dir_b/agents/shared.md"

    "$AP" install alpha --harness cursor >/dev/null
    "$AP" install beta  --harness cursor >/dev/null

    [[ -f "$TARGET/.claude/agents/shared.md" ]]
    run cat "$TARGET/.claude/agents/shared.md"
    assert_output_contains "beta shared agent"

    # Uninstall alpha — beta still claims the shared file.
    "$AP" uninstall alpha --harness cursor >/dev/null
    [[ -f "$TARGET/.claude/agents/shared.md" ]]

    # Uninstall beta — last claimant gone, file removed.
    "$AP" uninstall beta --harness cursor >/dev/null
    [[ ! -e "$TARGET/.claude/agents/shared.md" ]]
}

@test "integration: two profiles writing same .opencode/commands/<n>.md — ref-counted uninstall" {
    # opencode commands are per-profile under .opencode/commands/.
    # If two profiles happen to define a command with the same name
    # (legitimately — e.g. forks of base/), the file is tracked in
    # both manifests. Uninstalling one must not remove it.
    local dir_a="$PROFILE_ROOT/alpha"
    local dir_b="$PROFILE_ROOT/beta"
    mkdir -p "$dir_a/commands" "$dir_b/commands"
    cat > "$dir_a/profile.yaml" <<EOF
name: alpha
commands:
  - name: shared-cmd
    body_path: commands/shared-cmd.md
EOF
    cat > "$dir_b/profile.yaml" <<EOF
name: beta
commands:
  - name: shared-cmd
    body_path: commands/shared-cmd.md
EOF
    echo "alpha cmd body" > "$dir_a/commands/shared-cmd.md"
    echo "beta cmd body"  > "$dir_b/commands/shared-cmd.md"

    "$AP" install alpha --harness opencode >/dev/null
    "$AP" install beta  --harness opencode >/dev/null

    [[ -f "$TARGET/.opencode/commands/shared-cmd.md" ]]

    "$AP" uninstall alpha --harness opencode >/dev/null
    [[ -f "$TARGET/.opencode/commands/shared-cmd.md" ]]

    "$AP" uninstall beta --harness opencode >/dev/null
    [[ ! -e "$TARGET/.opencode/commands/shared-cmd.md" ]]
}

# ─── default-harness install + clean uninstall round-trip ───────────

@test "integration: default install → uninstall leaves no profile-owned artefacts" {
    # The big integration sweep: install with default harness list
    # (all 5), then uninstall, then verify nothing the profile wrote
    # remains. Excludes pre-existing user files in target (none here).
    make_full_profile

    "$AP" install multi >/dev/null

    # Snapshot what got written.
    local installed
    installed=$(find "$TARGET" -mindepth 1 -not -path "$TARGET/.agent-profile*" | sort)
    [[ -n "$installed" ]]

    "$AP" uninstall multi >/dev/null

    # Everything the profile created (outside .agent-profile/) should be gone.
    # We allow empty parent dirs to persist (rm -rf only nukes recorded
    # paths) — the assertion is on tracked files, not on dir cleanup.
    local mpath="$TARGET/.agent-profile/manifest.json"
    [[ -f "$mpath" ]]
    # Manifest entry for `multi` is cleared.
    local has_entry
    has_entry=$(jq --arg p "multi" 'has($p)' "$mpath")
    [[ "$has_entry" == "false" ]] || {
        echo "manifest still has entry for multi after uninstall" >&2
        jq '.' "$mpath" >&2
        return 1
    }

    # Every file the manifest listed at install-time must be gone.
    # We re-extract from the snapshot's grep over the install log isn't
    # easy here — instead, just check the well-known artefact paths.
    [[ ! -e "$TARGET/.claude/agents/shared-agent.md" ]]
    [[ ! -e "$TARGET/.agents/skills/widget" ]]
    [[ ! -e "$TARGET/.codex/agents/shared-agent.toml" ]]
    [[ ! -e "$TARGET/.opencode/commands/do-thing.md" ]]
    [[ ! -e "$TARGET/.cursor/commands/do-thing.md" ]]
    [[ ! -e "$TARGET/.github/agents/shared-agent.agent.md" ]]
    [[ ! -e "$TARGET/.github/skills/widget" ]]
    [[ ! -e "$TARGET/.claude/plugins/local/multi" ]]
}

# ─── selective install preserves other-harness artefacts ────────────

@test "integration: re-install --harness <subset> keeps other-harness files" {
    # Regression for the Copilot finding on cmd_install: a re-install
    # with --harness claude after a full install used to compute
    # new_files_json from just the claude artefacts, then diff against
    # the entire profile manifest. The non-claude files showed up as
    # orphans and got deleted. cmd_install now unions on selective
    # installs and only diff-and-cleans on full-harness installs.
    make_full_profile

    "$AP" install multi >/dev/null
    [[ -f "$TARGET/.codex/agents/shared-agent.toml" ]]
    [[ -d "$TARGET/.agents/skills/widget" ]]

    "$AP" install multi --harness claude >/dev/null

    # Other-harness artefacts still on disk.
    [[ -f "$TARGET/.codex/agents/shared-agent.toml" ]]
    [[ -d "$TARGET/.agents/skills/widget" ]]
    [[ -f "$TARGET/.github/agents/shared-agent.agent.md" ]]
    [[ -f "$TARGET/.cursor/commands/do-thing.md" ]]
    [[ -f "$TARGET/.opencode/commands/do-thing.md" ]]
}

# ─── uninstall --harness honors all cleaners ─────────────────────────

@test "integration: uninstall --harness still cleans shared/merged files" {
    # Regression for the Copilot finding on cmd_uninstall: a partial
    # uninstall used to skip the un-selected cleaners, orphaning entries
    # in merged files like opencode.json. cmd_uninstall now forces every
    # cleaner to run regardless of --harness so shared/merged files stay
    # consistent with the manifest.
    make_full_profile

    "$AP" install multi >/dev/null

    # opencode.json has the profile-authored MCP entry because the MCP
    # is harnessed to opencode.
    [[ -f "$TARGET/opencode.json" ]]
    [[ "$(jq -r '.mcp.omni.command[0]' "$TARGET/opencode.json")" == "/bin/true" ]]

    # Uninstall with only --harness claude. opencode_clean must still
    # run, evicting `omni` from opencode.json. The bootstrap leaves the
    # file with only the `$schema` key, which opencode_clean then
    # removes entirely.
    "$AP" uninstall multi --harness claude >/dev/null

    if [[ -f "$TARGET/opencode.json" ]]; then
        [[ "$(jq -r '.mcp // {} | has("omni")' "$TARGET/opencode.json")" == "false" ]]
    fi
}

# ─── unknown-harness rejection at dispatch ──────────────────────────

@test "integration: unknown harness in --harness rejects before any renderer runs" {
    # Defense in depth: validate_harnesses must fire before we touch
    # disk. If a curd ever bypassed validation, a typo'd harness would
    # silently do nothing — worse, would leave a half-written manifest.
    make_full_profile

    run "$AP" install multi --harness claude,bogus,codex
    assert_failure
    assert_output_contains "unknown harness"
    # No partial install — manifest must not exist (or, if it does
    # because of an earlier successful run, the targets the bogus run
    # would have produced are absent).
    [[ ! -e "$TARGET/.claude/plugins/local/multi" ]]
    [[ ! -e "$TARGET/.codex/agents/shared-agent.toml" ]]
}

# ─── manifest survives the install dispatch loop unmangled ──────────

@test "integration: install records merged_json alongside files" {
    # cmd_install calls ap_manifest_record_merged_json at the end. The
    # merged_json snapshot powers uninstall even after the profile dir
    # is deleted — a key cross-curd interaction (C4 manifest helper +
    # cmd_install wiring).
    make_full_profile

    "$AP" install multi >/dev/null

    local mpath="$TARGET/.agent-profile/manifest.json"
    local has_merged
    has_merged=$(jq --arg p "multi" '.[$p] | has("merged_json")' "$mpath")
    [[ "$has_merged" == "true" ]] || {
        echo "manifest missing merged_json for multi" >&2
        jq '.' "$mpath" >&2
        return 1
    }
    # The merged_json's name field matches the profile.
    local mname
    mname=$(jq -r --arg p "multi" '.[$p].merged_json.name' "$mpath")
    [[ "$mname" == "multi" ]]
}
