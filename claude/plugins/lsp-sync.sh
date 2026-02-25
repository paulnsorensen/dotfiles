#!/bin/bash
#
# lsp-sync.sh - Install LSP plugins and enable them in local settings only
#
# LSPs install language servers at startup, adding overhead unsuitable for
# headless or CI Claude sessions. This script enables them per-machine in
# ~/.claude/settings.local.json instead of the committed settings.json.
#
# Usage:
#   ./lsp-sync.sh             Install + enable all LSPs locally
#   ./lsp-sync.sh --dry-run   Preview changes
#   ./lsp-sync.sh --disable   Disable all LSPs locally (remove from settings.local.json)
#   ./lsp-sync.sh --list      Show current LSP status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_FILE="$SCRIPT_DIR/lsp-registry.yaml"
LOCAL_SETTINGS="$HOME/.claude/settings.local.json"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN=false
DISABLE=false
LIST_ONLY=false

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --disable) DISABLE=true ;;
        --list) LIST_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--disable] [--list]"
            echo "  --dry-run  Preview changes without applying"
            echo "  --disable  Remove LSP entries from local settings"
            echo "  --list     Show current LSP enable status"
            exit 0
            ;;
    esac
done

for cmd in yq jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error: $cmd not found. Install with: brew install $cmd${NC}"
        exit 1
    fi
done

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo -e "${RED}Error: LSP registry not found at $REGISTRY_FILE${NC}"
    exit 1
fi

# Get LSP names from registry
LSP_NAMES=$(yq '.lsps | keys | .[]' "$REGISTRY_FILE")

# Ensure settings.local.json exists
ensure_local_settings() {
    if [[ ! -f "$LOCAL_SETTINGS" ]]; then
        mkdir -p "$(dirname "$LOCAL_SETTINGS")"
        echo '{}' > "$LOCAL_SETTINGS"
    fi
}

# Get current enabled status from local settings
get_local_status() {
    local name="$1"
    if [[ -f "$LOCAL_SETTINGS" ]]; then
        jq -r --arg n "$name" '.enabledPlugins[$n] // "not set"' "$LOCAL_SETTINGS"
    else
        echo "not set"
    fi
}

# --- List mode ---
if $LIST_ONLY; then
    echo -e "${BLUE}LSP Plugin Status${NC}"
    echo
    echo "$LSP_NAMES" | while read -r name; do
        [[ -z "$name" ]] && continue
        local_status=$(get_local_status "$name")
        desc=$(yq ".lsps.\"$name\".description // \"\"" "$REGISTRY_FILE")
        if [[ "$local_status" == "true" ]]; then
            echo -e "  ${GREEN}[enabled]${NC}  $name - $desc"
        elif [[ "$local_status" == "false" ]]; then
            echo -e "  ${RED}[disabled]${NC} $name - $desc"
        else
            echo -e "  ${YELLOW}[not set]${NC} $name - $desc"
        fi
    done
    exit 0
fi

# --- Disable mode ---
if $DISABLE; then
    echo -e "${YELLOW}Disabling LSP plugins in local settings...${NC}"
    echo

    if $DRY_RUN; then
        echo "$LSP_NAMES" | while read -r name; do
            [[ -z "$name" ]] && continue
            echo -e "  ${BLUE}[dry-run]${NC} Would remove $name from $LOCAL_SETTINGS"
        done
    else
        ensure_local_settings
        LSP_JSON=$(yq -o=json '.lsps | keys' "$REGISTRY_FILE")
        jq --argjson lsps "$LSP_JSON" \
            '.enabledPlugins = (.enabledPlugins // {} | to_entries | map(select(.key as $k | $lsps | index($k) | not)) | from_entries)' \
            "$LOCAL_SETTINGS" > "${LOCAL_SETTINGS}.tmp" \
            && mv "${LOCAL_SETTINGS}.tmp" "$LOCAL_SETTINGS"
        echo -e "${GREEN}LSP plugins removed from local settings${NC}"
    fi
    echo
    echo -e "${YELLOW}Restart Claude Code for changes to take effect${NC}"
    exit 0
fi

# --- Enable mode (default) ---
echo -e "${BLUE}LSP Sync - Local-only Language Server Management${NC}"
echo

lsp_count=$(echo "$LSP_NAMES" | grep -c . 2>/dev/null || echo 0)
echo "Registry: $lsp_count LSPs defined"
echo

# Install plugins if not already installed
echo -e "${GREEN}Ensuring LSP plugins are installed...${NC}"
echo "$LSP_NAMES" | while read -r name; do
    [[ -z "$name" ]] && continue
    if $DRY_RUN; then
        echo -e "  ${BLUE}[dry-run]${NC} Would ensure installed: $name"
    else
        echo -n "  $name... "
        if claude plugin install -s user "$name" 2>/dev/null; then
            echo -e "${GREEN}ok${NC}"
        else
            echo -e "${YELLOW}already installed or failed${NC}"
        fi
    fi
done
echo

# Enable in local settings
echo -e "${GREEN}Enabling in $LOCAL_SETTINGS...${NC}"

ENABLED_JSON=$(yq -o=json '.lsps | keys' "$REGISTRY_FILE" | jq '[.[] | {(.): true}] | add')

if $DRY_RUN; then
    echo -e "  ${BLUE}[dry-run]${NC} Would merge into enabledPlugins:"
    echo "$ENABLED_JSON" | jq .
else
    ensure_local_settings
    jq --argjson lsps "$ENABLED_JSON" \
        '.enabledPlugins = (.enabledPlugins // {}) + $lsps' \
        "$LOCAL_SETTINGS" > "${LOCAL_SETTINGS}.tmp" \
        && mv "${LOCAL_SETTINGS}.tmp" "$LOCAL_SETTINGS"
    echo -e "  ${GREEN}Updated enabledPlugins${NC}"
fi
echo

echo -e "${GREEN}Sync complete!${NC}"
echo
echo -e "${YELLOW}Restart Claude Code for changes to take effect${NC}"
