#!/bin/bash
#
# sync.sh - Declarative plugin sync using native claude plugin commands
#
# Ownership split (single-writer for settings.json plugin keys):
#   * THIS SCRIPT installs/removes plugin payloads via `claude plugin
#     install/remove` and registers local marketplaces with the CLI via
#     `claude plugin marketplace add`. It writes NOTHING to settings.json.
#   * chezmoi/dot_claude/modify_settings.json is the sole writer of
#     settings.json's `enabledPlugins` and `extraKnownMarketplaces` (claude.yaml
#     base + gate-filtered registry overlay, composed at `chezmoi apply` time).
#
# Removal diffing sources ~/.claude/plugins/installed_plugins.json (user-scoped
# keys only), NOT settings.json — so installed-but-disabled plugins are removal
# candidates and project-scoped plugins are never touched.
#
# Usage:
#   ./sync.sh           Sync plugins (install missing, prompt to remove extras)
#   ./sync.sh --dry-run Show what would change without making changes
#   ./sync.sh --force   Remove extras without prompting
#

set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
REGISTRY_FILE="$SCRIPT_DIR/registry.yaml"
# Installed-plugins manifest — the source of truth for what is actually
# installed (and at what scope). CLAUDE_INSTALLED_PLUGINS_FILE is the test seam
# for this otherwise-hardcoded path.
INSTALLED_PLUGINS_FILE="${CLAUDE_INSTALLED_PLUGINS_FILE:-$HOME/.claude/plugins/installed_plugins.json}"

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

# Filter expression: keep plugins whose `gate` is unset or whose env var is "true".
# `$g` is a jq variable, not a shell var — single quotes are intentional.
# shellcheck disable=SC2016
GATE_FILTER='select((.value.gate // "") as $g | $g == "" or (env[$g] // "false") == "true")'

# Register local plugin marketplaces with the CLI so `claude plugin install`
# can resolve them. Resolves relative/`~/` paths to absolute and gate-filters
# the same way modify_settings.json does. Does NOT write settings.json — that
# file's extraKnownMarketplaces is authored by modify_settings.json.
register_local_marketplaces() {
    local local_entries
    local_entries=$(yq -o=json '.plugins' "$REGISTRY_FILE" | jq -c "to_entries[] | $GATE_FILTER | select(.value.path) | {plugin: (.key | split(\"@\") | .[0]), name: (.key | split(\"@\") | .[1]), path: .value.path}" 2>/dev/null || true)
    [[ -z "$local_entries" ]] && return 0

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local plugin_name mp_name mp_path abs_path
        plugin_name=$(echo "$entry" | jq -r '.plugin')
        mp_name=$(echo "$entry" | jq -r '.name')
        mp_path=$(echo "$entry" | jq -r '.path')

        # Skip shared marketplaces (e.g. `@local`) — those are registered
        # elsewhere (claude/.sync sync_vaudeville_cache) and may host multiple
        # plugins. Only auto-manage one-plugin-per-marketplace entries.
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

        # `claude plugin install` can only resolve a marketplace the CLI has
        # actually registered + fetched. `marketplace add` is the idempotent op
        # that does that: it fetches when missing, no-ops when present.
        if $DRY_RUN; then
            echo -e "  ${BLUE}[dry-run]${NC} Would register $mp_name marketplace → $abs_path"
        else
            claude plugin marketplace add "$abs_path" >/dev/null 2>&1 \
                && echo -e "  ${GREEN}Registered $mp_name marketplace → $abs_path${NC}" \
                || echo -e "  ${RED}Warning: failed to register $mp_name marketplace with the CLI${NC}"
        fi
    done < <(echo "$local_entries" | jq -c '.')
    echo
}

echo -e "${BLUE}Registering local marketplaces...${NC}"
register_local_marketplaces

# shellcheck disable=SC2034  # used by sync-common.sh
DESIRED_NAMES=$(yq -o=json '.plugins' "$REGISTRY_FILE" | jq -r "to_entries[] | $GATE_FILTER | .key" | sort)

# Removal candidates come from what is actually installed at user scope.
# Project-scoped plugins are excluded here → never proposed for removal. A
# missing/empty manifest (fresh machine) yields no candidates.
# shellcheck disable=SC2034  # used by sync-common.sh
if [[ -f "$INSTALLED_PLUGINS_FILE" ]]; then
    CURRENT_NAMES=$(jq -r '
        .plugins // {}
        | to_entries[]
        | select(any(.value[]?; .scope == "user"))
        | .key
    ' "$INSTALLED_PLUGINS_FILE" 2>/dev/null | sort || true)
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

# settings.json's enabledPlugins / extraKnownMarketplaces are authored by
# chezmoi/dot_claude/modify_settings.json — this script does not write them.

echo -e "${GREEN}Sync complete!${NC}"
echo
echo -e "${BLUE}Run 'claude plugin list' to verify${NC}"
echo -e "${YELLOW}Restart Claude Code for changes to take effect${NC}"
