#!/usr/bin/env bats
# Behavioural tests for sync_claude_chezmoi_sources (.sync-lib.sh) — the
# assembly step that copies registry-selected skills / rendered agents /
# claude asset dirs into chezmoi source state as exact_ trees
# (spec: chezmoi-authoritative-claude, decisions D1/G1).
#
# Runs against a synthetic fixture repo so assertions are exact and the repo
# checkout is never mutated. External vendoring is fed from a seeded cache +
# a git shim (no network).

load test_helper

setup() {
    setup_test_env
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"

    ROOT="$TEST_HOME/repo"
    SRC="$ROOT/chezmoi"
    export ROOT SRC

    # ── fixture repo ──
    mkdir -p "$ROOT/skills/alpha-skill/scripts" "$ROOT/skills/beta-skill"
    echo "# alpha" > "$ROOT/skills/alpha-skill/SKILL.md"
    printf '#!/bin/bash\necho hi\n' > "$ROOT/skills/alpha-skill/scripts/tool.sh"
    chmod +x "$ROOT/skills/alpha-skill/scripts/tool.sh"
    echo "# beta" > "$ROOT/skills/beta-skill/SKILL.md"

    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/ext-repo:
    description: external skills
YAML

    mkdir -p "$ROOT/agents/agent_definitions" "$ROOT/agents/hooks" "$ROOT/agents/lib" "$ROOT/agents/reference"
    cat > "$ROOT/agents/registry.yaml" <<'YAML'
agents:
  tester:
    description: A test agent.
    models:
      claude: haiku
    tools:
    - Bash
    - Read
    disallowedTools:
    - Edit
    color: cyan
    autoCompactWindow: 120000
    skills:
    - alpha-skill
    body_path: agents/agent_definitions/tester.md
YAML
    echo "Agent body." > "$ROOT/agents/agent_definitions/tester.md"

    cat > "$ROOT/agents/hooks/registry.yaml" <<'YAML'
hooks:
  claude-hook:
    event: Stop
    script: agents/hooks/claude-hook.sh
    harnesses: [claude, codex]
  codex-only:
    event: Stop
    script: agents/hooks/codex-only.sh
    harnesses: [codex]
  command-only:
    event: Stop
    command: "some-binary"
    harnesses: [claude]
YAML
    printf '#!/bin/bash\nexit 0\n' > "$ROOT/agents/hooks/claude-hook.sh"
    printf '#!/bin/bash\nexit 0\n' > "$ROOT/agents/hooks/codex-only.sh"
    chmod +x "$ROOT/agents/hooks/claude-hook.sh" "$ROOT/agents/hooks/codex-only.sh"
    echo "lib" > "$ROOT/agents/lib/helper.js"
    echo "bank" > "$ROOT/agents/reference/bank.md"

    mkdir -p "$ROOT/claude/commands" "$ROOT/claude/hooks" "$ROOT/claude/reference" "$ROOT/claude/workflows"
    echo "cmd" > "$ROOT/claude/commands/thing.md"
    echo "hook" > "$ROOT/claude/hooks/runner.js"
    echo "ref" > "$ROOT/claude/reference/doc.md"
    echo "wf" > "$ROOT/claude/workflows/flow.js"

    mkdir -p "$SRC/.chezmoidata"
    cat > "$SRC/.chezmoidata/claude.yaml" <<'YAML'
claude:
  skills:
    - alpha-skill
    - beta-skill
  agents:
    - tester
YAML

    # ── offline external cache + git shim (records calls, then fails) ──
    CACHE="$TEST_HOME/.cache/dotfiles/claude-skill-sources/owner__ext-repo"
    mkdir -p "$CACHE/.git" "$CACHE/skills/ext-skill"
    echo "# ext" > "$CACHE/skills/ext-skill/SKILL.md"
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

run_assembly() {
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && sync_claude_chezmoi_sources '$ROOT' '$SRC'"
}

@test "assembly: builds all seven exact_ trees with encoded names" {
    run_assembly
    [ "$status" -eq 0 ]
    local tree
    for tree in exact_skills exact_agents exact_commands exact_hooks exact_lib exact_reference exact_workflows; do
        [ -d "$SRC/dot_claude/$tree" ]
    done
    [ -f "$SRC/dot_claude/exact_skills/exact_alpha-skill/SKILL.md" ]
    # Nested dirs get exact_, executable files get executable_.
    [ -f "$SRC/dot_claude/exact_skills/exact_alpha-skill/exact_scripts/executable_tool.sh" ]
    [ -f "$SRC/dot_claude/exact_commands/thing.md" ]
    [ -f "$SRC/dot_claude/exact_workflows/flow.js" ]
    [ -f "$SRC/dot_claude/exact_lib/helper.js" ]
}

@test "assembly: renders agent frontmatter from registry metadata" {
    run_assembly
    [ "$status" -eq 0 ]
    local agent="$SRC/dot_claude/exact_agents/tester.md"
    [ -f "$agent" ]
    diff "$agent" - <<'EXPECTED'
---
name: tester
description: A test agent.
tools: Bash, Read
disallowedTools: [Edit]
model: haiku
color: cyan
autoCompactWindow: 120000
skills: [alpha-skill]
---
Agent body.
EXPECTED
}

@test "assembly: built-in shadows in claude/agents land next to rendered agents" {
    mkdir -p "$ROOT/claude/agents"
    printf -- '---\nname: Explore\nautoCompactWindow: 120000\n---\nShadow body.\n' > "$ROOT/claude/agents/Explore.md"
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_claude/exact_agents/tester.md" ]
    diff "$SRC/dot_claude/exact_agents/Explore.md" "$ROOT/claude/agents/Explore.md"
}

@test "assembly: a shadow that reuses a registry agent name aborts loud" {
    mkdir -p "$ROOT/claude/agents"
    printf -- '---\nname: tester\n---\nImpostor.\n' > "$ROOT/claude/agents/tester.md"
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"claude agent shadow 'tester.md' collides with a rendered registry agent"* ]]
}

