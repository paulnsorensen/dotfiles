#!/bin/bash
# sync-common.sh — Shared logic for declarative sync scripts (MCP + plugins)
# Source this file, then call sync_parse_args, sync_compute_diff, etc.

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
            --force)   FORCE=true ;;
            --help|-h)
                cat <<'USAGE'
Usage: $0 [--dry-run] [--force]
  --dry-run  Show what would change without making changes
  --force    Remove extras without prompting
USAGE
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

# Count non-empty lines in a string (idempotent on empty input).
_count_nonempty() {
    [[ -z "$1" ]] && { echo 0; return; }
    grep -c . <<<"$1" 2>/dev/null || echo 0
}

sync_compute_diff() {
    # Callers must pre-sort DESIRED_NAMES and CURRENT_NAMES so `comm` is
    # happy. Process substitution avoids the mktemp + rm dance.
    local desired current
    desired=$(grep -v '^$' <<<"$DESIRED_NAMES" || true)
    current=$(grep -v '^$' <<<"$CURRENT_NAMES" || true)

    TO_ADD=$(   comm -23 <(echo "$desired") <(echo "$current") 2>/dev/null || true)
    TO_REMOVE=$(comm -13 <(echo "$desired") <(echo "$current") 2>/dev/null || true)
    EXISTING=$( comm -12 <(echo "$desired") <(echo "$current") 2>/dev/null || true)

    desired_count=$(_count_nonempty "$DESIRED_NAMES")
    current_count=$(_count_nonempty "$CURRENT_NAMES")
    add_count=$(   _count_nonempty "$TO_ADD")
    remove_count=$(_count_nonempty "$TO_REMOVE")
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
        while read -r name; do
            [[ -z "$name" ]] && continue
            local desc; desc=$(get_description "$name")
            echo "  + $name: $desc"
        done <<<"$TO_ADD"
        echo
    fi

    if [[ -n "$TO_REMOVE" ]]; then
        echo -e "${YELLOW}Not in registry ($remove_count):${NC}"
        while read -r name; do
            [[ -z "$name" ]] && continue
            echo "  - $name"
        done <<<"$TO_REMOVE"
        echo
    fi

    if [[ -n "$EXISTING" ]]; then
        local existing_count; existing_count=$(_count_nonempty "$EXISTING")
        echo -e "${BLUE}Already configured ($existing_count):${NC}"
        while read -r name; do
            [[ -z "$name" ]] && continue
            echo "  = $name"
        done <<<"$EXISTING"
        echo
    fi

    return 0
}

# Caller must define get_item_scope(name) and remove_item(name, scope)
sync_handle_removals() {
    local label="$1"
    [[ -z "$TO_REMOVE" ]] && return 0

    echo -e "${YELLOW}${label} not in registry:${NC}"
    while read -r name; do
        [[ -z "$name" ]] && continue
        local scope; scope=$(get_item_scope "$name")

        if $FORCE; then
            _sync_remove_or_dryrun "$name" "$scope"
        elif $DRY_RUN; then
            echo -e "  ${BLUE}[dry-run]${NC} Would prompt to remove: $name ($scope)"
        else
            _sync_prompt_and_remove "$name" "$scope"
        fi
    done <<<"$TO_REMOVE"
    echo
}

# Internal: shared remove-or-dry-run print + exec.
_sync_remove_or_dryrun() {
    local name="$1" scope="$2"
    if $DRY_RUN; then
        echo -e "  ${BLUE}[dry-run]${NC} Would remove: $name ($scope)"
        return 0
    fi
    echo -n "  Removing $name... "
    if remove_item "$name" "$scope"; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed${NC}"
    fi
}

_sync_prompt_and_remove() {
    local name="$1" scope="$2" response
    if [[ ! -t 0 && ( ! -e /dev/tty || ! -w /dev/tty ) ]]; then
        echo "  Keeping $name (non-interactive)"
        return 0
    fi
    echo -n "  Remove '$name' ($scope)? [y/N] "
    read -r response </dev/tty || response=""
    if [[ "$response" =~ ^[Yy]$ ]]; then
        _sync_remove_or_dryrun "$name" "$scope"
    else
        echo "  Keeping $name"
    fi
}
