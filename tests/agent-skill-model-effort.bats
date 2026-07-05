#!/usr/bin/env bats
# Guard the agent/skill model+effort retune (spec: agent-model-effort-retune).
#
# WHY: the retune's whole premise is that EVERY agent and skill carries an
# EXPLICIT model+effort following ONE uniform tier→effort mapping
# (haiku→low, sonnet→medium, opus→high). Nothing else in the suite pins those
# values, so a future edit could drop an effort, flip sonnet→high, or leave a
# skill model-less and every other test would still pass. These assertions are
# the regression guard for the retune: they fail the moment the mapping drifts.
#
# Scope: the Claude tier only (models.claude / skill `model:`) and the shared
# `effort:` field — the axes the spec retuned. Per-harness codex/cursor models
# are deliberately out of scope (spec Locked Decision 4). xhigh/max are reserved
# for the manual deep-think path and must not appear on any agent/skill.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
REGISTRY="$DOTFILES_DIR/agents/registry.yaml"
CLAUDE_YAML="$DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"

setup() { command -v yq >/dev/null 2>&1 || skip "yq not installed"; }

# Expected effort for a claude model tier, per the uniform mapping rule.
expected_effort() {
    case "$1" in
        haiku) echo low ;;
        sonnet) echo medium ;;
        opus) echo high ;;
        *) echo "UNMAPPED" ;;
    esac
}

@test "every agent has an explicit claude model and effort" {
    local a model effort
    while IFS= read -r a; do
        model="$(yq -r ".agents.\"$a\".models.claude // \"\"" "$REGISTRY")"
        effort="$(yq -r ".agents.\"$a\".effort // \"\"" "$REGISTRY")"
        [[ -n "$model" ]] || { echo "agent '$a' has no models.claude" >&2; return 1; }
        [[ -n "$effort" ]] || { echo "agent '$a' has no effort" >&2; return 1; }
    done < <(yq -r '.agents | keys | .[]' "$REGISTRY")
}

@test "every agent's effort matches the tier→effort mapping" {
    local a model effort want
    while IFS= read -r a; do
        model="$(yq -r ".agents.\"$a\".models.claude" "$REGISTRY")"
        effort="$(yq -r ".agents.\"$a\".effort" "$REGISTRY")"
        want="$(expected_effort "$model")"
        [[ "$want" != "UNMAPPED" ]] \
            || { echo "agent '$a' claude model '$model' is outside the haiku/sonnet/opus mapping" >&2; return 1; }
        [[ "$effort" == "$want" ]] \
            || { echo "agent '$a' is $model/$effort — mapping wants $model/$want" >&2; return 1; }
    done < <(yq -r '.agents | keys | .[]' "$REGISTRY")
}

@test "no agent carries a reserved xhigh/max effort" {
    local a effort
    while IFS= read -r a; do
        effort="$(yq -r ".agents.\"$a\".effort // \"\"" "$REGISTRY")"
        [[ "$effort" != "xhigh" && "$effort" != "max" ]] \
            || { echo "agent '$a' has reserved effort '$effort' (xhigh/max are manual-only)" >&2; return 1; }
    done < <(yq -r '.agents | keys | .[]' "$REGISTRY")
}

@test "every selected skill has an explicit model and effort" {
    local s fm model effort
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        fm="$(awk '/^---/{c++; if(c==2)exit; if(c==1)next} c==1{print}' "$DOTFILES_DIR/skills/$s/SKILL.md")"
        model="$(echo "$fm" | yq -r '.model // ""')"
        effort="$(echo "$fm" | yq -r '.effort // ""')"
        [[ -n "$model" ]] || { echo "skill '$s' has no model:" >&2; return 1; }
        [[ -n "$effort" ]] || { echo "skill '$s' has no effort:" >&2; return 1; }
    done < <(yq -r '.claude.skills[]' "$CLAUDE_YAML")
}

@test "every selected skill's effort matches the tier→effort mapping" {
    local s fm model effort want
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        fm="$(awk '/^---/{c++; if(c==2)exit; if(c==1)next} c==1{print}' "$DOTFILES_DIR/skills/$s/SKILL.md")"
        model="$(echo "$fm" | yq -r '.model // ""')"
        effort="$(echo "$fm" | yq -r '.effort // ""')"
        want="$(expected_effort "$model")"
        [[ "$want" != "UNMAPPED" ]] \
            || { echo "skill '$s' model '$model' is outside the haiku/sonnet/opus mapping" >&2; return 1; }
        [[ "$effort" == "$want" ]] \
            || { echo "skill '$s' is $model/$effort — mapping wants $model/$want" >&2; return 1; }
    done < <(yq -r '.claude.skills[]' "$CLAUDE_YAML")
}

@test "no selected skill carries a reserved xhigh/max effort" {
    local s fm effort
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        fm="$(awk '/^---/{c++; if(c==2)exit; if(c==1)next} c==1{print}' "$DOTFILES_DIR/skills/$s/SKILL.md")"
        effort="$(echo "$fm" | yq -r '.effort // ""')"
        [[ "$effort" != "xhigh" && "$effort" != "max" ]] \
            || { echo "skill '$s' has reserved effort '$effort' (xhigh/max are manual-only)" >&2; return 1; }
    done < <(yq -r '.claude.skills[]' "$CLAUDE_YAML")
}

@test "self-eval is gone from the selected skills list" {
    ! yq -r '.claude.skills[]' "$CLAUDE_YAML" | grep -qx self-eval
}
