#!/bin/bash
#
# sync.sh - Declarative MCP sync using native claude mcp commands
#
# Usage:
#   ./sync.sh           Sync MCPs (add missing, prompt to remove extras)
#   ./sync.sh --dry-run Show what would change without making changes
#   ./sync.sh --force   Remove extras without prompting
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="$SCRIPT_DIR/registry.yaml"

# shellcheck source=../lib/sync-common.sh
source "$SCRIPT_DIR/../lib/sync-common.sh"

sync_parse_args "$@"
sync_check_deps

# Source .env for secrets (e.g. CONTEXT7_API_KEY) — same loader as zsh/core.zsh
DOTFILES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [[ -f "$DOTFILES_DIR/.env" ]]; then
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        export "$key=$val"
    done < "$DOTFILES_DIR/.env"
fi

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo -e "${RED}Error: Registry file not found at $REGISTRY_FILE${NC}" >&2
    exit 1
fi

echo -e "${BLUE}MCP Sync - Declarative MCP Management${NC}"
echo

DESIRED_JSON=$(yq -o=json '.mcps' "$REGISTRY_FILE")
# shellcheck disable=SC2034  # used by sync-common.sh
DESIRED_NAMES=$(echo "$DESIRED_JSON" | jq -r 'keys[]' | sort)

# Per-name lookup avoids `claude mcp list` which health-checks all servers (~6s)
CURRENT_NAMES_LIST=()
for name in $DESIRED_NAMES; do
    if claude mcp get "$name" &>/dev/null; then
        CURRENT_NAMES_LIST+=("$name")
    fi
done
# shellcheck disable=SC2034  # used by sync-common.sh
if (( ${#CURRENT_NAMES_LIST[@]} )); then
    CURRENT_NAMES=$(printf '%s\n' "${CURRENT_NAMES_LIST[@]}" | sort)
else
    CURRENT_NAMES=""
fi

get_description() { echo "$DESIRED_JSON" | jq -r --arg n "$1" '.[$n].description // ""'; }
get_item_scope() {
    local scope_info
    scope_info=$(claude mcp get "$1" 2>/dev/null || true)
    if echo "$scope_info" | grep -qi "user"; then echo "user"
    elif echo "$scope_info" | grep -qi "project"; then echo "project"
    else echo "local"
    fi
}
remove_item() { claude mcp remove "$1" -s "$2" 2>/dev/null; }

sync_compute_diff

# Config drift detection: compare desired command+args vs current for existing entries
TO_UPDATE=""
if [[ -n "$EXISTING" ]]; then
    while read -r name; do
        [[ -z "$name" ]] && continue
        current_info=$(claude mcp get "$name" 2>/dev/null || true)
        current_cmd=$(echo "$current_info" | grep '^ *Command:' | sed 's/^ *Command: *//')
        current_args=$(echo "$current_info" | grep '^ *Args:' | sed 's/^ *Args: *//')

        desired_cmd=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].command')
        desired_args=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].args // [] | join(" ")')

        if [[ "$current_cmd" != "$desired_cmd" ]] || [[ "$current_args" != "$desired_args" ]]; then
            TO_UPDATE="${TO_UPDATE:+$TO_UPDATE
}$name"
        fi
    done <<< "$EXISTING"
fi

# Move drifted entries into TO_ADD (they'll be removed first in the update step)
if [[ -n "$TO_UPDATE" ]]; then
    TO_ADD="${TO_ADD:+$TO_ADD
}$TO_UPDATE"
    # shellcheck disable=SC2034  # used by sync-common.sh
    add_count=$(echo "$TO_ADD" | grep -c . 2>/dev/null || echo 0)
fi

# Show update info alongside the standard plan
if [[ -n "$TO_UPDATE" ]]; then
    update_count=$(echo "$TO_UPDATE" | grep -c . 2>/dev/null || echo 0)
    echo -e "${YELLOW}Config changed ($update_count):${NC}"
    echo "$TO_UPDATE" | while read -r name; do
        [[ -z "$name" ]] && continue
        echo "  ~ $name: command/args changed"
    done
    echo
fi

sync_show_plan "MCPs" || { [[ -z "$TO_UPDATE" ]] && exit 0; }

# Remove drifted entries before re-adding with new config
if [[ -n "$TO_UPDATE" ]]; then
    echo -e "${YELLOW}Updating changed MCPs...${NC}"
    echo "$TO_UPDATE" | while read -r name; do
        [[ -z "$name" ]] && continue
        scope=$(get_item_scope "$name")
        if $DRY_RUN; then
            echo -e "  ${BLUE}[dry-run]${NC} Would remove $name (config changed)"
        else
            echo -n "  Removing old $name... "
            remove_item "$name" "$scope" && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
        fi
    done
    echo
fi

if [[ -n "$TO_ADD" ]]; then
    echo -e "${GREEN}Adding MCPs...${NC}"
    echo "$TO_ADD" | while read -r name; do
        [[ -z "$name" ]] && continue

        scope=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].scope // "user"')
        command=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].command')

        if $DRY_RUN; then
            args_preview=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].args // [] | join(" ")')
            env_preview=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].env // {} | to_entries[] | "-e \(.key)=\(.value)"' 2>/dev/null || true)
            echo -e "  ${BLUE}[dry-run]${NC} Would run: claude mcp add -s $scope $env_preview $name -- $command $args_preview"
        else
            echo -n "  Adding $name... "

            args_json=$(echo "$DESIRED_JSON" | jq -c --arg n "$name" '.[$n].args // []')
            args_array=()
            while IFS= read -r arg; do
                args_array+=("$arg")
            done < <(echo "$args_json" | jq -r '.[]')

            env_flags=()
            env_json=$(echo "$DESIRED_JSON" | jq -c --arg n "$name" '.[$n].env // {}')
            if [[ "$env_json" != "{}" ]]; then
                while IFS='=' read -r key val; do
                    if [[ "$val" =~ ^\$\{([^}]+)\}$ ]]; then
                        var_name="${BASH_REMATCH[1]}"
                        if [[ -z "${!var_name+x}" || -z "${!var_name}" ]]; then
                            echo -e "${RED}Error: $key references unset env var \$$var_name — skipping $name${NC}" >&2
                            continue 2
                        fi
                        expanded_val="${!var_name}"
                    else
                        expanded_val="$val"
                    fi
                    env_flags+=(-e "${key}=${expanded_val}")
                done < <(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
            fi

            # shellcheck disable=SC2154
            if err=$(claude mcp add ${env_flags[@]+"${env_flags[@]}"} -s "$scope" "$name" -- "$command" ${args_array[@]+"${args_array[@]}"} 2>&1 >/dev/null); then
                echo -e "${GREEN}done${NC}"
            else
                echo -e "${RED}failed${NC}"
                [[ -n "$err" ]] && echo -e "    ${RED}$err${NC}"
            fi
        fi
    done
    echo
fi

sync_handle_removals "MCPs"

echo -e "${GREEN}Sync complete!${NC}"
echo
echo -e "${BLUE}Run 'claude mcp list' to verify${NC}"
