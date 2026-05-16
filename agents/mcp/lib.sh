#!/bin/bash
# lib.sh — MCP-specific helpers for agents/mcp/sync.sh.
#
# Sourced by sync.sh and by bats tests. Functions take their inputs as args
# or read declared globals (HARNESS_DESIRED_JSON, REGISTRY_JSON, DRY_RUN,
# FORCE) populated by sync.sh; no hidden environment beyond that.
#
# shellcheck disable=SC2034,SC2329
#   SC2034: exports consumed by sync-common.sh
#   SC2329: get_description is called indirectly by sync-common.sh

set -euo pipefail

# ─── .env loader ────────────────────────────────────────────────────────
# Skips blanks, comments, malformed lines; strips surrounding quotes from
# values; refuses to export keys that are not legal bash identifiers.

mcp_load_dotenv() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local key val
    while IFS='=' read -r key val; do
        key="${key#export }"
        key="${key#"${key%%[![:space:]]*}"}"   # ltrim
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
        val="${val#\"}"; val="${val%\"}"
        val="${val#\'}"; val="${val%\'}"
        export "$key=$val"
    done < "$file"
}

# ─── registry filtering ─────────────────────────────────────────────────

mcp_filter_for_harness() {
    local harness="$1" json="$2"
    if [[ "$harness" == "claude" ]]; then
        # shellcheck disable=SC2016
        jq <<<"$json" '
            to_entries
            | map(select(((.value.harnesses // ["claude","codex"]) | index("claude")) != null))
            | map(select((.value.gate_unless // "") as $g | $g == "" or (env[$g] // "false") != "true"))
            | from_entries'
    else
        jq --arg h "$harness" <<<"$json" '
            to_entries
            | map(select(((.value.harnesses // ["claude","codex"]) | index($h)) != null))
            | from_entries'
    fi
}

# ─── current-state primitives ───────────────────────────────────────────

mcp_claude_list_current() {
    claude mcp list 2>/dev/null | awk '
        /^[a-zA-Z0-9_-]+:[[:space:]]+[^[:space:]]/ {
            n=$1; sub(/:$/,"",n)
            if (n !~ /^plugin/) print n
        }' | sort -u
}

mcp_codex_list_current() {
    codex mcp list --json 2>/dev/null | jq -r '
        if type == "array" then .[].name
        elif type == "object" and has("servers") then .servers[].name
        elif type == "object" then keys[]
        else empty end' 2>/dev/null | sort -u
}

# Pin the grep to the Scope field so an MCP whose args contain `--user-agent`
# (or similar) cannot falsely scope as "user".
mcp_claude_get_scope() {
    local scope
    scope=$(claude mcp get "$1" 2>/dev/null \
        | sed -n 's/^[[:space:]]*Scope:[[:space:]]*//p' \
        | head -1 | tr '[:upper:]' '[:lower:]')
    case "$scope" in user|project|local) echo "$scope" ;; *) echo "local" ;; esac
}

mcp_claude_remove() { claude mcp remove "$1" -s "$2"; }
mcp_codex_remove()  { codex  mcp remove "$1"; }

# ─── drift signatures ───────────────────────────────────────────────────
# Returns "<cmd>\t<args>\t<sorted-env>" for a stable equality check.
# `env` is resolved (${VAR} → live value) on both sides so credential
# rotations or env-block changes get detected — not just command/args drift.

mcp_resolve_env_value() {
    local val="$1"
    if [[ "$val" =~ ^\$\{([^}]+)\}$ ]]; then
        local var="${BASH_REMATCH[1]}"
        echo "${!var:-}"
    else
        echo "$val"
    fi
}

mcp_resolved_env_csv() {
    local kv k v out=""
    while IFS= read -r kv; do
        [[ -z "$kv" ]] && continue
        k="${kv%%=*}"; v="${kv#*=}"
        v=$(mcp_resolve_env_value "$v")
        out+="${out:+,}${k}=${v}"
    done < <(jq -r 'to_entries | sort_by(.key)[] | "\(.key)=\(.value)"' <<<"$1")
    echo "$out"
}

mcp_desired_signature() {
    local name="$1" cmd args env_json env_csv
    cmd=$(jq      -r --arg n "$name" '.[$n].command // ""'        <<<"$HARNESS_DESIRED_JSON")
    args=$(jq     -r --arg n "$name" '.[$n].args // [] | join(" ")' <<<"$HARNESS_DESIRED_JSON")
    env_json=$(jq -c --arg n "$name" '.[$n].env // {}'              <<<"$HARNESS_DESIRED_JSON")
    env_csv=$(mcp_resolved_env_csv "$env_json")
    printf '%s\t%s\t%s\n' "$cmd" "$args" "$env_csv"
}

mcp_claude_current_signature() {
    local info cmd args env_block env_csv=""
    info=$(claude mcp get "$1" 2>/dev/null || true)
    cmd=$( sed -n 's/^[[:space:]]*Command:[[:space:]]*//p' <<<"$info" | head -1)
    args=$(sed -n 's/^[[:space:]]*Args:[[:space:]]*//p'    <<<"$info" | head -1)
    # `claude mcp get` prints env as `KEY=VALUE` lines under `Environment:`.
    env_block=$(awk '
        /^[[:space:]]*Environment:/ { capture=1; next }
        capture && /^[[:space:]]*[A-Z_][A-Za-z0-9_]*=/ { sub(/^[[:space:]]+/, ""); print; next }
        capture { capture=0 }
    ' <<<"$info" | sort)
    [[ -n "$env_block" ]] && env_csv=$(paste -sd',' - <<<"$env_block")
    printf '%s\t%s\t%s\n' "$cmd" "$args" "$env_csv"
}

mcp_codex_current_signature() {
    local entry
    entry=$(codex mcp list --json 2>/dev/null | jq --arg n "$1" '
        if type == "array" then (.[] | select(.name == $n))
        elif type == "object" and has("servers") then (.servers[] | select(.name == $n))
        elif type == "object" then (.[$n] // empty)
        else empty end' 2>/dev/null)
    [[ -z "$entry" || "$entry" == "null" ]] && { printf '\t\t\n'; return; }
    local cmd args env_json env_csv
    cmd=$(     jq -r '(.transport.command // .command // "")'             <<<"$entry")
    args=$(    jq -r '(.transport.args // .args // []) | join(" ")'        <<<"$entry")
    env_json=$(jq -c '(.transport.env  // .env  // {})'                    <<<"$entry")
    env_csv=$(mcp_resolved_env_csv "$env_json")
    printf '%s\t%s\t%s\n' "$cmd" "$args" "$env_csv"
}

# ─── add ────────────────────────────────────────────────────────────────
# `env_flags` is returned via a global because bash 3.2 (macOS default)
# lacks namerefs for arrays. The caller must `env_flags=()` first.

mcp_build_env_flags() {
    local name="$1" flag_prefix="$2"  # "-e" (claude) or "--env" (codex)
    env_flags=()
    local env_json key val var
    env_json=$(jq -c --arg n "$name" '.[$n].env // {}' <<<"$HARNESS_DESIRED_JSON")
    [[ "$env_json" == "{}" ]] && return 0
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
    done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$env_json")
}

mcp_claude_add() {
    local name="$1" scope command
    scope=$(  jq -r --arg n "$name" '.[$n].scope // "user"' <<<"$HARNESS_DESIRED_JSON")
    command=$(jq -r --arg n "$name" '.[$n].command'         <<<"$HARNESS_DESIRED_JSON")

    local args_array=()
    while IFS= read -r arg; do args_array+=("$arg"); done < \
        <(jq -r --arg n "$name" '.[$n].args // [] | .[]' <<<"$HARNESS_DESIRED_JSON")

    local env_flags=()
    mcp_build_env_flags "$name" "-e" || return 1

    claude mcp add ${env_flags[@]+"${env_flags[@]}"} -s "$scope" "$name" -- \
        "$command" ${args_array[@]+"${args_array[@]}"} >/dev/null
}

mcp_codex_add() {
    local name="$1" command
    command=$(jq -r --arg n "$name" '.[$n].command' <<<"$HARNESS_DESIRED_JSON")

    local args_array=()
    while IFS= read -r arg; do args_array+=("$arg"); done < \
        <(jq -r --arg n "$name" '.[$n].args // [] | .[]' <<<"$HARNESS_DESIRED_JSON")

    local env_flags=()
    mcp_build_env_flags "$name" "--env" || return 1

    codex mcp add ${env_flags[@]+"${env_flags[@]}"} "$name" -- \
        "$command" ${args_array[@]+"${args_array[@]}"} >/dev/null
}

# ─── drift detection ────────────────────────────────────────────────────
# Reads EXISTING (set by sync_compute_diff). Emits drifted names, one per
# line; empty output means no drift.

mcp_detect_drift() {
    local harness="$1"
    [[ -z "${EXISTING:-}" ]] && return 0
    local name desired current
    while read -r name; do
        [[ -z "$name" ]] && continue
        desired=$(mcp_desired_signature "$name")
        case "$harness" in
            claude) current=$(mcp_claude_current_signature "$name") ;;
            codex)  current=$(mcp_codex_current_signature  "$name") ;;
        esac
        [[ "$desired" != "$current" ]] && echo "$name"
    done <<<"$EXISTING"
}

# ─── per-harness orchestration ──────────────────────────────────────────
# Returns the count of failed adds via the global ADD_FAILURES so the
# parent exit code can reflect partial failures.

mcp_sync_harness() {
    local harness="$1"

    case "$harness" in
        claude) command -v claude &>/dev/null || { echo -e "${YELLOW}Skipping claude (CLI not found)${NC}"; return 0; } ;;
        codex)  command -v codex  &>/dev/null || { echo -e "${YELLOW}Skipping codex  (CLI not found)${NC}"; return 0; } ;;
        *) echo -e "${RED}Unknown harness: $harness${NC}" >&2; return 1 ;;
    esac

    echo
    echo -e "${BLUE}━━━ ${harness} ━━━${NC}"

    HARNESS_DESIRED_JSON=$(mcp_filter_for_harness "$harness" "$REGISTRY_JSON")
    DESIRED_NAMES=$(jq -r 'keys[]' <<<"$HARNESS_DESIRED_JSON" | sort)

    case "$harness" in
        claude) CURRENT_NAMES=$(mcp_claude_list_current) ;;
        codex)  CURRENT_NAMES=$(mcp_codex_list_current) ;;
    esac

    get_description() { jq -r --arg n "$1" '.[$n].description // ""' <<<"$HARNESS_DESIRED_JSON"; }
    if [[ "$harness" == "claude" ]]; then
        get_item_scope() { mcp_claude_get_scope "$1"; }
        remove_item()   { mcp_claude_remove "$1" "$2"; }
    else
        get_item_scope() { echo "user"; }
        remove_item()   { mcp_codex_remove "$1"; }
    fi

    sync_compute_diff

    local to_update; to_update=$(mcp_detect_drift "$harness")
    _mcp_inject_drift_into_adds "$to_update"

    sync_show_plan "$harness MCPs" || { [[ -z "$to_update" ]] && return 0; }

    _mcp_apply_updates "$harness" "$to_update"
    _mcp_apply_adds    "$harness"

    sync_handle_removals "$harness MCPs"
}

# Folds drifted-entry names into TO_ADD (they get removed first, then
# re-added). Also displays the "Config changed" block.
_mcp_inject_drift_into_adds() {
    local to_update="$1"
    [[ -z "$to_update" ]] && return 0
    TO_ADD="${TO_ADD:+$TO_ADD$'\n'}$to_update"
    add_count=$(_count_nonempty "$TO_ADD")
    local update_count; update_count=$(_count_nonempty "$to_update")
    echo -e "${YELLOW}Config changed ($update_count):${NC}"
    while read -r name; do
        [[ -z "$name" ]] && continue
        echo "  ~ $name: command/args/env changed"
    done <<<"$to_update"
    echo
}

_mcp_apply_updates() {
    local harness="$1" to_update="$2"
    [[ -z "$to_update" ]] && return 0
    echo -e "${YELLOW}Updating changed MCPs...${NC}"
    while read -r name; do
        [[ -z "$name" ]] && continue
        local scope; scope=$(get_item_scope "$name")
        if $DRY_RUN; then
            echo -e "  ${BLUE}[dry-run]${NC} Would remove $name (config changed)"
        else
            echo -n "  Removing old $name... "
            remove_item "$name" "$scope" && echo -e "${GREEN}done${NC}" || echo -e "${RED}failed${NC}"
        fi
    done <<<"$to_update"
    echo
}

_mcp_apply_adds() {
    local harness="$1"
    [[ -z "$TO_ADD" ]] && return 0
    echo -e "${GREEN}Adding MCPs...${NC}"
    while read -r name; do
        [[ -z "$name" ]] && continue
        if $DRY_RUN; then
            local cmd args
            cmd=$( jq -r --arg n "$name" '.[$n].command // ""'              <<<"$HARNESS_DESIRED_JSON")
            args=$(jq -r --arg n "$name" '.[$n].args // [] | join(" ")'     <<<"$HARNESS_DESIRED_JSON")
            echo -e "  ${BLUE}[dry-run]${NC} Would add $name → $cmd $args"
            continue
        fi
        echo -n "  Adding $name... "
        local err rc=0
        case "$harness" in
            claude) err=$(mcp_claude_add "$name" 2>&1) || rc=$? ;;
            codex)  err=$(mcp_codex_add  "$name" 2>&1) || rc=$? ;;
        esac
        if (( rc == 0 )); then
            echo -e "${GREEN}done${NC}"
        else
            echo -e "${RED}failed${NC}"
            [[ -n "$err" ]] && echo -e "    ${RED}$err${NC}"
            ADD_FAILURES=$((ADD_FAILURES + 1))
        fi
    done <<<"$TO_ADD"
    echo
}
