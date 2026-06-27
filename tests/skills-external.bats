#!/usr/bin/env bats
#
# Tests for chezmoi/lib/install-external.sh and skills/_registry.yaml.
#
# Strategy: copy install-external.sh + the shared sync-common.sh into a fake
# dotfiles tree under $TEST_HOME, write a per-test registry and .env, then run
# the script with a mocked `npx` on $PATH. yq and jq are real.
#
# The skills CLI is invoked as `npx --yes skills add <repo>[@pin] --skill ...
# --agent ... -g --copy -y` — one clone per source repo, installed to every
# harness via repeated --agent. The mock logs every invocation.
#
# The helper takes the registry path as its first argument:
#   install-external.sh <registry_path>

load test_helper

setup() {
    setup_test_env

    export MOCK_DOTFILES="$TEST_HOME/mock-dotfiles"
    export MOCK_SKILLS_DIR="$MOCK_DOTFILES/chezmoi/lib"
    export MOCK_REGISTRY_DIR="$MOCK_DOTFILES/skills"
    export MOCK_REGISTRY_FILE="$MOCK_REGISTRY_DIR/_registry.yaml"
    export MOCK_LIB_DIR="$MOCK_DOTFILES/claude/lib"
    export MOCK_BIN="$TEST_HOME/bin"
    export NPX_LOG="$TEST_HOME/npx.log"

    mkdir -p "$MOCK_SKILLS_DIR" "$MOCK_REGISTRY_DIR" "$MOCK_LIB_DIR" "$MOCK_BIN" \
             "$MOCK_DOTFILES/agent-profile/agent_profile"

    cp "$REAL_DOTFILES_DIR/chezmoi/lib/install-external.sh" "$MOCK_SKILLS_DIR/install-external.sh"
    cp "$REAL_DOTFILES_DIR/claude/lib/sync-common.sh" "$MOCK_LIB_DIR/sync-common.sh"
    # Canonical agent-IDs file — shared source of truth between fetch.py and
    # install-external.sh. The shell installer reads $DOTFILES_DIR/agent-profile/
    # agent_profile/skill_agents.txt and aborts loud if it's missing, so the
    # mock tree needs it too.
    cp "$REAL_DOTFILES_DIR/agent-profile/agent_profile/skill_agents.txt" \
       "$MOCK_DOTFILES/agent-profile/agent_profile/skill_agents.txt"
    chmod +x "$MOCK_SKILLS_DIR/install-external.sh"

    # Mocked `npx` — every invocation is logged. Default: succeed.
    # Behavior is configured per-test via $NPX_BEHAVIOR:
    #   ok        - exit 0 for everything (default)
    #   fail-add  - `npx ... skills add ...` exits 1
    cat > "$MOCK_BIN/npx" << 'MOCK'
#!/bin/bash
printf 'npx %s\n' "$*" >> "${NPX_LOG:-/dev/null}"

# Args look like: --yes skills add <spec> --skill ... --agent ... -g --copy -y
for a in "$@"; do
    if [[ "$a" == "add" ]]; then
        if [[ "${NPX_BEHAVIOR:-ok}" == "fail-add" ]]; then
            echo "mock npx skills: add failed for $*" >&2
            exit 1
        fi
        exit 0
    fi
done
exit 0
MOCK
    chmod +x "$MOCK_BIN/npx"

    export PATH="$MOCK_BIN:$PATH"
    : > "$NPX_LOG"
}

teardown() {
    teardown_test_env
}

# Build a minimal registry with a single source.
write_registry() {
    local repo="${1:-acme/widgets}"
    local body="${2:-}"
    cat > "$MOCK_REGISTRY_FILE" <<EOF
sources:
  $repo:
    description: test source
$body
EOF
}

write_env() {
    local harnesses="$1"
    cat > "$MOCK_DOTFILES/.env" <<EOF
SKILL_HARNESSES="$harnesses"
EOF
}

run_sync() {
    run bash "$MOCK_SKILLS_DIR/install-external.sh" "$MOCK_REGISTRY_FILE" "$@"
}

# ─── empty harness behavior ────────────────────────────────────────────

@test "skill sync: empty SKILL_HARNESSES is a no-op with guidance" {
    write_registry
    write_env ""

    run_sync
    assert_success
    assert_output_contains "SKILL_HARNESSES is empty"
    assert_output_contains "SKILL_HARNESSES=\"claude-code cursor codex\""

    # Crucially: no skills add calls were made.
    run grep -c 'skills add' "$NPX_LOG"
    [[ "$output" == "0" ]]
}