@test "shadow copy: missing source dir is a no-op success and creates nothing" {
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && _cz_copy_claude_agent_shadows '$TEST_HOME/no-such-src' '$TEST_HOME/dst'"
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_HOME/dst" ]
}

@test "shadow copy: non-md files and nested subdirs are ignored" {
    mkdir -p "$TEST_HOME/s/nested" "$TEST_HOME/d"
    echo a > "$TEST_HOME/s/Explore.md"
    echo b > "$TEST_HOME/s/notes.txt"
    echo c > "$TEST_HOME/s/README"
    echo d > "$TEST_HOME/s/nested/Deep.md"
    echo e > "$TEST_HOME/s/Plan.md.bak"
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && _cz_copy_claude_agent_shadows '$TEST_HOME/s' '$TEST_HOME/d'"
    [ "$status" -eq 0 ]
    [ -f "$TEST_HOME/d/Explore.md" ]
    [ "$(find "$TEST_HOME/d" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "1" ]
}

@test "shadow copy: filename with spaces is copied intact" {
    mkdir -p "$TEST_HOME/s" "$TEST_HOME/d"
    echo a > "$TEST_HOME/s/my agent.md"
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && _cz_copy_claude_agent_shadows '$TEST_HOME/s' '$TEST_HOME/d'"
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_HOME/d/my agent.md")" = "a" ]
}

@test "shadow copy: empty source dir succeeds and leaves dst empty" {
    mkdir -p "$TEST_HOME/s"
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && _cz_copy_claude_agent_shadows '$TEST_HOME/s' '$TEST_HOME/d'"
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$TEST_HOME/d")" ]
}

@test "shadow copy: collision names the file, returns non-zero, keeps the rendered file" {
    mkdir -p "$TEST_HOME/s" "$TEST_HOME/d"
    echo shadow > "$TEST_HOME/s/tester.md"
    echo rendered > "$TEST_HOME/d/tester.md"
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && _cz_copy_claude_agent_shadows '$TEST_HOME/s' '$TEST_HOME/d'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"collides with a rendered registry agent"* ]]
    [ "$(cat "$TEST_HOME/d/tester.md")" = "rendered" ]
}

@test "shadow copy: a symlinked shadow is dereferenced into a regular file" {
    mkdir -p "$TEST_HOME/s" "$TEST_HOME/d" "$TEST_HOME/real"
    echo body > "$TEST_HOME/real/x.md"
    ln -s "$TEST_HOME/real/x.md" "$TEST_HOME/s/Linked.md"
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && _cz_copy_claude_agent_shadows '$TEST_HOME/s' '$TEST_HOME/d'"
    [ "$status" -eq 0 ]
    [ -f "$TEST_HOME/d/Linked.md" ] && [ ! -L "$TEST_HOME/d/Linked.md" ]
}

@test "shadow copy: a dangling symlinked shadow is skipped without failing" {
    mkdir -p "$TEST_HOME/s" "$TEST_HOME/d"
    ln -s "$TEST_HOME/nope.md" "$TEST_HOME/s/Dead.md"
    echo ok > "$TEST_HOME/s/Good.md"
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && _cz_copy_claude_agent_shadows '$TEST_HOME/s' '$TEST_HOME/d'"
    [ "$status" -eq 0 ]
    [ -f "$TEST_HOME/d/Good.md" ]
    [ ! -e "$TEST_HOME/d/Dead.md" ]
}

