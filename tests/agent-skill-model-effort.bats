#!/usr/bin/env bats
# Guard Claude tier→effort policy and workload-specific Codex model routes.
#
# Canonical agents and selected skills retain the Claude haiku→low,
# sonnet→medium, opus→high mapping; xhigh/max remain manual-only. Codex models
# are workload-specific, and OMP thinking is locked separately in omp-agents.bats.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
REGISTRY="$DOTFILES_DIR/agents/registry.yaml"
CLAUDE_YAML="$DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"

setup() { command -v yq >/dev/null 2>&1 || skip "yq not installed"; }

expected_effort() {
    case "$1" in
        haiku) echo low ;;
        sonnet) echo medium ;;
        opus) echo high ;;
        *) echo "UNMAPPED" ;;
    esac
}

expected_agent_codex_model() {
    case "$1" in
        reviewer) echo gpt-5.6-sol ;;
        ghostbuster|researcher|generalist) echo gpt-5.6-terra ;;
        roquefort-wrecker|coder|explorer|nih-scanner|duckdb-expert|whey-drainer|worktree-content-digest) echo gpt-5.6-luna ;;
        *) echo UNMAPPED ;;
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

@test "every agent's effort matches the Claude tier→effort mapping" {
    local a model effort want
    while IFS= read -r a; do
        model="$(yq -r ".agents.\"$a\".models.claude // \"\"" "$REGISTRY")"
        effort="$(yq -r ".agents.\"$a\".effort // \"\"" "$REGISTRY")"
        want="$(expected_effort "$model")"
        [[ "$want" != "UNMAPPED" ]] \
            || { echo "agent '$a' model '$model' is outside the haiku/sonnet/opus mapping" >&2; return 1; }
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

@test "every agent matches its workload-specific Codex model" {
    local a codex_model want
    while IFS= read -r a; do
        codex_model="$(yq -r ".agents.\"$a\".models.codex // \"\"" "$REGISTRY")"
        want="$(expected_agent_codex_model "$a")"
        [[ "$want" != "UNMAPPED" ]] \
            || { echo "agent '$a' has no workload route" >&2; return 1; }
        [[ "$codex_model" == "$want" ]] \
            || { echo "agent '$a' uses $codex_model — workload policy wants $want" >&2; return 1; }
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
