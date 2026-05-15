#!/usr/bin/env bats
#
# Tests for chezmoi/lib/install-external.sh and skills/_registry.yaml.
#
# Strategy: copy install-external.sh + the shared sync-common.sh into a fake
# dotfiles tree under $TEST_HOME, write a per-test registry and .env, then
# run the script with a mocked `gh` on $PATH. yq and jq are real.
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
    export GH_LOG="$TEST_HOME/gh.log"

    mkdir -p "$MOCK_SKILLS_DIR" "$MOCK_REGISTRY_DIR" "$MOCK_LIB_DIR" "$MOCK_BIN"

    cp "$REAL_DOTFILES_DIR/chezmoi/lib/install-external.sh" "$MOCK_SKILLS_DIR/install-external.sh"
    cp "$REAL_DOTFILES_DIR/claude/lib/sync-common.sh" "$MOCK_LIB_DIR/sync-common.sh"
    chmod +x "$MOCK_SKILLS_DIR/install-external.sh"

    # Mocked `gh` — every invocation is logged. Default: succeed.
    # Behavior is configured per-test via $GH_BEHAVIOR:
    #   ok        - exit 0 for everything (default)
    #   fail-skill-install - skill install exits 1, api still ok
    #   fail-api  - `gh api ...` exits 1 (auto-discovery fails)
    cat > "$MOCK_BIN/gh" << 'MOCK'
#!/bin/bash
printf 'gh %s\n' "$*" >> "${GH_LOG:-/dev/null}"

