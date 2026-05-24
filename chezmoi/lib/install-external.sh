#!/bin/bash
#
# install-external.sh — Install agent skills via `gh skill install` per harness
#
# Reads SKILL_HARNESSES from .env (space-separated agent IDs) and installs
# every skill discovered in each source repo from the given registry into
# each harness at user scope.
#
# Usage:
#   install-external.sh <registry_path>           Install/update all skills
#   install-external.sh <registry_path> --dry-run Show what would change
#

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <registry_path> [--dry-run]" >&2
    exit 2
fi

REGISTRY_FILE="$1"
shift

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
# Script lives at chezmoi/lib/, dotfiles root is two levels up.
DOTFILES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../claude/lib/sync-common.sh
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
        key="${key#export }"
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

# Cache: skip when registry content + harness list match the last successful
# run. Bust with --force, by deleting $CACHE_FILE, or by running
# `gh skill update --all` to pull upstream changes.
CACHE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/skill-external-hash"
REGISTRY_DIGEST=$(shasum -a 256 "$REGISTRY_FILE" | awk '{print $1}')
COMBINED_DIGEST=$(printf '%s\n%s\n' "$REGISTRY_DIGEST" "$HARNESSES" | shasum -a 256 | awk '{print $1}')

if ! $FORCE && ! $DRY_RUN && [[ -f "$CACHE_FILE" ]] && [[ "$(cat "$CACHE_FILE" 2>/dev/null)" == "$COMBINED_DIGEST" ]]; then
    echo -e "${GREEN}Registry + harnesses unchanged since last sync — skipping.${NC}"
    echo "  Pass --force, delete $CACHE_FILE, or run 'gh skill update --all' to refresh."
    exit 0
fi

# Failure counter shared across parallel subshells via tempfile (one line per fail).
FAIL_COUNTER=$(mktemp "${TMPDIR:-/tmp}/skill-fail.XXXXXX")
export FAIL_COUNTER
trap 'rm -f "$FAIL_COUNTER"' EXIT

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
        echo x >> "$FAIL_COUNTER"
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

    # Parallel fan-out: one subshell per harness. Each writes to stdout +
    # the shared $FAIL_COUNTER tempfile. Output interleaves across harnesses,
    # but every install line is self-identifying ("✓ <skill> → <harness>").
    pids=()
    for harness in $HARNESSES; do
        {
            while IFS= read -r skill; do
                [[ -z "$skill" ]] && continue
                install_skill "$repo" "$skill" "$harness" "$pin"
            done <<< "$skills"
        } &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    echo
done

fail_count=0
if [[ -s "$FAIL_COUNTER" ]]; then
    fail_count=$(wc -l < "$FAIL_COUNTER" | tr -d ' ')
fi

if [[ "$fail_count" -gt 0 ]]; then
    # Fail loud: propagate non-zero so the chezmoi run_onchange records the
    # apply as failed and reruns next `dots sync` instead of marking success
    # and skipping until the skills tree hash changes (the silent partial
    # install regression mode).
    echo -e "${RED}$fail_count install(s) failed — cache not updated. Re-run to retry.${NC}" >&2
    exit 1
fi

if ! $DRY_RUN; then
    mkdir -p "$(dirname "$CACHE_FILE")"
    echo "$COMBINED_DIGEST" > "$CACHE_FILE"
fi

echo -e "${GREEN}Sync complete!${NC}"
echo
echo -e "${BLUE}Run 'gh skill update --all --dry-run' to inspect installed versions.${NC}"
