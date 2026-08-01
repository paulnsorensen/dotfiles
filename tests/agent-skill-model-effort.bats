#!/usr/bin/env bats
# Guard workload-specific agent routes and the selected-skill effort policy.
#
# Agents choose the Codex capability tier from task breadth and stakes, then
# choose effort independently from reasoning demand. This keeps bounded workers
# on Luna without forcing low effort and reserves Sol for quality-first review.
# Selected Claude skills retain the uniform haiku→low, sonnet→medium,
# opus→high mapping; xhigh/max remain manual-only for skills.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
REGISTRY="$DOTFILES_DIR/agents/registry.yaml"
CLAUDE_YAML="$DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"

setup() { command -v yq >/dev/null 2>&1 || skip "yq not installed"; }

# Expected effort for selected skills, per their uniform Claude tier mapping.
expected_effort() {
    case "$1" in
        haiku) echo low ;;
        sonnet) echo medium ;;
        opus) echo high ;;
        *) echo "UNMAPPED" ;;
    esac
}

expected_agent_route() {
    case "$1" in
        fromage-age-arch|fromage-secaudit|reviewer) echo "gpt-5.6-sol xhigh" ;;
        ghostbuster|ricotta-reducer|researcher) echo "gpt-5.6-terra high" ;;
        generalist) echo "gpt-5.6-terra xhigh" ;;
        fromage-fort|roquefort-wrecker|coder) echo "gpt-5.6-luna xhigh" ;;
        explorer) echo "gpt-5.6-luna high" ;;
        nih-scanner) echo "gpt-5.6-luna medium" ;;
        fromage-age-history|duckdb-expert|whey-drainer|worktree-content-digest) echo "gpt-5.6-luna low" ;;
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

@test "every agent matches its workload-specific Codex model and effort" {
    local a codex_model effort want actual
    while IFS= read -r a; do
        codex_model="$(yq -r ".agents.\"$a\".models.codex // \"\"" "$REGISTRY")"
        effort="$(yq -r ".agents.\"$a\".effort // \"\"" "$REGISTRY")"
        want="$(expected_agent_route "$a")"
        [[ "$want" != "UNMAPPED" ]] \
            || { echo "agent '$a' has no workload route" >&2; return 1; }
        actual="$codex_model $effort"
        [[ "$actual" == "$want" ]] \
            || { echo "agent '$a' is $actual — workload policy wants $want" >&2; return 1; }
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
