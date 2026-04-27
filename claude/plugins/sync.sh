#!/bin/bash
#
# sync.sh - Declarative plugin sync using native claude plugin commands
#
# Usage:
#   ./sync.sh           Sync plugins (install missing, prompt to remove extras)
#   ./sync.sh --dry-run Show what would change without making changes
#   ./sync.sh --force   Remove extras without prompting
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="$SCRIPT_DIR/registry.yaml"
SETTINGS_FILE="$SCRIPT_DIR/../settings.json"

# shellcheck source=../lib/sync-common.sh
source "$SCRIPT_DIR/../lib/sync-common.sh"

DOTFILES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

sync_parse_args "$@"
sync_check_deps

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo -e "${RED}Error: Registry file not found at $REGISTRY_FILE${NC}" >&2
    exit 1
fi

echo -e "${BLUE}Plugin Sync - Declarative Plugin Management${NC}"
echo

# Sync local plugin marketplaces — resolve relative paths to absolute
sync_local_marketplaces() {
    local local_entries
    local_entries=$(yq -o=json '.plugins' "$REGISTRY_FILE" | jq -c 'to_entries[] | select(.value.path) | {plugin: (.key | split("@") | .[0]), name: (.key | split("@") | .[1]), path: .value.path}' 2>/dev/null || true)
    [[ -z "$local_entries" ]] && return 0

    local changed=false
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local plugin_name mp_name mp_path abs_path current_path
        plugin_name=$(echo "$entry" | jq -r '.plugin')
        mp_name=$(echo "$entry" | jq -r '.name')
        mp_path=$(echo "$entry" | jq -r '.path')

        # Skip shared marketplaces (e.g. `@local`) — those are registered manually
        # via `claude plugin marketplace add` and may host multiple plugins.
        # Only auto-manage one-plugin-per-marketplace entries.
        if [[ "$mp_name" != "$plugin_name" ]]; then
            continue
        fi

        # shellcheck disable=SC2088  # literal "~/" pattern, expanded explicitly below
        case "$mp_path" in
            "~/"*) abs_path="${HOME}/${mp_path#"~/"}" ;;
            /*)    abs_path="$mp_path" ;;
            *)     abs_path="$DOTFILES_DIR/$mp_path" ;;
        esac

        if [[ ! -d "$abs_path" ]]; then
            echo -e "  ${RED}Warning: $mp_name path not found: $abs_path${NC}"
            continue
        fi

        current_path=$(jq -r --arg n "$mp_name" '.extraKnownMarketplaces[$n].source.path // ""' "$SETTINGS_FILE" 2>/dev/null || true)
        if [[ "$current_path" != "$abs_path" ]]; then
            if $DRY_RUN; then
                echo -e "  ${BLUE}[dry-run]${NC} Would set $mp_name marketplace → $abs_path"
            else
                jq --arg n "$mp_name" --arg p "$abs_path" \
                    '.extraKnownMarketplaces[$n] = {"source": {"source": "directory", "path": $p}}' \
                    "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
                echo -e "  ${GREEN}Updated $mp_name marketplace → $abs_path${NC}"
            fi
            changed=true
        fi
    done < <(echo "$local_entries" | jq -c '.')

    if ! $changed; then
        echo -e "  ${BLUE}Local marketplaces up to date${NC}"
    fi
    echo
}

if [[ -f "$SETTINGS_FILE" ]]; then
    echo -e "${BLUE}Syncing local marketplace paths...${NC}"
    sync_local_marketplaces
fi

# shellcheck disable=SC2034  # used by sync-common.sh
DESIRED_NAMES=$(yq '.plugins | keys | .[]' "$REGISTRY_FILE" | sort)

# shellcheck disable=SC2034  # used by sync-common.sh
if [[ -f "$SETTINGS_FILE" ]] && jq -e '.enabledPlugins' "$SETTINGS_FILE" &>/dev/null; then
    CURRENT_NAMES=$(jq -r '.enabledPlugins | keys[]' "$SETTINGS_FILE" | sort)
else
    CURRENT_NAMES=""
fi

get_description() { yq ".plugins.\"$1\".description // \"\"" "$REGISTRY_FILE"; }
get_item_scope() { echo "user"; }
remove_item() { claude plugin remove -s "$2" "$1" 2>/dev/null; }

sync_compute_diff
sync_show_plan "plugins" || exit 0

if [[ -n "$TO_ADD" ]]; then
    echo -e "${GREEN}Installing missing plugins...${NC}"
    echo "$TO_ADD" | while read -r name; do
        [[ -z "$name" ]] && continue
        scope=$(yq ".plugins.\"$name\".scope // \"user\"" "$REGISTRY_FILE")

        if $DRY_RUN; then
            echo -e "  ${BLUE}[dry-run]${NC} Would run: claude plugin install -s $scope $name"
        else
            echo -n "  Installing $name... "
            if claude plugin install -s "$scope" "$name" 2>/dev/null; then
                echo -e "${GREEN}done${NC}"
            else
                echo -e "${RED}failed${NC}"
            fi
        fi
    done
    echo
fi

sync_handle_removals "Plugins"

if [[ -f "$SETTINGS_FILE" ]]; then
    echo -e "${BLUE}Syncing enabledPlugins in settings.json...${NC}"

    ENABLED_JSON=$(yq -o=json '.plugins' "$REGISTRY_FILE" | jq 'to_entries | map({(.key): (.value.load // false)}) | add')

    if $DRY_RUN; then
        echo -e "  ${BLUE}[dry-run]${NC} Would set enabledPlugins to:"
        echo "$ENABLED_JSON" | jq .
    else
        jq --argjson plugins "$ENABLED_JSON" '.enabledPlugins = $plugins' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" \
            && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
        echo -e "  ${GREEN}Updated enabledPlugins${NC}"
    fi
    echo
fi

echo -e "${GREEN}Sync complete!${NC}"
echo
echo -e "${BLUE}Run 'claude plugin list' to verify${NC}"
echo -e "${YELLOW}Restart Claude Code for changes to take effect${NC}"
