#!/bin/bash
#
# sync.sh - Declarative plugin sync using native claude plugin commands
#
# Usage:
#   ./sync.sh           Sync plugins (install missing, prompt to remove extras)
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
for cmd in claude yq; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Error: $cmd not found. Install with: brew install $cmd${NC}"
        exit 1
    fi
done

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo -e "${RED}Error: Registry file not found at $REGISTRY_FILE${NC}"
    exit 1
fi

echo -e "${BLUE}Plugin Sync - Declarative Plugin Management${NC}"
echo

# Get desired plugins from registry (keys are in format plugin@marketplace)
DESIRED_NAMES=$(yq '.plugins | keys | .[]' "$REGISTRY_FILE" | sort)

# Get current plugins from claude
# Output format: "  ❯ plugin@marketplace" followed by metadata lines
CURRENT_OUTPUT=$(claude plugin list 2>/dev/null || true)
if echo "$CURRENT_OUTPUT" | grep -q "No plugins installed"; then
    CURRENT_NAMES=""
else
    # Parse lines containing @ and extract plugin name (handle ❯ bullet character)
    CURRENT_NAMES=$(echo "$CURRENT_OUTPUT" | grep '@' | sed 's/^[[:space:]]*❯[[:space:]]*//' | cut -d' ' -f1 | sort)
fi

# Find differences
DESIRED_FILE=$(mktemp)
CURRENT_FILE=$(mktemp)
echo "$DESIRED_NAMES" | grep -v '^$' > "$DESIRED_FILE" 2>/dev/null || true
echo "$CURRENT_NAMES" | grep -v '^$' > "$CURRENT_FILE" 2>/dev/null || true

TO_ADD=$(comm -23 "$DESIRED_FILE" "$CURRENT_FILE" 2>/dev/null || cat "$DESIRED_FILE")
TO_REMOVE=$(comm -13 "$DESIRED_FILE" "$CURRENT_FILE" 2>/dev/null || true)
EXISTING=$(comm -12 "$DESIRED_FILE" "$CURRENT_FILE" 2>/dev/null || true)

rm -f "$DESIRED_FILE" "$CURRENT_FILE"

# Count items (handle empty strings)
desired_count=0
current_count=0
add_count=0
remove_count=0

[[ -n "$DESIRED_NAMES" ]] && desired_count=$(echo "$DESIRED_NAMES" | grep -c . 2>/dev/null || echo 0)
[[ -n "$CURRENT_NAMES" ]] && current_count=$(echo "$CURRENT_NAMES" | grep -c . 2>/dev/null || echo 0)
[[ -n "$TO_ADD" ]] && add_count=$(echo "$TO_ADD" | grep -c . 2>/dev/null || echo 0)
[[ -n "$TO_REMOVE" ]] && remove_count=$(echo "$TO_REMOVE" | grep -c . 2>/dev/null || echo 0)

# Summary
echo "Registry: $desired_count plugins defined"
echo "Current:  $current_count plugins installed"
echo

if [[ -z "$TO_ADD" && -z "$TO_REMOVE" ]]; then
    echo -e "${GREEN}Everything in sync!${NC}"
    exit 0
fi

# Helper to get plugin attribute from registry
get_plugin_attr() {
    local plugin="$1"
    local attr="$2"
    local default="$3"
    local value
    value=$(yq ".plugins.\"$plugin\".$attr // \"$default\"" "$REGISTRY_FILE")
    echo "$value"
}

# Show plan
if [[ -n "$TO_ADD" ]]; then
    echo -e "${GREEN}To install ($add_count):${NC}"
    echo "$TO_ADD" | while read -r name; do
        [[ -z "$name" ]] && continue
        desc=$(get_plugin_attr "$name" "description" "")
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
    existing_count=$(echo "$EXISTING" | grep -c . 2>/dev/null || echo 0)
    echo -e "${BLUE}Already installed ($existing_count):${NC}"
    echo "$EXISTING" | while read -r name; do
        [[ -z "$name" ]] && continue
        echo "  = $name"
    done
    echo
fi

# Execute installations
if [[ -n "$TO_ADD" ]]; then
    echo -e "${GREEN}Installing missing plugins...${NC}"
    echo "$TO_ADD" | while read -r name; do
        [[ -z "$name" ]] && continue

        scope=$(get_plugin_attr "$name" "scope" "user")

        if $DRY_RUN; then
            echo -e "  ${BLUE}[dry-run]${NC} Would run: claude plugin install -s $scope $name"
        else
            echo -n "  Installing $name... "
            local err; err=$(claude plugin install -s "$scope" "$name" 2>&1 >/dev/null)
            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}done${NC}"
            else
                echo -e "${RED}failed${NC}"
                [[ -n "$err" ]] && echo -e "    ${RED}$err${NC}"
            fi
        fi
    done
    echo
fi

# Handle removals
if [[ -n "$TO_REMOVE" ]]; then
    echo -e "${YELLOW}Plugins not in registry:${NC}"
    echo "$TO_REMOVE" | while read -r name; do
        [[ -z "$name" ]] && continue

        # Default to user scope for removal
        scope="user"

        if $FORCE; then
            if $DRY_RUN; then
                echo -e "  ${BLUE}[dry-run]${NC} Would remove: $name"
            else
                echo -n "  Removing $name... "
                local err; err=$(claude plugin remove -s "$scope" "$name" 2>&1 >/dev/null)
                if [[ $? -eq 0 ]]; then
                    echo -e "${GREEN}done${NC}"
                else
                    echo -e "${RED}failed${NC}"
                    [[ -n "$err" ]] && echo -e "    ${RED}$err${NC}"
                fi
            fi
        elif $DRY_RUN; then
            echo -e "  ${BLUE}[dry-run]${NC} Would prompt to remove: $name"
        else
            echo -n "  Remove '$name'? [y/N] "
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                echo -n "  Removing $name... "
                local err; err=$(claude plugin remove -s "$scope" "$name" 2>&1 >/dev/null)
                if [[ $? -eq 0 ]]; then
                    echo -e "${GREEN}done${NC}"
                else
                    echo -e "${RED}failed${NC}"
                    [[ -n "$err" ]] && echo -e "    ${RED}$err${NC}"
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
echo -e "${BLUE}Run 'claude plugin list' to verify${NC}"
echo -e "${YELLOW}Restart Claude Code for changes to take effect${NC}"