case "$1" in
    skill)
        case "$2" in
            --help) exit 0 ;;
            install)
                if [[ "${GH_BEHAVIOR:-ok}" == "fail-skill-install" ]]; then
                    echo "mock gh: install failed for $*" >&2
                    exit 1
                fi
                exit 0
                ;;
        esac
        exit 0
        ;;
    api)
        if [[ "${GH_BEHAVIOR:-ok}" == "fail-api" ]]; then
            exit 1
        fi
        # Reply to `gh api repos/OWNER/REPO/contents/skills` with a fixed
        # set of three skills so auto-discovery has something to chew on.
        if [[ "$2" == repos/*/contents/skills ]]; then
            cat <<'JSON'
[
  {"name": "alpha", "type": "dir"},
  {"name": "bravo", "type": "dir"},
  {"name": "charlie", "type": "dir"},
  {"name": "README.md", "type": "file"}
]
JSON
            exit 0
        fi
        exit 0
        ;;
esac
exit 0
MOCK
    chmod +x "$MOCK_BIN/gh"

    export PATH="$MOCK_BIN:$PATH"
    : > "$GH_LOG"
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

    # Crucially: no gh skill install calls were made.
    run grep -c 'gh skill install' "$GH_LOG"
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

# ─── auto-discovery vs explicit skill list ─────────────────────────────

@test "skill sync: auto-discovers skills via gh api when no explicit list" {
    write_registry "acme/widgets"
    write_env "claude-code"

    run_sync
    assert_success
    assert_output_contains "Skills (3):"
    assert_output_contains "alpha bravo charlie"

    # gh api was called for the contents endpoint
    run grep -F 'gh api repos/acme/widgets/contents/skills' "$GH_LOG"
    assert_success
}

@test "skill sync: explicit skills: list overrides auto-discovery" {
    write_registry "acme/widgets" "    skills:
      - just-this-one
      - and-this"
    write_env "claude-code"

    run_sync
    assert_success
    assert_output_contains "Skills (2):"
    assert_output_contains "just-this-one and-this"

    # gh api should NOT have been called when the list is explicit
    run grep -c 'gh api repos/acme/widgets/contents/skills' "$GH_LOG"
    [[ "$output" == "0" ]]
}

@test "skill sync: auto-discovery failing yields no skills, not a crash" {
    write_registry "missing/repo"
    write_env "claude-code"
    export GH_BEHAVIOR="fail-api"

    run_sync
    assert_success
    assert_output_contains "No skills discovered"
}

# ─── install fan-out ──────────────────────────────────────────────────

@test "skill sync: dry-run prints planned install commands without invoking gh skill install" {
    write_registry "acme/widgets" "    skills:
      - alpha
      - bravo"
    write_env "claude-code cursor"

    run_sync --dry-run
    assert_success
    assert_output_contains "[dry-run]"
    assert_output_contains "gh skill install acme/widgets alpha --agent claude-code --scope user --force"
    assert_output_contains "gh skill install acme/widgets alpha --agent cursor --scope user --force"
    assert_output_contains "gh skill install acme/widgets bravo --agent claude-code --scope user --force"
    assert_output_contains "gh skill install acme/widgets bravo --agent cursor --scope user --force"

    # No real install calls
    run grep -c 'gh skill install' "$GH_LOG"
    [[ "$output" == "0" ]]
}

@test "skill sync: real run invokes gh skill install for every (skill x harness) tuple" {
    write_registry "acme/widgets" "    skills:
      - alpha
      - bravo"
    write_env "claude-code cursor codex"

    run_sync
    assert_success

    # 2 skills * 3 harnesses = 6 installs
    run grep -c 'gh skill install acme/widgets' "$GH_LOG"
    [[ "$output" == "6" ]]

    for harness in claude-code cursor codex; do
        for skill in alpha bravo; do
            run grep -F "gh skill install acme/widgets $skill --agent $harness --scope user --force" "$GH_LOG"
            assert_success
        done
    done
}

@test "skill sync: pin field appends --pin <value> to install command" {
    write_registry "acme/widgets" "    pin: v1.2.3
    skills:
      - alpha"
    write_env "claude-code"

    run_sync --dry-run
    assert_success
    assert_output_contains "gh skill install acme/widgets alpha --agent claude-code --scope user --force --pin v1.2.3"
}

@test "skill sync: failed install is reported but doesn't abort other installs" {
    write_registry "acme/widgets" "    skills:
      - alpha
      - bravo"
    write_env "claude-code"
    export GH_BEHAVIOR="fail-skill-install"

    run_sync
    assert_success  # script itself doesn't bail on per-skill failure
    # Both skills attempted, both shown as failed
    local stripped
    stripped=$(strip_colors "$output")
    [[ "$stripped" == *"✗ alpha → claude-code"* ]]
    [[ "$stripped" == *"✗ bravo → claude-code"* ]]
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

    run grep -F 'gh skill install acme/widgets alpha --agent claude-code' "$GH_LOG"
    assert_success
    run grep -F 'gh skill install beta/gadgets zulu --agent claude-code' "$GH_LOG"
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
    assert_output_contains "gh skill install acme/widgets alpha --agent claude-code --scope user --force"
    assert_output_contains "gh skill install acme/widgets alpha --agent cursor --scope user --force"
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
    assert_output_contains "gh skill install acme/widgets alpha --agent claude-code --scope user --force"
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

# ─── tooling preflight ─────────────────────────────────────────────────

@test "skill sync: missing 'gh skill' subcommand fails fast with upgrade hint" {
    # Override the mock gh so `gh skill --help` fails. The script's preflight
    # must catch this before doing any work.
    cat > "$MOCK_BIN/gh" <<'MOCK'
#!/bin/bash
printf 'gh %s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$1 $2" in
    "skill --help") exit 1 ;;
esac
exit 0
MOCK
    chmod +x "$MOCK_BIN/gh"

    write_registry
    write_env "claude-code"

    run_sync
    assert_failure
    assert_output_contains "'gh skill' subcommand not available"
    assert_output_contains "v2.90"

    # No install attempted.
    run grep -c 'gh skill install' "$GH_LOG"
    [[ "$output" == "0" ]]
}

# ─── registry.yaml shape (live registry) ───────────────────────────────

# ─── cache: skip-if-unchanged ──────────────────────────────────────────
# install-external.sh writes $XDG_STATE_HOME/dotfiles/skill-external-hash
# (or ~/.local/state/...) after a successful run, then early-exits on
# subsequent runs when the (registry content + harness list) digest matches.
# This is the optimization that turns a multi-minute re-sync into a no-op.

@test "skill sync: second run with unchanged registry+harnesses early-exits and runs no installs" {
    write_registry "acme/widgets" "    skills:
      - alpha
      - bravo"
    write_env "claude-code"

    run_sync
    assert_success

    # First run did real installs (2 skills × 1 harness = 2 calls).
    run grep -c 'gh skill install' "$GH_LOG"
    [[ "$output" == "2" ]]

    # Cache file was written
    assert_file_exists "$HOME/.local/state/dotfiles/skill-external-hash"

    # Reset log, then run again with no changes — should skip entirely.
    : > "$GH_LOG"
    run_sync
    assert_success
    assert_output_contains "unchanged since last sync"

    # Zero install calls on the second run.
    run grep -c 'gh skill install' "$GH_LOG"
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
    : > "$GH_LOG"
    run_sync --force
    assert_success
    run grep -c 'gh skill install acme/widgets alpha' "$GH_LOG"
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

    : > "$GH_LOG"
    run_sync
    assert_success
    # Cache invalidated, real installs happen again
    run grep -c 'gh skill install' "$GH_LOG"
    [[ "$output" == "2" ]]
}

@test "skill sync: harness change busts the cache" {
    write_registry "acme/widgets" "    skills:
      - alpha"
    write_env "claude-code"

    run_sync
    assert_success

    # Same registry, different harness set
    write_env "claude-code cursor"

    : > "$GH_LOG"
    run_sync
    assert_success
    run grep -c 'gh skill install' "$GH_LOG"
    [[ "$output" == "2" ]]
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

@test "skill sync: failed installs do not write the cache" {
    write_registry "acme/widgets" "    skills:
      - alpha
      - bravo"
    write_env "claude-code"
    export GH_BEHAVIOR="fail-skill-install"

    run_sync
    assert_success  # script does not abort on per-skill failure

    if [[ -f "$HOME/.local/state/dotfiles/skill-external-hash" ]]; then
        echo "cache written despite failures" >&2
        return 1
    fi
    assert_output_contains "install(s) failed"
    assert_output_contains "cache not updated"
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
