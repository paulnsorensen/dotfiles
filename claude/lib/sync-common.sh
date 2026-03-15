#!/bin/bash
# sync-common.sh — Shared logic for declarative sync scripts (MCP + plugins)
# Source this file, then call sync_init, sync_compute_diff, etc.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN=false
FORCE=false

sync_parse_args() {
    for arg in "$@"; do
        case $arg in
            --dry-run) DRY_RUN=true ;;
            --force) FORCE=true ;;
            --help|-h)
                echo "Usage: $0 [--dry-run] [--force]"
                echo "  --dry-run  Show what would change without making changes"
                echo "  --force    Remove extras without prompting"
                exit 0
                ;;
        esac
    done
}

sync_check_deps() {
    for cmd in claude yq jq; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}Error: $cmd not found. Install with: brew install $cmd${NC}" >&2
            exit 1
        fi
    done
}

sync_compute_diff() {
    local desired_file current_file
    desired_file=$(mktemp)
    current_file=$(mktemp)

    echo "$DESIRED_NAMES" | grep -v '^$' > "$desired_file" 2>/dev/null || true
    echo "$CURRENT_NAMES" | grep -v '^$' > "$current_file" 2>/dev/null || true

    TO_ADD=$(comm -23 "$desired_file" "$current_file" 2>/dev/null || cat "$desired_file")
    TO_REMOVE=$(comm -13 "$desired_file" "$current_file" 2>/dev/null || true)
    EXISTING=$(comm -12 "$desired_file" "$current_file" 2>/dev/null || true)

    rm -f "$desired_file" "$current_file"

    desired_count=0; current_count=0; add_count=0; remove_count=0
    if [[ -n "$DESIRED_NAMES" ]]; then desired_count=$(echo "$DESIRED_NAMES" | grep -c . 2>/dev/null || echo 0); fi
    if [[ -n "$CURRENT_NAMES" ]]; then current_count=$(echo "$CURRENT_NAMES" | grep -c . 2>/dev/null || echo 0); fi
    if [[ -n "$TO_ADD" ]]; then add_count=$(echo "$TO_ADD" | grep -c . 2>/dev/null || echo 0); fi
    if [[ -n "$TO_REMOVE" ]]; then remove_count=$(echo "$TO_REMOVE" | grep -c . 2>/dev/null || echo 0); fi
}

# Caller must define get_description(name)
sync_show_plan() {
    local label="$1"

    echo "Registry: $desired_count $label defined"
    echo "Current:  $current_count $label configured"
    echo

    if [[ -z "$TO_ADD" && -z "$TO_REMOVE" ]]; then
        echo -e "${GREEN}Everything in sync!${NC}"
        return 1  # signal: nothing to do
    fi

    if [[ -n "$TO_ADD" ]]; then
        echo -e "${GREEN}To add ($add_count):${NC}"
        echo "$TO_ADD" | while read -r name; do
            [[ -z "$name" ]] && continue
            local desc
            desc=$(get_description "$name")
            echo "  + $name: $desc"
        done
        echo
    fi

    if [[ -n "$TO_REMOVE" ]]; then
        echo -e "${YELLOW}Not in registry ($remove_count):${NC}"
        echo "$TO_REMOVE" | while read -r name; do
            [[ -z "$name" ]] && continue
            echo "  - $name"
        done
        echo
    fi

    if [[ -n "$EXISTING" ]]; then
        local existing_count
        existing_count=$(echo "$EXISTING" | grep -c . 2>/dev/null || echo 0)
        echo -e "${BLUE}Already configured ($existing_count):${NC}"
        echo "$EXISTING" | while read -r name; do
            [[ -z "$name" ]] && continue
            echo "  = $name"
        done
        echo
    fi

    return 0
}

# Caller must define get_item_scope(name) and remove_item(name, scope)
sync_handle_removals() {
    local label="$1"
    [[ -z "$TO_REMOVE" ]] && return 0

    echo -e "${YELLOW}${label} not in registry:${NC}"
    echo "$TO_REMOVE" | while read -r name; do
        [[ -z "$name" ]] && continue
        local scope
        scope=$(get_item_scope "$name")

        if $FORCE; then
            if $DRY_RUN; then
                echo -e "  ${BLUE}[dry-run]${NC} Would remove: $name ($scope)"
            else
                echo -n "  Removing $name... "
                if remove_item "$name" "$scope"; then
                    echo -e "${GREEN}done${NC}"
                else
                    echo -e "${RED}failed${NC}"
                fi
            fi
        elif $DRY_RUN; then
            echo -e "  ${BLUE}[dry-run]${NC} Would prompt to remove: $name ($scope)"
        else
            echo -n "  Remove '$name' ($scope)? [y/N] "
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                echo -n "  Removing $name... "
                if remove_item "$name" "$scope"; then
                    echo -e "${GREEN}done${NC}"
                else
                    echo -e "${RED}failed${NC}"
                fi
            else
                echo "  Keeping $name"
            fi
        fi
    done
    echo
}
