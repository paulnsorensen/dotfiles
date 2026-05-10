#!/bin/bash
#
# sync.sh - Install agent skills via `gh skill install` per harness
#
# Reads SKILL_HARNESSES from .env (space-separated agent IDs) and installs
# every skill discovered in each source repo from registry.yaml into each
# harness at user scope.
#
# Usage:
#   ./sync.sh           Install/update all skills for each configured harness
#   ./sync.sh --dry-run Show what would change without making changes
#

set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
REGISTRY_FILE="$SCRIPT_DIR/registry.yaml"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=claude/lib/sync-common.sh
source "$DOTFILES_DIR/claude/lib/sync-common.sh"

sync_parse_args "$@"

# Skill sync needs gh + yq + jq (claude is not required here)
for cmd in gh yq jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error: $cmd not found. Install with: brew install $cmd${NC}" >&2
        exit 1
    fi
done

if ! gh skill --help &> /dev/null; then
    echo -e "${RED}Error: 'gh skill' subcommand not available. Upgrade gh CLI to v2.90+.${NC}" >&2
    exit 1
fi

# Source .env for SKILL_HARNESSES
if [[ -f "$DOTFILES_DIR/.env" ]]; then
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        # Strip surrounding quotes from value (env loader is naive)
        val="${val%\"}"
        val="${val#\"}"
        export "$key=$val"
    done < "$DOTFILES_DIR/.env"
fi

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo -e "${RED}Error: Registry file not found at $REGISTRY_FILE${NC}" >&2
    exit 1
fi

echo -e "${BLUE}Skill Sync - Declarative Skill Management${NC}"
echo

HARNESSES="${SKILL_HARNESSES:-}"
if [[ -z "$HARNESSES" ]]; then
    echo -e "${YELLOW}SKILL_HARNESSES is empty in .env — nothing to do.${NC}"
    echo "Set SKILL_HARNESSES in .env to a space-separated list of agent IDs."
    echo "Example: SKILL_HARNESSES=\"claude-code cursor codex\""
    exit 0
fi

echo -e "${BLUE}Harnesses:${NC} $HARNESSES"
echo

# Resolve skills for a source repo: explicit list from registry, or auto-discover
# via GitHub API. Echoes one skill name per line.
resolve_skills() {
    local repo="$1"
    local explicit
    explicit=$(yq -o=json ".sources.\"$repo\".skills // []" "$REGISTRY_FILE" | jq -r '.[]?')
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return 0
    fi
    # Auto-discover via GitHub API. Failure (private repo, network, missing
    # skills/ dir) is non-fatal — caller surfaces "No skills discovered".
    local response
    response=$(gh api "repos/$repo/contents/skills" 2>/dev/null) || return 0
    echo "$response" | jq -r '.[] | select(.type == "dir") | .name' | sort
}

# Install one (repo, skill, harness) tuple
install_skill() {
    local repo="$1" skill="$2" harness="$3" pin="$4"
    local args=(skill install "$repo" "$skill" --agent "$harness" --scope user --force)
    [[ -n "$pin" && "$pin" != "null" ]] && args+=(--pin "$pin")

    if $DRY_RUN; then
        echo -e "    ${BLUE}[dry-run]${NC} gh ${args[*]}"
        return 0
    fi

    local output
    if output=$(gh "${args[@]}" 2>&1); then
        echo -e "    ${GREEN}✓${NC} $skill → $harness"
    else
        echo -e "    ${RED}✗${NC} $skill → $harness"
        if [[ -n "$output" ]]; then
            echo "$output" | head -3 | sed -e "s/^/      /"
        fi
    fi
}

SOURCES=$(yq -o=json '.sources' "$REGISTRY_FILE" | jq -r 'keys[]')
if [[ -z "$SOURCES" ]]; then
    echo -e "${YELLOW}No sources defined in registry.${NC}"
    exit 0
fi

for repo in $SOURCES; do
    description=$(yq -r ".sources.\"$repo\".description // \"\"" "$REGISTRY_FILE")
    pin=$(yq -r ".sources.\"$repo\".pin // \"\"" "$REGISTRY_FILE")

    echo -e "${BLUE}Source:${NC} $repo"
    [[ -n "$description" ]] && echo "  $description"

    skills=$(resolve_skills "$repo")
    if [[ -z "$skills" ]]; then
        echo -e "  ${YELLOW}No skills discovered.${NC}"
        echo
        continue
    fi

    skill_count=$(echo "$skills" | grep -c .)
    echo -e "  ${BLUE}Skills ($skill_count):${NC} $(echo "$skills" | tr '\n' ' ')"
    echo

    for harness in $HARNESSES; do
        echo -e "  ${BLUE}→ $harness${NC}"
        while IFS= read -r skill; do
            [[ -z "$skill" ]] && continue
            install_skill "$repo" "$skill" "$harness" "$pin"
        done <<< "$skills"
        echo
    done
done

echo -e "${GREEN}Sync complete!${NC}"
echo
echo -e "${BLUE}Run 'gh skill update --all --dry-run' to inspect installed versions.${NC}"
