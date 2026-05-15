#!/bin/bash
#
# sync.sh — Declarative MCP sync across coding-agent harnesses (Claude, Codex)
#
# Reads agents/mcp/registry.yaml and brings each installed harness in line:
# adds missing servers, updates drifted command/args, prompts (or with --force,
# removes) any servers present in the harness but absent from the registry.
#
# Per-harness CLIs:
#   claude — `claude mcp add/list/remove/get` (text output; scope-aware)
#   codex  — `codex mcp add/list/remove`     (JSON output via --json; no scopes)
#
# Skips a harness silently if its CLI is not installed.
#
# Usage:
#   ./sync.sh                Sync MCPs (add missing, prompt to remove extras)
#   ./sync.sh --dry-run      Show what would change without making changes
#   ./sync.sh --force        Remove extras without prompting (used by dots sync)
#   ./sync.sh --harness NAME Only sync the named harness (claude|codex)
#
# FORCE, CURRENT_NAMES, DESIRED_NAMES, TO_ADD, TO_REMOVE, EXISTING, add_count
# are written here and read by sync-common.sh — shellcheck can't see cross-file
# globals.
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
REGISTRY_FILE="$SCRIPT_DIR/registry.yaml"

# shellcheck source=../../claude/lib/sync-common.sh
source "$SCRIPT_DIR/../../claude/lib/sync-common.sh"

ONLY_HARNESS=""

# Custom arg parse — sync_parse_args doesn't know about --harness
while (($#)); do
    case $1 in
        --dry-run) DRY_RUN=true ;;
        --force) FORCE=true ;;
        --harness=*) ONLY_HARNESS="${1#*=}" ;;
        --harness) shift; ONLY_HARNESS="${1:-}" ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--dry-run] [--force] [--harness NAME]
  --dry-run         Show what would change without making changes
  --force           Remove extras without prompting
  --harness NAME    Only sync the named harness (claude|codex)
EOF
            exit 0 ;;
    esac
    shift
done

# Source .env for secrets (same loader as zsh/core.zsh)
DOTFILES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [[ -f "$DOTFILES_DIR/.env" ]]; then
    while IFS='=' read -r key val; do
        key="${key#export }"
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        export "$key=$val"
    done < "$DOTFILES_DIR/.env"
fi

# yq + jq are required; per-harness CLIs are checked per iteration
for cmd in yq jq; do
    command -v "$cmd" &>/dev/null || { echo -e "${RED}Error: $cmd not found${NC}" >&2; exit 1; }
done

[[ -f "$REGISTRY_FILE" ]] || { echo -e "${RED}Error: $REGISTRY_FILE not found${NC}" >&2; exit 1; }

REGISTRY_JSON=$(yq -o=json '.mcps' "$REGISTRY_FILE")

# ─────────────── harness filtering ───────────────