@test "skill sync: missing .env still no-ops if SKILL_HARNESSES unset in shell" {
    write_registry
    # No .env file at all.
    unset SKILL_HARNESSES

    run_sync
    assert_success
    assert_output_contains "SKILL_HARNESSES is empty"
}

@test "skill sync: unsupported SKILL_HARNESSES agent is skipped, supported ones still install" {
    # SKILL_HARNESSES is shared with agents the `skills` CLI doesn't support
    # (e.g. crush, antigravity — valid install targets elsewhere). An
    # unsupported entry must be skipped with a loud warning, NOT abort the
    # whole refresh: the supported agents should still get their skills. The
    # silent-no-op masking risk the old hard-fail guarded is covered by the
    # explicit per-skip warning.
    write_registry
    write_env "claude-code bogus-agent"

    run_sync
    assert_success
    assert_output_contains "Skipping SKILL_HARNESSES agents"
    assert_output_contains "bogus-agent"
    # The supported agent still reached npx with its --agent flag.
    run grep -c -- '--agent claude-code' "$NPX_LOG"
    [[ "$output" != "0" ]]
    # The unsupported agent was never passed to npx.
    run grep -c 'bogus-agent' "$NPX_LOG"
    [[ "$output" == "0" ]]
}

@test "skill sync: all-unsupported SKILL_HARNESSES is a no-op (warn, exit 0, no npx)" {
    # When every configured agent is unsupported, there is nothing to install
    # into — warn and exit 0 (matching empty-SKILL_HARNESSES), don't fail the
    # caller (the `dots upgrade` skills-refresh step).
    write_registry
    write_env "bogus-agent another-bogus"

    run_sync
    assert_success
    assert_output_contains "No supported SKILL_HARNESSES agents"
    run grep -c 'skills add' "$NPX_LOG"
    [[ "$output" == "0" ]]
}

# ─── registry parsing ──────────────────────────────────────────────────

@test "skill sync: missing registry.yaml fails fast" {
    write_env "claude-code"
    rm -f "$MOCK_REGISTRY_FILE"

    run_sync
    assert_failure
    assert_output_contains "Registry file not found"
}

@test "skill sync: empty sources map exits with 'No sources defined'" {
    cat > "$MOCK_REGISTRY_FILE" <<'EOF'
sources: {}
EOF
    write_env "claude-code"

    run_sync
    assert_success
    assert_output_contains "No sources defined in registry"
}

# ─── --skill '*' (auto-discovery) vs explicit skill list ───────────────

@test "skill sync: no explicit list installs all skills via --skill '*'" {
    write_registry "acme/widgets"
    write_env "claude-code"

    run_sync --dry-run
    assert_success
    # Repo-level source → one `skills add` with `--skill *`.
    assert_output_contains "npx --yes skills add acme/widgets --skill * --agent claude-code -g --copy -y"
}

@test "skill sync: explicit skills: list becomes repeated --skill flags" {
    write_registry "acme/widgets" "    skills:
      - just-this-one
      - and-this"
    write_env "claude-code"

    run_sync --dry-run
    assert_success
    assert_output_contains "npx --yes skills add acme/widgets --skill just-this-one --skill and-this --agent claude-code -g --copy -y"
    # No `--skill *` when an explicit list is present.
    run grep -F 'skills add acme/widgets --skill *' "$NPX_LOG"
    assert_failure
}

# ─── install fan-out (one call per repo, repeated --agent) ─────────────

@test "skill sync: dry-run prints the planned npx command without invoking npx skills add" {
    write_registry "acme/widgets" "    skills:
      - alpha"
    write_env "claude-code cursor"

    run_sync --dry-run
    assert_success
    assert_output_contains "[dry-run]"
    # One call covers both harnesses via repeated --agent.
    assert_output_contains "npx --yes skills add acme/widgets --skill alpha --agent claude-code --agent cursor -g --copy -y"

    # No real add calls.
    run grep -c 'skills add' "$NPX_LOG"
    [[ "$output" == "0" ]]
}

