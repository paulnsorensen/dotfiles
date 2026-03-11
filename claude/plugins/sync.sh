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

sync_parse_args "$@"
sync_check_deps

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo -e "${RED}Error: Registry file not found at $REGISTRY_FILE${NC}" >&2
    exit 1
fi

echo -e "${BLUE}Plugin Sync - Declarative Plugin Management${NC}"
echo

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