# Filter the full registry to entries that should install on this harness.
# Default `harnesses: [claude, codex]` if absent. `gate_unless` is honored
# only for claude (codex has no plugin system to defer to).
filter_for_harness() {
    local harness="$1"
    local default_harnesses='["claude","codex"]'
    if [[ "$harness" == "claude" ]]; then
        # shellcheck disable=SC2016
        echo "$REGISTRY_JSON" | jq --argjson def "$default_harnesses" '
            to_entries
            | map(select(((.value.harnesses // $def) | index("claude")) != null))
            | map(select((.value.gate_unless // "") as $g | $g == "" or (env[$g] // "false") != "true"))
            | from_entries
        '
    else
        echo "$REGISTRY_JSON" | jq --argjson def "$default_harnesses" --arg h "$harness" '
            to_entries
            | map(select(((.value.harnesses // $def) | index($h)) != null))
            | from_entries
        '
    fi
}

# ─────────────── per-harness primitives ───────────────

claude_list_current() {
    local out=()
    while IFS= read -r line; do
        # name: <command> ... — exclude health-check banner and plugin: rows
        [[ "$line" =~ ^([a-zA-Z0-9_-]+):[[:space:]]+[^[:space:]] ]] || continue
        local name="${BASH_REMATCH[1]}"
        [[ "$name" == plugin* ]] && continue
        out+=("$name")
    done < <(claude mcp list 2>/dev/null)
    if (( ${#out[@]} )); then
        printf '%s\n' "${out[@]}" | sort -u
    fi
}

codex_list_current() {
    codex mcp list --json 2>/dev/null | jq -r '
        if type == "array" then .[].name
        elif type == "object" and has("servers") then .servers[].name
        elif type == "object" then keys[]
        else empty end
    ' 2>/dev/null | sort -u
}

claude_get_scope() {
    local info; info=$(claude mcp get "$1" 2>/dev/null || true)
    if echo "$info" | grep -qi "user"; then echo "user"
    elif echo "$info" | grep -qi "project"; then echo "project"
    else echo "local"; fi
}

claude_remove() { claude mcp remove "$1" -s "$2" 2>/dev/null; }
codex_remove()  { codex  mcp remove "$1"     2>/dev/null; }

# Returns "<command>\t<args-joined-by-space>" for drift comparison
claude_current_cmd_args() {
    local info; info=$(claude mcp get "$1" 2>/dev/null || true)
    local cmd args
    cmd=$(echo "$info" | grep '^ *Command:' | sed 's/^ *Command: *//')
    args=$(echo "$info" | grep '^ *Args:' | sed 's/^ *Args: *//')
    printf '%s\t%s\n' "$cmd" "$args"
}

codex_current_cmd_args() {
    # `codex mcp list --json` nests command/args under .transport for stdio servers.
    local entry
    entry=$(codex mcp list --json 2>/dev/null | jq --arg n "$1" '
        if type == "array" then (.[] | select(.name == $n))
        elif type == "object" and has("servers") then (.servers[] | select(.name == $n))
        elif type == "object" then (.[$n] // empty)
        else empty end
    ' 2>/dev/null)
    [[ -z "$entry" || "$entry" == "null" ]] && { printf '\t\n'; return; }
    local cmd args
    cmd=$(echo "$entry" | jq -r '(.transport.command // .command // "")')
    args=$(echo "$entry" | jq -r '(.transport.args // .args // []) | join(" ")')
    printf '%s\t%s\n' "$cmd" "$args"
}

# Build the env-flag array for the current entry. Caller must declare
# `env_flags=()` first. Sets it via nameref-free pattern using a temp file
# would be cleaner; for now we abuse globals.
build_env_flags() {
    local name="$1" flag_prefix="$2"  # flag_prefix is "-e" (claude) or "--env" (codex)
    env_flags=()
    local env_json; env_json=$(echo "$HARNESS_DESIRED_JSON" | jq -c --arg n "$name" '.[$n].env // {}')
    [[ "$env_json" == "{}" ]] && return 0
    local key val var
    while IFS='=' read -r key val; do
        if [[ "$val" =~ ^\$\{([^}]+)\}$ ]]; then
            var="${BASH_REMATCH[1]}"
            if [[ -z "${!var:-}" ]]; then
                echo -e "${RED}    Skipping: $key references unset env var \$$var${NC}" >&2
                return 1
            fi
            val="${!var}"
        fi
        env_flags+=("$flag_prefix" "${key}=${val}")
    done < <(echo "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
}

claude_add() {
    local name="$1"
    local scope command
    scope=$(echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$name" '.[$n].scope // "user"')
    command=$(echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$name" '.[$n].command')

    local args_array=()
    while IFS= read -r arg; do args_array+=("$arg"); done < <(echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$name" '.[$n].args // [] | .[]')

    local env_flags=()
    build_env_flags "$name" "-e" || return 1

    claude mcp add ${env_flags[@]+"${env_flags[@]}"} -s "$scope" "$name" -- "$command" ${args_array[@]+"${args_array[@]}"} >/dev/null
}

codex_add() {
    local name="$1"
    local command
    command=$(echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$name" '.[$n].command')

    local args_array=()
    while IFS= read -r arg; do args_array+=("$arg"); done < <(echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$name" '.[$n].args // [] | .[]')

    local env_flags=()
    build_env_flags "$name" "--env" || return 1

    codex mcp add ${env_flags[@]+"${env_flags[@]}"} "$name" -- "$command" ${args_array[@]+"${args_array[@]}"} >/dev/null
}

# ─────────────── per-harness orchestration ───────────────

sync_for_harness() {
    local harness="$1"

    case "$harness" in
        claude) command -v claude &>/dev/null || { echo -e "${YELLOW}Skipping claude (CLI not found)${NC}"; return 0; } ;;
        codex)  command -v codex  &>/dev/null || { echo -e "${YELLOW}Skipping codex  (CLI not found)${NC}"; return 0; } ;;
        *) echo -e "${RED}Unknown harness: $harness${NC}" >&2; return 1 ;;
    esac

    echo
    echo -e "${BLUE}━━━ ${harness} ━━━${NC}"

    HARNESS_DESIRED_JSON=$(filter_for_harness "$harness")
    # shellcheck disable=SC2034  # consumed by sync-common.sh
    DESIRED_NAMES=$(echo "$HARNESS_DESIRED_JSON" | jq -r 'keys[]' | sort)

    case "$harness" in
        claude) CURRENT_NAMES=$(claude_list_current) ;;
        codex)  CURRENT_NAMES=$(codex_list_current) ;;
    esac

    get_description() { echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$1" '.[$n].description // ""'; }
    case "$harness" in
        claude)
            get_item_scope() { claude_get_scope "$1"; }
            remove_item() { claude_remove "$1" "$2"; }
            ;;
        codex)
            get_item_scope() { echo "user"; }
            remove_item() { codex_remove "$1"; }
            ;;
    esac

    sync_compute_diff

    # Drift: existing entries whose live command/args don't match the registry
    local to_update=""
    if [[ -n "$EXISTING" ]]; then
        while read -r name; do
            [[ -z "$name" ]] && continue
            local pair desired_cmd desired_args current_cmd current_args
            case "$harness" in
                claude) pair=$(claude_current_cmd_args "$name") ;;
                codex)  pair=$(codex_current_cmd_args  "$name") ;;
            esac
            current_cmd="${pair%%$'\t'*}"
            current_args="${pair#*$'\t'}"
            desired_cmd=$(echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$name" '.[$n].command // ""')
            desired_args=$(echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$name" '.[$n].args // [] | join(" ")')
            if [[ "$current_cmd" != "$desired_cmd" || "$current_args" != "$desired_args" ]]; then
                to_update="${to_update:+$to_update
}$name"
            fi
        done <<< "$EXISTING"
    fi

    if [[ -n "$to_update" ]]; then
        TO_ADD="${TO_ADD:+$TO_ADD
}$to_update"
        # shellcheck disable=SC2034  # add_count is consumed by sync-common.sh's sync_show_plan
        add_count=$(echo "$TO_ADD" | grep -c . 2>/dev/null || echo 0)

        local update_count; update_count=$(echo "$to_update" | grep -c . 2>/dev/null || echo 0)
        echo -e "${YELLOW}Config changed ($update_count):${NC}"
        echo "$to_update" | while read -r name; do
            [[ -z "$name" ]] && continue
            echo "  ~ $name: command/args changed"
        done
        echo
    fi

    sync_show_plan "$harness MCPs" || { [[ -z "$to_update" ]] && return 0; }

    if [[ -n "$to_update" ]]; then
        echo -e "${YELLOW}Updating changed MCPs...${NC}"
        echo "$to_update" | while read -r name; do
            [[ -z "$name" ]] && continue
            local scope; scope=$(get_item_scope "$name")
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
            if $DRY_RUN; then
                local cmd args
                cmd=$(echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$name" '.[$n].command // ""')
                args=$(echo "$HARNESS_DESIRED_JSON" | jq -r --arg n "$name" '.[$n].args // [] | join(" ")')
                echo -e "  ${BLUE}[dry-run]${NC} Would add $name → $cmd $args"
                continue
            fi
            echo -n "  Adding $name... "
            local err rc=0
            case "$harness" in
                claude) err=$(claude_add "$name" 2>&1) || rc=$? ;;
                codex)  err=$(codex_add  "$name" 2>&1) || rc=$? ;;
            esac
            if (( rc == 0 )); then
                echo -e "${GREEN}done${NC}"
            else
                echo -e "${RED}failed${NC}"
                [[ -n "$err" ]] && echo -e "    ${RED}$err${NC}"
            fi
        done
        echo
    fi

    sync_handle_removals "$harness MCPs"
}

# ─────────────── main ───────────────

echo -e "${BLUE}MCP Sync - Declarative MCP Management${NC}"

if [[ -n "$ONLY_HARNESS" ]]; then
    sync_for_harness "$ONLY_HARNESS"
else
    for h in claude codex; do
        sync_for_harness "$h"
    done
fi

echo
echo -e "${GREEN}Sync complete!${NC}"