@test "skill sync: real run invokes one npx skills add per source, all harnesses at once" {
    write_registry "acme/widgets" "    skills:
      - alpha
      - bravo"
    write_env "claude-code cursor codex"

    run_sync
    assert_success

    # Exactly ONE `skills add` for the single source (not per skill, not per harness).
    run grep -c 'skills add acme/widgets' "$NPX_LOG"
    [[ "$output" == "1" ]]

    # That one call carries both explicit skills and all three agents.
    run grep -F 'skills add acme/widgets --skill alpha --skill bravo --agent claude-code --agent cursor --agent codex -g --copy -y' "$NPX_LOG"
    assert_success
}

@test "skill sync: pin field appends @<ref> to the repo spec" {
    write_registry "acme/widgets" "    pin: v1.2.3
    skills:
      - alpha"
    write_env "claude-code"

    run_sync --dry-run
    assert_success
    assert_output_contains "npx --yes skills add acme/widgets@v1.2.3 --skill alpha --agent claude-code -g --copy -y"
}

@test "skill sync: a failed source propagates exit 1 (PR #196 invariant)" {
    # install-external.sh must propagate non-zero on any failure so the chezmoi
    # run_onchange records the apply as failed and reruns next sync. Pre-#196
    # this exited 0, silently marking the apply successful → no retry.
    write_registry "acme/widgets" "    skills:
      - alpha"
    write_env "claude-code"
    export NPX_BEHAVIOR="fail-add"

    run_sync
    assert_failure
    local stripped
    stripped=$(strip_colors "$output")
    [[ "$stripped" == *"✗ acme/widgets → claude-code"* ]]
}

# ─── multi-source registry ─────────────────────────────────────────────

@test "skill sync: handles multiple sources" {
    cat > "$MOCK_REGISTRY_FILE" <<'EOF'
sources:
  acme/widgets:
    description: first
    skills:
      - alpha
  beta/gadgets:
    description: second
    skills:
      - zulu
EOF
    write_env "claude-code"

    run_sync
    assert_success
    assert_output_contains "Source: acme/widgets"
    assert_output_contains "Source: beta/gadgets"

    run grep -F 'skills add acme/widgets --skill alpha --agent claude-code' "$NPX_LOG"
    assert_success
    run grep -F 'skills add beta/gadgets --skill zulu --agent claude-code' "$NPX_LOG"
    assert_success
}

# ─── .env loader edge cases ────────────────────────────────────────────
# The loader is naive by design (spec PR #1 Group A): it strips an optional
# `export ` prefix and strips surrounding double quotes. These tests lock
# that contract so a future "simplification" can't silently break harness
# installs.

@test "skill sync: .env loader honors 'export ' prefix" {
    write_registry "acme/widgets" "    skills:
      - alpha"
    cat > "$MOCK_DOTFILES/.env" <<'EOF'
export SKILL_HARNESSES="claude-code cursor"
EOF
    unset SKILL_HARNESSES

    run_sync --dry-run
    assert_success
    assert_output_contains "Harnesses: claude-code cursor"
    assert_output_contains "skills add acme/widgets --skill alpha --agent claude-code --agent cursor"
}

@test "skill sync: .env loader accepts unquoted value" {
    write_registry "acme/widgets" "    skills:
      - alpha"
    cat > "$MOCK_DOTFILES/.env" <<'EOF'
SKILL_HARNESSES=claude-code
EOF
    unset SKILL_HARNESSES

    run_sync --dry-run
    assert_success
    assert_output_contains "Harnesses: claude-code"
    assert_output_contains "skills add acme/widgets --skill alpha --agent claude-code"
}

@test "skill sync: .env loader skips comment lines and blank lines" {
    write_registry "acme/widgets" "    skills:
      - alpha"
    cat > "$MOCK_DOTFILES/.env" <<'EOF'
# This is a comment

SKILL_HARNESSES="claude-code"
# Trailing comment
EOF
    unset SKILL_HARNESSES

    run_sync --dry-run
    assert_success
    assert_output_contains "Harnesses: claude-code"
}

# ─── cache: skip-if-unchanged ──────────────────────────────────────────
# install-external.sh writes $XDG_STATE_HOME/dotfiles/skill-external-hash
# (or ~/.local/state/...) after a successful run, then early-exits on
# subsequent runs when the (registry content + harness list) digest matches.
# This is the optimization that turns a multi-source re-sync into a no-op.

