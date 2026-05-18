#!/bin/bash
#
# sync.sh — Declarative hook sync across coding-agent harnesses (Claude, Codex).
#
# Reads agents/hooks/registry.yaml and brings each harness's config in line:
# upserts the SessionStart entry into claude/settings.json (in-repo) for
# Claude, and into ~/.codex/config.toml for Codex. Idempotent — re-runs
# with no registry changes make no file edits. Preserves every other
# top-level config key.
#
# Backends:
#   claude — jq-edits $REPO/claude/settings.json under .hooks.SessionStart[]
#   codex  — yq-edits $HOME/.codex/config.toml under [[hooks.SessionStart]]
#
# Usage:
#   ./sync.sh                Sync hooks (idempotent upsert per entry)
#   ./sync.sh --dry-run      Show what would change without making changes
#   ./sync.sh --harness NAME Only sync the named harness (claude|codex)
#
# Exit status is non-zero if any upsert failed, so chezmoi / dots sync can
# surface partial-failure cases instead of reporting green.
#
# No interactive prompts — upserts are purely additive and idempotent, so
# there is no removal flow that would need a --force escape hatch.
#
# sync-common.sh globals (DRY_RUN, …) are written here and shared with the
# helpers in lib.sh; shellcheck can't see cross-file refs.
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
REGISTRY_FILE="$SCRIPT_DIR/registry.yaml"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../claude/lib/sync-common.sh
source "$SCRIPT_DIR/../../claude/lib/sync-common.sh"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

CLAUDE_SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$DOTFILES_DIR/claude/settings.json}"
CODEX_CONFIG_FILE="${CODEX_CONFIG_FILE:-$HOME/.codex/config.toml}"

ONLY_HARNESS=""
ADD_FAILURES=0

while (($#)); do
    case $1 in
        --dry-run) DRY_RUN=true ;;
        --harness=*) ONLY_HARNESS="${1#*=}" ;;
        --harness)   shift; ONLY_HARNESS="${1:-}" ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--dry-run] [--harness NAME]
  --dry-run         Show what would change without making changes
  --harness NAME    Only sync the named harness (claude|codex)
EOF
            exit 0 ;;
    esac
    shift
done

for cmd in yq jq; do
    command -v "$cmd" &>/dev/null \
        || { echo -e "${RED}Error: $cmd not found${NC}" >&2; exit 1; }
done

[[ -f "$REGISTRY_FILE" ]] \
    || { echo -e "${RED}Error: $REGISTRY_FILE not found${NC}" >&2; exit 1; }

REGISTRY_JSON=$(yq -o=json '.hooks' "$REGISTRY_FILE")

echo -e "${BLUE}Hook Sync - Declarative Hook Management${NC}"

if [[ -n "$ONLY_HARNESS" ]]; then
    hook_sync_harness "$ONLY_HARNESS"
else
    for h in claude codex; do
        hook_sync_harness "$h"
    done
fi

echo
if (( ADD_FAILURES > 0 )); then
    echo -e "${RED}Sync finished with $ADD_FAILURES upsert failure(s).${NC}" >&2
    exit 1
fi
echo -e "${GREEN}Sync complete!${NC}"
