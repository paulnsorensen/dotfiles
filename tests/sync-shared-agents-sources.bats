#!/usr/bin/env bats
# Behavioural tests for sync_shared_agents_chezmoi_sources (.sync-lib.sh) —
# the assembly step that writes chezmoi/private_dot_agents/exact_skills/ from
# .claude.skills plus every skills/_registry.yaml source whose harnesses:
# is absent or intersects "codex copilot zed omp"
# (spec: shared-agents-skills-exact, f1-selection/f2-target).
#
# Runs against a synthetic fixture repo so assertions are exact and the repo
# checkout is never mutated. External vendoring is fed from a seeded cache +
# a git shim (no network).

load test_helper

setup() {
    setup_test_env
    command -v yq >/dev/null 2>&1 || skip "yq not installed"

    ROOT="$TEST_HOME/repo"
    SRC="$ROOT/chezmoi"
    export ROOT SRC

    mkdir -p "$ROOT/skills/alpha-skill"
    echo "# alpha" > "$ROOT/skills/alpha-skill/SKILL.md"

    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources: {}
YAML

    mkdir -p "$SRC/.chezmoidata"
    cat > "$SRC/.chezmoidata/claude.yaml" <<'YAML'
claude:
  skills:
    - alpha-skill
YAML

    # ── offline external cache + git shim (records calls, then fails) ──
    export GIT_CALLS="$TEST_HOME/git-calls.log"
    local fake_bin="$TEST_HOME/fake-git"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_CALLS"
exit 1
SH
    chmod +x "$fake_bin/git"
    export PATH="$fake_bin:$PATH"
}

teardown() { teardown_test_env; }

seed_cache_source() {
    local source="$1" skill="$2"
    local cache="$TEST_HOME/.cache/dotfiles/claude-skill-sources/${source//\//__}"
    mkdir -p "$cache/.git" "$cache/skills/$skill"
    echo "# $skill" > "$cache/skills/$skill/SKILL.md"
}

run_assembly() {
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && sync_shared_agents_chezmoi_sources '$ROOT' '$SRC'"
}

@test "AC-1 shared-agents: builds private_dot_agents/exact_skills from .claude.skills" {
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/private_dot_agents/exact_skills/exact_alpha-skill/SKILL.md" ]
}

@test "AC-1 shared-agents: unknown skill name aborts loud" {
    cat > "$SRC/.chezmoidata/claude.yaml" <<'YAML'
claude:
  skills:
    - alpha-skill
    - ghost-skill
YAML
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"ghost-skill"* ]]
}

@test "AC-2 shared-agents: vendors codex, zed and unfiltered sources and skips claude-only" {
    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/codex-src:
    harnesses: [codex]
  owner/zed-src:
    harnesses: [zed]
  owner/any-src: {}
  owner/claude-src:
    harnesses: [claude]
  owner/omp-src:
    harnesses: [omp]
  owner/copilot-src:
    harnesses: [copilot]
YAML
    seed_cache_source owner/codex-src codex-skill
    seed_cache_source owner/zed-src zed-skill
    seed_cache_source owner/any-src any-skill
    seed_cache_source owner/claude-src claude-skill
    seed_cache_source owner/omp-src omp-skill
    seed_cache_source owner/copilot-src copilot-skill

    run_assembly
    [ "$status" -eq 0 ]
    local base="$SRC/private_dot_agents/exact_skills"
    [ -f "$base/exact_codex-skill/SKILL.md" ]
    [ -f "$base/exact_zed-skill/SKILL.md" ]
    [ -f "$base/exact_any-skill/SKILL.md" ]
    [ -f "$base/exact_omp-skill/SKILL.md" ]
    [ -f "$base/exact_copilot-skill/SKILL.md" ]
    [ ! -e "$base/exact_claude-skill" ]
}

@test "AC-3 shared-agents: repeat run is byte-identical" {
    mkdir -p "$ROOT/skills/beta-skill"
    echo "# beta" > "$ROOT/skills/beta-skill/SKILL.md"
    cat > "$SRC/.chezmoidata/claude.yaml" <<'YAML'
claude:
  skills:
    - alpha-skill
    - beta-skill
YAML

    run_assembly
    [ "$status" -eq 0 ]
    local first
    first="$TEST_HOME/first-run"
    cp -R "$SRC/private_dot_agents/exact_skills" "$first"

    run_assembly
    [ "$status" -eq 0 ]
    diff -r "$first" "$SRC/private_dot_agents/exact_skills"
}

@test "AC-3 shared-agents: deselecting a skill drops it from the tree" {
    mkdir -p "$ROOT/skills/beta-skill"
    echo "# beta" > "$ROOT/skills/beta-skill/SKILL.md"
    cat > "$SRC/.chezmoidata/claude.yaml" <<'YAML'
claude:
  skills:
    - alpha-skill
    - beta-skill
YAML

    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/private_dot_agents/exact_skills/exact_beta-skill/SKILL.md" ]

    cat > "$SRC/.chezmoidata/claude.yaml" <<'YAML'
claude:
  skills:
    - alpha-skill
YAML
    run_assembly
    [ "$status" -eq 0 ]
    [ ! -e "$SRC/private_dot_agents/exact_skills/exact_beta-skill" ]
}