@test "skill sync: second run with unchanged registry+harnesses early-exits and runs no installs" {
    write_registry "acme/widgets" "    skills:
      - alpha
      - bravo"
    write_env "claude-code"

    run_sync
    assert_success

    # First run did a real install (one source).
    run grep -c 'skills add' "$NPX_LOG"
    [[ "$output" == "1" ]]

    # Cache file was written
    assert_file_exists "$HOME/.local/state/dotfiles/skill-external-hash"

    # Reset log, then run again with no changes — should skip entirely.
    : > "$NPX_LOG"
    run_sync
    assert_success
    assert_output_contains "unchanged since last sync"

    # Zero install calls on the second run.
    run grep -c 'skills add' "$NPX_LOG"
    [[ "$output" == "0" ]]
}

@test "skill sync: --force bypasses the cache even when registry is unchanged" {
    write_registry "acme/widgets" "    skills:
      - alpha"
    write_env "claude-code"

    # Prime the cache via a first successful run.
    run_sync
    assert_success

    # Second run with --force should re-install despite matching cache.
    : > "$NPX_LOG"
    run_sync --force
    assert_success
    run grep -c 'skills add acme/widgets' "$NPX_LOG"
    [[ "$output" == "1" ]]
}

@test "skill sync: registry change busts the cache (re-installs)" {
    write_registry "acme/widgets" "    skills:
      - alpha"
    write_env "claude-code"

    run_sync
    assert_success

    # Change the registry — add a second skill.
    write_registry "acme/widgets" "    skills:
      - alpha
      - bravo"

    : > "$NPX_LOG"
    run_sync
    assert_success
    # Cache invalidated, real install happens again.
    run grep -c 'skills add' "$NPX_LOG"
    [[ "$output" == "1" ]]
}

@test "skill sync: harness change busts the cache" {
    write_registry "acme/widgets" "    skills:
      - alpha"
    write_env "claude-code"

    run_sync
    assert_success

    # Same registry, different harness set
    write_env "claude-code cursor"

    : > "$NPX_LOG"
    run_sync
    assert_success
    run grep -c 'skills add' "$NPX_LOG"
    [[ "$output" == "1" ]]
}

@test "skill sync: --dry-run does not write the cache file" {
    write_registry "acme/widgets" "    skills:
      - alpha"
    write_env "claude-code"

    run_sync --dry-run
    assert_success

    if [[ -f "$HOME/.local/state/dotfiles/skill-external-hash" ]]; then
        echo "dry-run wrote the cache file" >&2
        return 1
    fi
}

@test "skill sync: failed installs do not write the cache (and propagate exit 1)" {
    # PR #196 finding 3: cache must stay un-written on any failure, AND
    # the script must exit non-zero so the run_onchange retries.
    write_registry "acme/widgets" "    skills:
      - alpha"
    write_env "claude-code"
    export NPX_BEHAVIOR="fail-add"

    run_sync
    assert_failure  # PR #196: failure propagates exit 1

    if [[ -f "$HOME/.local/state/dotfiles/skill-external-hash" ]]; then
        echo "cache written despite failures" >&2
        return 1
    fi
    assert_output_contains "source(s) failed"
    assert_output_contains "cache not updated"
}

@test "skill sync: cache digest is sha256(sha256(registry) + LF + harnesses + LF)" {
    # Locks down the exact digest formula. If a refactor changes the
    # algorithm, this test fails and forces a conscious decision about
    # cache invalidation across machines.
    write_registry "acme/widgets" "    skills:
      - alpha"
    write_env "claude-code cursor"

    run_sync
    assert_success

    local cache_file="$HOME/.local/state/dotfiles/skill-external-hash"
    assert_file_exists "$cache_file"

    local registry_digest combined_digest actual
    registry_digest=$(shasum -a 256 "$MOCK_REGISTRY_FILE" | awk '{print $1}')
    combined_digest=$(printf '%s\n%s\n' "$registry_digest" "claude-code cursor" \
        | shasum -a 256 | awk '{print $1}')
    actual=$(cat "$cache_file")

    [[ "$actual" == "$combined_digest" ]] || {
        echo "Cache digest mismatch" >&2
        echo "  expected: $combined_digest" >&2
        echo "  actual:   $actual" >&2
        return 1
    }
}

@test "skill sync: --force re-runs the add (the documented upstream-refresh workaround)" {
    # The cache is keyed on registry+harnesses, so it is blind to upstream
    # skill-set changes (a new skill added to a source repo). The documented
    # escape hatch is --force, which re-runs `skills add --skill '*'` and lets
    # the CLI pull whatever is now in the repo.
    write_registry "acme/widgets"  # --skill '*'
    write_env "claude-code"

    run_sync
    assert_success

    : > "$NPX_LOG"
    run_sync --force
    assert_success
    run grep -F 'skills add acme/widgets --skill * --agent claude-code' "$NPX_LOG"
    assert_success
}

