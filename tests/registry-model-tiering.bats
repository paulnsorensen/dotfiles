#!/usr/bin/env bats
# Tier invariant for the real agents/registry.yaml (spec:
# orchestration-model-tiering). Renders each agent's claude frontmatter via
# _cz_render_claude_agent and asserts the model/effort tier its ROLE demands:
#
#   backbone (explorer/researcher/coder/generalist) -> model: inherit, no effort
#     (cascades both axes with the session)
#   gates    (reviewer/fromage-secaudit/fromage-age-arch) -> opus / high
#     (must never downgrade in a lean session)
#   workers  (whey-drainer/duckdb-expert/fromage-age-history/
#             worktree-content-digest) -> haiku / low (must never upgrade)
#   brain    (deep-thinker) -> fable / xhigh (the deliberate reasoning tier)
#
# A tier change to any of these is deliberate by design; this test makes an
# accidental one fail loud rather than ship silently.

load test_helper

setup() {
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    ROOT="$REAL_DOTFILES_DIR"
    REG="$ROOT/agents/registry.yaml"
    RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tier-render.XXXXXX")"
    export ROOT REG RENDER_DIR
}

teardown() { rm -rf "$RENDER_DIR"; }

render() {
    # render <agent-name> -> frontmatter+body on stdout
    local name="$1" out="$RENDER_DIR/$1.md"
    bash -c "source '$ROOT/.sync-lib.sh' && _cz_render_claude_agent '$REG' '$name' '$ROOT' '$out'" || return 1
    cat "$out"
}

@test "backbone agents render model: inherit and no effort key" {
    for a in explorer researcher coder generalist; do
        run render "$a"
        [ "$status" -eq 0 ] || { echo "render $a failed: $output"; return 1; }
        [[ "$output" == *"model: inherit"* ]] || { echo "$a: expected 'model: inherit'"; echo "$output"; return 1; }
        # no effort line at all — both axes cascade with the session
        if grep -q '^effort:' <<<"$output"; then
            echo "$a: expected NO effort key, found one"; echo "$output"; return 1
        fi
    done
}

@test "quality-gate agents stay pinned opus / high" {
    for a in reviewer fromage-secaudit fromage-age-arch; do
        run render "$a"
        [ "$status" -eq 0 ] || { echo "render $a failed: $output"; return 1; }
        [[ "$output" == *"model: opus"* ]] || { echo "$a: expected 'model: opus'"; echo "$output"; return 1; }
        [[ "$output" == *"effort: high"* ]] || { echo "$a: expected 'effort: high'"; echo "$output"; return 1; }
    done
}

@test "mechanical worker agents stay pinned haiku / low" {
    for a in whey-drainer duckdb-expert fromage-age-history worktree-content-digest; do
        run render "$a"
        [ "$status" -eq 0 ] || { echo "render $a failed: $output"; return 1; }
        [[ "$output" == *"model: haiku"* ]] || { echo "$a: expected 'model: haiku'"; echo "$output"; return 1; }
        [[ "$output" == *"effort: low"* ]] || { echo "$a: expected 'effort: low'"; echo "$output"; return 1; }
    done
}

@test "deep-thinker brain renders fable / xhigh and is read-only" {
    run render deep-thinker
    [ "$status" -eq 0 ] || { echo "render deep-thinker failed: $output"; return 1; }
    [[ "$output" == *"model: fable"* ]] || { echo "expected 'model: fable'"; echo "$output"; return 1; }
    [[ "$output" == *"effort: xhigh"* ]] || { echo "expected 'effort: xhigh'"; echo "$output"; return 1; }
    # brain, not hands: Edit/Write must be denied
    [[ "$output" == *"disallowedTools:"*"Edit"* ]] || { echo "expected Edit in disallowedTools"; echo "$output"; return 1; }
    [[ "$output" == *"Write"* ]] || { echo "expected Write denied"; echo "$output"; return 1; }
}

@test "deep-thinker is selected in the claude registry so it deploys" {
    run yq -r '.claude.agents // [] | .[]' "$ROOT/chezmoi/.chezmoidata/claude.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deep-thinker"* ]] || { echo "deep-thinker not in claude.yaml agents:"; echo "$output"; return 1; }
}