@test "repo: every built-in shadow compacts at the registry's window" {
    local shadow window
    window=$(yq -r '[.agents[].autoCompactWindow] | unique | .[]' "$REAL_DOTFILES_DIR/agents/registry.yaml")
    [ "$window" = "120000" ]
    for shadow in Explore Plan general-purpose; do
        [ -f "$REAL_DOTFILES_DIR/claude/agents/$shadow.md" ]
        [ "$(yq --front-matter=extract -r '.name' "$REAL_DOTFILES_DIR/claude/agents/$shadow.md")" = "$shadow" ]
        [ "$(yq --front-matter=extract -r '.autoCompactWindow' "$REAL_DOTFILES_DIR/claude/agents/$shadow.md")" = "$window" ]
    done
}

@test "assembly: claude-harness hook scripts land executable; codex-only and command-only do not" {
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_claude/exact_hooks/executable_claude-hook.sh" ]
    [ ! -e "$SRC/dot_claude/exact_hooks/executable_codex-only.sh" ]
    # claude/hooks assets copied alongside.
    [ -f "$SRC/dot_claude/exact_hooks/runner.js" ]
}

@test "assembly: a yq failure on the hooks registry aborts loud (no silent zero-copy)" {
    # Malformed YAML in the hooks registry makes the hooks-registry yq query
    # exit nonzero. Assembly must abort and name the hook registry, not copy
    # zero hooks and return success (the silent-swallow regression).
    printf 'hooks:\n  broken: [unterminated\n' > "$ROOT/agents/hooks/registry.yaml"
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"hook registry"* ]]
    [[ "$output" == *"agents/hooks/registry.yaml"* ]]
}
@test "assembly: reference merges claude/reference and agents/reference" {
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_claude/exact_reference/doc.md" ]
    [ -f "$SRC/dot_claude/exact_reference/bank.md" ]
}

@test "assembly: plain sync floats an unpinned source to latest (git pull --ff-only)" {
    # Every sync pulls the default branch; the failing git shim simulates
    # offline, so the pull falls back to the cached checkout with a warning.
    run_assembly
    [ "$status" -eq 0 ]
    grep -q "pull --ff-only" "$GIT_CALLS"
    [[ "$output" == *"using cached checkout"* ]]
    [ -f "$SRC/dot_claude/exact_skills/exact_ext-skill/SKILL.md" ]
}

@test "assembly: a changed pin on a cached source is fetched, checked out, and recorded" {
    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/ext-repo:
    pin: v2.0.0
YAML
    # git shim that succeeds; FETCH_HEAD resolves to a new sha, so the
    # remote moved relative to the cached checkout.
    cat > "$TEST_HOME/fake-git/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_CALLS"
case "$*" in
    *"rev-parse FETCH_HEAD"*) echo bbbbbbbb ;;
    *"rev-parse HEAD"*) echo aaaaaaaa ;;
esac
exit 0
SH
    run_assembly
    [ "$status" -eq 0 ]
    grep -q "fetch --depth 1 origin v2.0.0" "$GIT_CALLS"
    grep -q "checkout --detach FETCH_HEAD" "$GIT_CALLS"
    [ "$(cat "$CACHE/.dotfiles-pin")" = "v2.0.0" ]
    # Same pin again: branch pins move, so every sync re-fetches — but when
    # the remote sha matches the cached checkout there is no re-checkout churn.
    cat > "$TEST_HOME/fake-git/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_CALLS"
case "$*" in
    *"rev-parse"*) echo bbbbbbbb ;;
esac
exit 0
SH
    : > "$GIT_CALLS"
    run_assembly
    [ "$status" -eq 0 ]
    grep -q "fetch --depth 1 origin v2.0.0" "$GIT_CALLS"
    ! grep -q "checkout --detach" "$GIT_CALLS"
}

@test "assembly: a changed pin that cannot be fetched fails loud" {
    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/ext-repo:
    pin: v9.9.9
YAML
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot fetch changed pin"* ]]
}

@test "assembly: an unchanged pin that cannot be fetched falls back to cache" {
    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/ext-repo:
    pin: v9.9.9
YAML
    echo "v9.9.9" > "$CACHE/.dotfiles-pin"
    run_assembly
    [ "$status" -eq 0 ]
    [[ "$output" == *"using cached checkout"* ]]
    [ -f "$SRC/dot_claude/exact_skills/exact_ext-skill/SKILL.md" ]
}