# ─── per-repo harnesses: filtering ────────────────────────────────────

@test "skill sync: per-repo harnesses: restricts install to that subset" {
    # Source declares harnesses: [claude] (ap name) → only claude-code gets
    # the --agent flag, even though SKILL_HARNESSES includes cursor too.
    write_registry "acme/widgets" "    harnesses:
      - claude"
    write_env "claude-code cursor"

    run_sync --dry-run
    assert_success
    assert_output_contains "--agent claude-code"
    run grep -F 'agent cursor' <<< "$output"
    assert_failure
}

@test "skill sync: source without harnesses: still installs into all SKILL_HARNESSES" {
    write_registry "acme/widgets"
    write_env "claude-code cursor"

    run_sync --dry-run
    assert_success
    assert_output_contains "--agent claude-code"
    assert_output_contains "--agent cursor"
}

@test "skill sync: unknown ap harness name in harnesses: warns and skips that harness" {
    write_registry "acme/widgets" "    harnesses:
      - claude
      - bogus-ap-name"
    write_env "claude-code"

    run_sync --dry-run
    assert_success
    assert_output_contains "Skipping unknown harness 'bogus-ap-name'"
    assert_output_contains "--agent claude-code"
}

@test "skill sync: all-invalid harnesses: entries skips that source entirely (exit 0)" {
    write_registry "acme/widgets" "    harnesses:
      - not-a-real-harness"
    write_env "claude-code"

    run_sync
    assert_success
    assert_output_contains "No valid harnesses for acme/widgets"
    # Source was skipped — no skills add call for it.
    run grep -c 'skills add acme/widgets' "$NPX_LOG"
    [[ "$output" == "0" ]]
}

@test "skill sync: harnesses: uses ap name → cli-id mapping (claude → claude-code)" {
    write_registry "acme/widgets" "    harnesses:
      - claude"
    write_env "claude-code codex cursor"

    run_sync
    assert_success
    # npx was called with claude-code, not the raw ap name 'claude'.
    run grep -F -- '--agent claude-code' "$NPX_LOG"
    assert_success
    # The other harnesses were not passed.
    run grep -F -- '--agent codex' "$NPX_LOG"
    assert_failure
    run grep -F -- '--agent cursor' "$NPX_LOG"
    assert_failure
}

@test "registry.yaml: real registry parses cleanly with yq" {
    run yq '.sources | keys' "$REAL_DOTFILES_DIR/skills/_registry.yaml"
    assert_success
    [[ -n "$output" ]]
}

@test "registry.yaml: every source key matches OWNER/REPO format" {
    run yq -r '.sources | keys | .[]' "$REAL_DOTFILES_DIR/skills/_registry.yaml"
    assert_success
    [[ -n "$output" ]]

    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            echo "Source '$repo' is not OWNER/REPO format" >&2
            return 1
        fi
    done <<< "$output"
}

@test "registry.yaml: top-level shape is exactly { sources: ... }" {
    run yq -r 'keys | .[]' "$REAL_DOTFILES_DIR/skills/_registry.yaml"
    assert_success
    [[ "$output" == "sources" ]]
}

@test "registry.yaml: optional fields (skills, pin, description) parse to expected types" {
    # If a source declares 'skills', it must be a sequence of scalars.
    # If it declares 'pin', it must be a scalar.
    # If it declares 'description', it must be a scalar.
    run yq -r '
      .sources
      | to_entries
      | map(
          .value
          | (
              ((.skills // []) | type) + " " +
              ((.pin // "") | type) + " " +
              ((.description // "") | type)
            )
        )
      | .[]
    ' "$REAL_DOTFILES_DIR/skills/_registry.yaml"
    assert_success
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Expected: "!!seq !!str !!str"
        local skills_t pin_t desc_t
        read -r skills_t pin_t desc_t <<< "$line"
        [[ "$skills_t" == "!!seq" ]] || { echo "skills not seq: $line" >&2; return 1; }
        [[ "$pin_t" == "!!str" ]] || { echo "pin not str: $line" >&2; return 1; }
        [[ "$desc_t" == "!!str" ]] || { echo "description not str: $line" >&2; return 1; }
    done <<< "$output"
}
