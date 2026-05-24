#!/bin/bash
#
# sync.sh — Declarative MCP sync across coding-agent harnesses
#           (Claude, Codex, opencode, Cursor).
#
# Reads agents/mcp/registry.yaml and brings each installed harness in line:
# adds missing servers, re-adds drifted ones (command/args/env), prompts (or
# with --force removes) any servers present in the harness but absent from
# the registry. Skips a harness silently if its CLI is not installed.
#
# Per-harness backends:
#   claude   — `claude mcp add/list/remove/get`     (text; scope-aware)
#   codex    — `codex mcp add/list/remove --json`   (JSON; no scopes)
#   opencode — jq-edits ~/.config/opencode/opencode.json directly
#              (no non-interactive CLI; OPENCODE_CONFIG overrides path)
#   cursor   — jq-edits ~/.cursor/mcp.json directly (mcpServers schema,
#              identical to Claude Desktop; CURSOR_CONFIG overrides path)
#
# Usage:
#   ./sync.sh                Sync MCPs (add missing, prompt to remove extras)
#   ./sync.sh --dry-run      Show what would change without making changes
#   ./sync.sh --force        Remove extras without prompting (used by dots sync)
#   ./sync.sh --harness NAME Only sync the named harness (claude|codex|opencode|cursor)
#
# Exit status is non-zero if any `add` call failed, so chezmoi / dots sync
# can surface partial-failure cases instead of reporting green.
#
# sync-common.sh globals (DRY_RUN, FORCE, TO_ADD, …) are written here and
# shared with the helpers in lib.sh; shellcheck can't see cross-file refs.
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
REGISTRY_FILE="$SCRIPT_DIR/registry.yaml"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../claude/lib/sync-common.sh
source "$SCRIPT_DIR/../../claude/lib/sync-common.sh"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

ONLY_HARNESS=""
ADD_FAILURES=0

while (($#)); do
    case $1 in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        --harness=*) ONLY_HARNESS="${1#*=}" ;;
        --harness)   shift; ONLY_HARNESS="${1:-}" ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--dry-run] [--force] [--harness NAME]
  --dry-run         Show what would change without making changes
  --force           Remove extras without prompting
  --harness NAME    Only sync the named harness (claude|codex|opencode|cursor)
EOF
            exit 0 ;;
    esac
    shift
done

mcp_load_dotenv "$DOTFILES_DIR/.env"

for cmd in yq jq chezmoi; do
    command -v "$cmd" &>/dev/null \
        || { echo -e "${RED}Error: $cmd not found${NC}" >&2; exit 1; }
done

[[ -f "$REGISTRY_FILE" ]] \
    || { echo -e "${RED}Error: $REGISTRY_FILE not found${NC}" >&2; exit 1; }

echo -e "${BLUE}MCP Sync - Declarative MCP Management${NC}"

# Render the registry once per harness so `args` strings can branch on
# `{{ env "HARNESS" }}`. mcp_sync_harness reads REGISTRY_JSON from its env.
sync_for_harness() {
    local h="$1"
    REGISTRY_JSON=$(HARNESS="$h" chezmoi execute-template < "$REGISTRY_FILE" | yq -o=json '.mcps')
    mcp_sync_harness "$h"
}

if [[ -n "$ONLY_HARNESS" ]]; then
    sync_for_harness "$ONLY_HARNESS"
else
    for h in claude codex opencode cursor; do
        sync_for_harness "$h"
    done
fi

echo
if (( ADD_FAILURES > 0 )); then
    echo -e "${RED}Sync finished with $ADD_FAILURES add failure(s).${NC}" >&2
    exit 1
fi
echo -e "${GREEN}Sync complete!${NC}"