@test "assembly: deselecting a skill removes it from source state (deletion propagates)" {
    run_assembly
    [ "$status" -eq 0 ]
    [ -d "$SRC/dot_claude/exact_skills/exact_beta-skill" ]
    # Drop beta-skill from the registry, re-run.
    cat > "$SRC/.chezmoidata/claude.yaml" <<'YAML'
claude:
  skills:
    - alpha-skill
  agents:
    - tester
YAML
    run_assembly
    [ "$status" -eq 0 ]
    [ ! -e "$SRC/dot_claude/exact_skills/exact_beta-skill" ]
    [ -d "$SRC/dot_claude/exact_skills/exact_alpha-skill" ]
}

@test "assembly: unknown skill in the registry fails loud and leaves prior state intact" {
    run_assembly
    [ "$status" -eq 0 ]
    cat > "$SRC/.chezmoidata/claude.yaml" <<'YAML'
claude:
  skills:
    - no-such-skill
  agents: []
YAML
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown skill"* ]]
    # Previous assembled tree untouched (staging swap never happened).
    [ -d "$SRC/dot_claude/exact_skills/exact_alpha-skill" ]
}

@test "assembly: external source with no cache and failing clone aborts" {
    rm -rf "$TEST_HOME/.cache/dotfiles/claude-skill-sources"
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"clone failed"* ]]
}

@test "assembly: dotfile-named entries are encoded (dot_ prefix), not deployed verbatim" {
    mkdir -p "$ROOT/skills/alpha-skill/.claude-plugin"
    echo '{}' > "$ROOT/skills/alpha-skill/.claude-plugin/plugin.json"
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_claude/exact_skills/exact_alpha-skill/exact_dot_claude-plugin/plugin.json" ]
}

@test "assembly: filenames colliding with chezmoi attribute prefixes get literal_ escaped" {
    # chezmoi treats any source file named run_* as a SCRIPT TO EXECUTE and
    # strips attribute prefixes like exact_/private_ from target names. A
    # skill shipping a file literally named run_tests.sh or exact_notes.md
    # must be literal_-escaped in source state or apply executes/renames it.
    printf '#!/bin/bash\nexit 0\n' > "$ROOT/skills/alpha-skill/run_tests.sh"
    echo "notes" > "$ROOT/skills/alpha-skill/exact_notes.md"
    run_assembly
    [ "$status" -eq 0 ]
    local base="$SRC/dot_claude/exact_skills/exact_alpha-skill"
    [ -f "$base/literal_run_tests.sh" ]
    [ -f "$base/literal_exact_notes.md" ]
    # No unescaped copies that chezmoi would misinterpret.
    [ ! -e "$base/run_tests.sh" ]
    [ ! -e "$base/exact_notes.md" ]
}

@test "assembly: second run with an unchanged registry is byte-identical (idempotent)" {
    # dots sync runs the assembly on every invocation; acceptance requires the
    # second sync to be a no-op, so the assembled source state must be stable.
    run_assembly
    [ "$status" -eq 0 ]
    cp -R "$SRC/dot_claude" "$TEST_HOME/first-pass"
    run_assembly
    [ "$status" -eq 0 ]
    diff -r "$TEST_HOME/first-pass" "$SRC/dot_claude"
}

@test "assembly: agent with a missing body_path fails loud and leaves prior state intact" {
    run_assembly
    [ "$status" -eq 0 ]
    cat > "$ROOT/agents/registry.yaml" <<'YAML'
agents:
  tester:
    description: A test agent.
    body_path: agents/agent_definitions/no-such-body.md
YAML
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"body_path missing"* ]]
    # Staging swap never happened — the previously assembled agent survives.
    [ -f "$SRC/dot_claude/exact_agents/tester.md" ]
}

@test "assembly: a failed file copy fails loud and leaves prior state intact" {
    run_assembly
    [ "$status" -eq 0 ]
    # cp shim that always fails — simulates disk-full / permission errors. An
    # unchecked copy would swap a PARTIAL exact_ tree in and apply would
    # DELETE the missing live entries.
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_HOME/fake-git/cp"
    chmod +x "$TEST_HOME/fake-git/cp"
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"copy failed"* ]]
    # Staging swap never happened — the previously assembled tree survives.
    [ -f "$SRC/dot_claude/exact_skills/exact_alpha-skill/SKILL.md" ]
}

@test "assembly: a failed staging swap fails loud" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_HOME/fake-git/mv"
    chmod +x "$TEST_HOME/fake-git/mv"
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"staging swap failed"* ]]
}

