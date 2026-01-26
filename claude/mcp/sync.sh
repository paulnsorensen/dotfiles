#!/bin/bash
#
# sync.sh - Declarative MCP sync using native claude mcp commands
#
# Usage:
#   ./sync.sh           Sync MCPs (add missing, prompt to remove extras)
#   ./sync.sh --dry-run Show what would change without making changes
#   ./sync.sh --force   Remove extras without prompting
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="$SCRIPT_DIR/registry.yaml"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
DRY_RUN=false
FORCE=false
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

# Check dependencies
for cmd in claude yq jq; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Error: $cmd not found. Install with: brew install $cmd${NC}"
        exit 1
    fi
done

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo -e "${RED}Error: Registry file not found at $REGISTRY_FILE${NC}"
    exit 1
fi

echo -e "${BLUE}MCP Sync - Declarative MCP Management${NC}"
echo

# Get desired MCPs from registry (as JSON for easier processing)
DESIRED_JSON=$(yq -o=json '.mcps' "$REGISTRY_FILE")
DESIRED_NAMES=$(echo "$DESIRED_JSON" | jq -r 'keys[]' | sort)

# Get current MCPs from claude
CURRENT_OUTPUT=$(claude mcp list 2>/dev/null || true)
CURRENT_NAMES=$(echo "$CURRENT_OUTPUT" | grep -E '^[a-zA-Z0-9_-]+:' | cut -d: -f1 | sort)

# Find differences using comm (works on all bash versions)
DESIRED_FILE=$(mktemp)
CURRENT_FILE=$(mktemp)
echo "$DESIRED_NAMES" | grep -v '^$' > "$DESIRED_FILE"
echo "$CURRENT_NAMES" | grep -v '^$' > "$CURRENT_FILE"

TO_ADD=$(comm -23 "$DESIRED_FILE" "$CURRENT_FILE")
TO_REMOVE=$(comm -13 "$DESIRED_FILE" "$CURRENT_FILE")
EXISTING=$(comm -12 "$DESIRED_FILE" "$CURRENT_FILE")

rm -f "$DESIRED_FILE" "$CURRENT_FILE"

# Count items
desired_count=$(echo "$DESIRED_NAMES" | grep -c . || echo 0)
current_count=$(echo "$CURRENT_NAMES" | grep -c . || echo 0)
add_count=$(echo "$TO_ADD" | grep -c . || echo 0)
remove_count=$(echo "$TO_REMOVE" | grep -c . || echo 0)

# Summary
echo "Registry: $desired_count MCPs defined"
echo "Current:  $current_count MCPs configured"
echo

if [[ -z "$TO_ADD" && -z "$TO_REMOVE" ]]; then
    echo -e "${GREEN}Everything in sync!${NC}"
    exit 0
fi

# Show plan
if [[ -n "$TO_ADD" ]]; then
    echo -e "${GREEN}To add ($add_count):${NC}"
    echo "$TO_ADD" | while read -r name; do
        [[ -z "$name" ]] && continue
        desc=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].description // ""')
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
    existing_count=$(echo "$EXISTING" | grep -c . || echo 0)
    echo -e "${BLUE}Already configured ($existing_count):${NC}"
    echo "$EXISTING" | while read -r name; do
        [[ -z "$name" ]] && continue
        echo "  = $name"
    done
    echo
fi

# Execute additions
if [[ -n "$TO_ADD" ]]; then
    echo -e "${GREEN}Adding missing MCPs...${NC}"
    echo "$TO_ADD" | while read -r name; do
        [[ -z "$name" ]] && continue

        scope=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].scope // "user"')
        command=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].command')

        if $DRY_RUN; then
            args_preview=$(echo "$DESIRED_JSON" | jq -r --arg n "$name" '.[$n].args // [] | join(" ")')
            echo -e "  ${BLUE}[dry-run]${NC} Would run: claude mcp add -s $scope $name -- $command $args_preview"
        else
            echo -n "  Adding $name... "

            # Build the command with proper argument handling
            args_json=$(echo "$DESIRED_JSON" | jq -c --arg n "$name" '.[$n].args // []')

            # Use eval to properly handle the args array
            eval "args_array=($(echo "$args_json" | jq -r '.[] | @sh'))"

            if claude mcp add -s "$scope" "$name" -- "$command" "${args_array[@]}" 2>/dev/null; then
                echo -e "${GREEN}done${NC}"
            else
                echo -e "${RED}failed${NC}"
            fi
        fi
    done
    echo
fi

# Handle removals
if [[ -n "$TO_REMOVE" ]]; then
    echo -e "${YELLOW}MCPs not in registry:${NC}"
    echo "$TO_REMOVE" | while read -r name; do
        [[ -z "$name" ]] && continue

        # Get scope from claude mcp get
        scope_info=$(claude mcp get "$name" 2>/dev/null || true)
        if echo "$scope_info" | grep -qi "user"; then
            scope="user"
        elif echo "$scope_info" | grep -qi "project"; then
            scope="project"
        else
            scope="local"
        fi

        if $FORCE; then
            if $DRY_RUN; then
                echo -e "  ${BLUE}[dry-run]${NC} Would remove: $name ($scope)"
            else
                echo -n "  Removing $name... "
                if claude mcp remove "$name" -s "$scope" 2>/dev/null; then
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
                if claude mcp remove "$name" -s "$scope" 2>/dev/null; then
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
fi

echo -e "${GREEN}Sync complete!${NC}"
echo
echo -e "${BLUE}Run 'claude mcp list' to verify${NC}"
