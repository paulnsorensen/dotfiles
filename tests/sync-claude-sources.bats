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
    maxTurns: 42
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
maxTurns: 42
skills: [alpha-skill]
---
Agent body.
EXPECTED
}

@test "assembly: claude-harness hook scripts land executable; codex-only and command-only do not" {
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_claude/exact_hooks/executable_claude-hook.sh" ]
    [ ! -e "$SRC/dot_claude/exact_hooks/executable_codex-only.sh" ]
    # claude/hooks assets copied alongside.
    [ -f "$SRC/dot_claude/exact_hooks/runner.js" ]
}

@test "assembly: reference merges claude/reference and agents/reference" {
    run_assembly
    [ "$status" -eq 0 ]
    [ -f "$SRC/dot_claude/exact_reference/doc.md" ]
    [ -f "$SRC/dot_claude/exact_reference/bank.md" ]
}

@test "assembly: vendors external skills from the cache when offline (refresh mode)" {
    # FORCE_PACKAGES (dots sync refresh) opts into the float-to-latest pull;
    # the failing git shim simulates offline — cache fallback with a warning.
    export FORCE_PACKAGES=true
    run_assembly
    [ "$status" -eq 0 ]
    [[ "$output" == *"using cached checkout"* ]]
    [ -f "$SRC/dot_claude/exact_skills/exact_ext-skill/SKILL.md" ]
}

@test "assembly: plain sync never hits the network for a cached unpinned source" {
    # Float-to-latest is opt-in (dots sync refresh); the plain-sync hot path
    # must vendor straight from the cache with zero git invocations.
    run_assembly
    [ "$status" -eq 0 ]
    [ ! -f "$GIT_CALLS" ]
    [ -f "$SRC/dot_claude/exact_skills/exact_ext-skill/SKILL.md" ]
}

@test "assembly: a changed pin on a cached source is fetched, checked out, and recorded" {
    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/ext-repo:
    pin: v2.0.0
YAML
    # git shim that succeeds (fetch/checkout are no-ops against the cache).
    cat > "$TEST_HOME/fake-git/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_CALLS"
exit 0
SH
    run_assembly
    [ "$status" -eq 0 ]
    grep -q "fetch --depth 1 origin v2.0.0" "$GIT_CALLS"
    grep -q "checkout --detach FETCH_HEAD" "$GIT_CALLS"
    [ "$(cat "$CACHE/.dotfiles-pin")" = "v2.0.0" ]
    # Same pin again: marker short-circuits — no further network.
    : > "$GIT_CALLS"
    run_assembly
    [ "$status" -eq 0 ]
    [ ! -s "$GIT_CALLS" ]
}

@test "assembly: a pin that cannot be fetched fails loud" {
    cat > "$ROOT/skills/_registry.yaml" <<'YAML'
sources:
  owner/ext-repo:
    pin: v9.9.9
YAML
    run_assembly
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot check out pin"* ]]
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