@test "assembly: a dangling symlink is warned about, not silently dropped" {
    ln -s "$ROOT/nonexistent-target" "$ROOT/claude/commands/dangling-link"
    run_assembly
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping unreadable entry"* ]]
    [[ "$output" == *"dangling-link"* ]]
}

@test "assembly: a harness id merely containing 'claude' does not match the hook filter" {
    # jq/yq array-contains is substring-matching on string elements; the
    # filter must use exact membership (index) so e.g. claude-desktop
    # never rides along.
    cat >> "$ROOT/agents/hooks/registry.yaml" <<'YAML'
  desktop-only:
    event: Stop
    script: agents/hooks/desktop-only.sh
    harnesses: [claude-desktop]
YAML
    printf '#!/bin/bash\nexit 0\n' > "$ROOT/agents/hooks/desktop-only.sh"
    chmod +x "$ROOT/agents/hooks/desktop-only.sh"
    run_assembly
    [ "$status" -eq 0 ]
    [ ! -e "$SRC/dot_claude/exact_hooks/executable_desktop-only.sh" ]
}

@test "assembly: per-source harnesses excluding claude is skipped" {
    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/ext-repo:
    harnesses: [codex]
YAML
    run_assembly
    [ "$status" -eq 0 ]
    [ ! -e "$SRC/dot_claude/exact_skills/exact_ext-skill" ]
}


@test "OMP assembly: mirrors selected and OMP-eligible external skills into native discovery path" {
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && sync_omp_chezmoi_sources '$ROOT' '$SRC'"
    [ "$status" -eq 0 ]
    local base="$SRC/dot_omp/private_agent/exact_skills"
    [ -f "$base/exact_alpha-skill/SKILL.md" ]
    [ -f "$base/exact_beta-skill/SKILL.md" ]
    [ -f "$base/exact_ext-skill/SKILL.md" ]
}

@test "assembly: a source with skills_path vendors skills discovered under the nested dir" {
    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/plugin-repo:
    skills_path: plugins/thing/skills
YAML
    local nested="$TEST_HOME/.cache/dotfiles/claude-skill-sources/owner__plugin-repo"
    mkdir -p "$nested/.git" "$nested/plugins/thing/skills/nested-skill"
    echo "# nested" > "$nested/plugins/thing/skills/nested-skill/SKILL.md"
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_claude/exact_skills/exact_nested-skill/SKILL.md" ]
}

@test "assembly: a source without skills_path still vendors from repo-root skills/ (default unchanged)" {
    # owner/ext-repo (setup fixture) has no skills_path; its skill lives at
    # the repo-root skills/ext-skill, the pre-skills_path default location.
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_claude/exact_skills/exact_ext-skill/SKILL.md" ]
}

@test "assembly: a skills_path escaping the cache subtree fails loud" {
    for bad in "../evil" "/abs/path" '""'; do
        cat > "$ROOT/skills/_registry.yaml" <<YAML
sources:
  owner/plugin-repo:
    skills_path: $bad
YAML
        local nested="$TEST_HOME/.cache/dotfiles/claude-skill-sources/owner__plugin-repo"
        mkdir -p "$nested/.git"
        run_assembly
        [ "$status" -ne 0 ] || { echo "skills_path '$bad' did not fail"; return 1; }
        [[ "$output" == *"invalid skills_path"* ]]
    done
}

@test "assembly: a vendored skill name colliding with a local skill warns" {
    mkdir -p "$ROOT/skills/ext-skill"
    echo "# local ext" > "$ROOT/skills/ext-skill/SKILL.md"
    cat > "$SRC/.chezmoidata/claude.yaml" <<'YAML'
claude:
  skills:
    - alpha-skill
    - beta-skill
    - ext-skill
  agents:
    - tester
YAML
    run_assembly
    [ "$status" -eq 0 ]
    [[ "$output" == *"ext-skill"* ]]
    [[ "$output" == *"overwrites a local skill"* ]]
}

@test "assembly: explicit skills list resolves under skills_path" {
    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/plugin-repo:
    skills_path: plugins/thing/skills
    skills: [nested-skill]
YAML
    local nested="$TEST_HOME/.cache/dotfiles/claude-skill-sources/owner__plugin-repo"
    mkdir -p "$nested/.git" "$nested/plugins/thing/skills/nested-skill"
    echo "# nested" > "$nested/plugins/thing/skills/nested-skill/SKILL.md"
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_claude/exact_skills/exact_nested-skill/SKILL.md" ]
}
