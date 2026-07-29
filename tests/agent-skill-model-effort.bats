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
# Scope: Claude models/efforts plus the Codex model tier paired to each agent.
# The Codex mapping is high/opus→Sol, medium/sonnet→Terra, low/haiku→Luna.
# xhigh/max remain reserved for the manual deep-think path and must not appear
# on any agent/skill.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
REGISTRY="$DOTFILES_DIR/agents/registry.yaml"
MODELS="$DOTFILES_DIR/agents/models.yaml"
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

# Expected effort for a registry tier name. Agents name a tier; the claude
# model behind it lives in agents/models.yaml.
expected_effort_for_tier() {
    case "$1" in
        fast) echo low ;;
        mid) echo medium ;;
        deep) echo high ;;
        *) echo "UNMAPPED" ;;
    esac
}

expected_codex_model() {
    case "$1" in
        haiku) echo gpt-5.6-luna ;;
        sonnet) echo gpt-5.6-terra ;;
        opus) echo gpt-5.6-sol ;;
        *) echo "UNMAPPED" ;;
    esac
}

@test "every agent has an explicit tier and effort" {
    local a tier effort
    while IFS= read -r a; do
        tier="$(yq -r ".agents.\"$a\".tier // \"\"" "$REGISTRY")"
        effort="$(yq -r ".agents.\"$a\".effort // \"\"" "$REGISTRY")"
        [[ -n "$tier" ]] || { echo "agent '$a' has no tier" >&2; return 1; }
        [[ -n "$effort" ]] || { echo "agent '$a' has no effort" >&2; return 1; }
    done < <(yq -r '.agents | keys | .[]' "$REGISTRY")
}

@test "every agent's effort matches the tier→effort mapping" {
    local a tier effort want
    while IFS= read -r a; do
        tier="$(yq -r ".agents.\"$a\".tier" "$REGISTRY")"
        effort="$(yq -r ".agents.\"$a\".effort" "$REGISTRY")"
        want="$(expected_effort_for_tier "$tier")"
        [[ "$want" != "UNMAPPED" ]] \
            || { echo "agent '$a' tier '$tier' is outside the fast/mid/deep mapping" >&2; return 1; }
        [[ "$effort" == "$want" ]] \
            || { echo "agent '$a' is $tier/$effort — mapping wants $tier/$want" >&2; return 1; }
    done < <(yq -r '.agents | keys | .[]' "$REGISTRY")
}

@test "every tier in agents/models.yaml pairs its claude and codex models" {
    # This used to be asserted 16 times, once per agent. The pins table is now
    # the only place the pairing is written down, so assert it there — and
    # assert every tier the effort mapping knows about actually exists.
    local tier claude_model codex_model want
    while IFS= read -r tier; do
        claude_model="$(yq -r ".pins.\"$tier\".claude // \"\"" "$MODELS")"
        codex_model="$(yq -r ".pins.\"$tier\".codex // \"\"" "$MODELS")"
        want="$(expected_codex_model "$claude_model")"
        [[ "$want" != "UNMAPPED" ]] \
            || { echo "tier '$tier' claude model '$claude_model' has no Codex tier mapping" >&2; return 1; }
        [[ "$codex_model" == "$want" ]] \
            || { echo "tier '$tier' codex model '$codex_model' — mapping wants '$want'" >&2; return 1; }
        [[ "$(expected_effort "$claude_model")" == "$(expected_effort_for_tier "$tier")" ]] \
            || { echo "tier '$tier' names claude model '$claude_model' but their efforts disagree" >&2; return 1; }
    done < <(yq -r '.pins | keys | .[]' "$MODELS")

    for tier in fast mid deep; do
        [[ "$(yq -r ".pins.\"$tier\" // \"\"" "$MODELS")" != "" ]] \
            || { echo "agents/models.yaml is missing tier '$tier'" >&2; return 1; }
    done
}

@test "no agent carries a reserved xhigh/max effort" {
    local a effort
    while IFS= read -r a; do
        effort="$(yq -r ".agents.\"$a\".effort // \"\"" "$REGISTRY")"
        [[ "$effort" != "xhigh" && "$effort" != "max" ]] \
            || { echo "agent '$a' has reserved effort '$effort' (xhigh/max are manual-only)" >&2; return 1; }
    done < <(yq -r '.agents | keys | .[]' "$REGISTRY")
}

# An agent may still override a single harness inline. Those overrides are
# deliberate escapes from the tier, so assert only that they are not a silent
# re-transcription of what the tier already says.
@test "no agent's inline models override restates its tier" {
    local a tier harness inline pinned
    while IFS= read -r a; do
        tier="$(yq -r ".agents.\"$a\".tier // \"\"" "$REGISTRY")"
        [[ -n "$tier" ]] || continue
        for harness in claude codex; do
            inline="$(yq -r ".agents.\"$a\".models.$harness // \"\"" "$REGISTRY")"
            [[ -n "$inline" ]] || continue
            pinned="$(yq -r ".pins.\"$tier\".$harness // \"\"" "$MODELS")"
            [[ "$inline" != "$pinned" ]] \
                || { echo "agent '$a' sets models.$harness to '$inline', which tier '$tier' already gives — drop it" >&2; return 1; }
        done
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
