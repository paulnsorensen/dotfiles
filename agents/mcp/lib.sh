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
            | map(select(((.value.harnesses // ["claude","codex","opencode","cursor"]) | index("claude")) != null))
            | map(select((.value.gate_unless // "") as $g | $g == "" or (env[$g] // "false") != "true"))
            | from_entries'
    else
        jq --arg h "$harness" <<<"$json" '
            to_entries
            | map(select(((.value.harnesses // ["claude","codex","opencode","cursor"]) | index($h)) != null))
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
    # Capture codex's exit code explicitly: a non-zero exit (CLI bug, auth
    # failure, malformed config) must NOT be silently treated as "no current
    # MCPs" — that would trigger an `add` for every desired entry and
    # collide with the existing ones.
    local raw rc=0
    raw=$(codex mcp list --json 2>/dev/null) || rc=$?
    if (( rc != 0 )); then
        echo -e "${RED}    codex mcp list --json failed (exit $rc); aborting codex sync${NC}" >&2
        return "$rc"
    fi
    jq -r <<<"$raw" '
        if type == "array" then .[].name
        elif type == "object" and has("servers") then .servers[].name
        elif type == "object" then keys[]
        else empty end' 2>/dev/null | sort -u
}

# Pin the grep to the Scope field so an MCP whose args contain `--user-agent`
# (or similar) cannot falsely scope as "user". Single awk pass replaces the
# sed | head -1 | tr pipeline; `exit` after the first match takes the place
# of `head -1`, `tolower()` the place of `tr`.
mcp_claude_get_scope() {
    local scope
    scope=$(claude mcp get "$1" 2>/dev/null | awk '
        /^[[:space:]]*Scope:[[:space:]]*/ {
            sub(/^[[:space:]]*Scope:[[:space:]]*/, "")
            print tolower($0); exit
        }')
    case "$scope" in user|project|local) echo "$scope" ;; *) echo "local" ;; esac
}

mcp_claude_remove() { claude mcp remove "$1" -s "$2"; }
mcp_codex_remove()  { codex  mcp remove "$1"; }

# ─── opencode primitives ────────────────────────────────────────────────
# opencode has no non-interactive `mcp add`/`mcp remove`, so we jq-edit
# ~/.config/opencode/opencode.json in place. OPENCODE_CONFIG overrides the
# target path (tests).

mcp_opencode_config_path() {
    echo "${OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json}"
}

mcp_opencode_ensure_config() {
    local cfg; cfg=$(mcp_opencode_config_path)
    mkdir -p "${cfg%/*}"
    if [[ ! -s "$cfg" ]]; then
        # Mirror chezmoi's create_opencode.json scaffold so a sync-before-chezmoi
        # ordering doesn't leave formatter disabled. `create_` won't overwrite.
        # shellcheck disable=SC2016  # $schema is a literal JSON key, not a shell var
        echo '{"$schema": "https://opencode.ai/config.json", "formatter": true}' > "$cfg"
    fi
}

mcp_opencode_list_current() {
    local cfg; cfg=$(mcp_opencode_config_path)
    [[ -f "$cfg" ]] || return 0
    jq -r '.mcp // {} | keys[]' "$cfg" 2>/dev/null | sort -u
}

mcp_opencode_remove() {
    local name="$1" cfg tmp
    cfg=$(mcp_opencode_config_path)
    [[ -f "$cfg" ]] || return 0
    tmp=$(mktemp)
    jq --arg n "$name" 'if .mcp then .mcp |= del(.[$n]) else . end' "$cfg" > "$tmp" \
        && mv "$tmp" "$cfg"
}

# ─── cursor primitives ──────────────────────────────────────────────────
# Cursor uses ~/.cursor/mcp.json (global) with the same `mcpServers` schema
# as Claude Desktop. No non-interactive `cursor mcp` CLI exists, so we
# jq-edit the file directly. CURSOR_CONFIG overrides the target path (tests).

mcp_cursor_config_path() {
    echo "${CURSOR_CONFIG:-$HOME/.cursor/mcp.json}"
}

mcp_cursor_ensure_config() {
    local cfg; cfg=$(mcp_cursor_config_path)
    mkdir -p "${cfg%/*}"
    if [[ ! -s "$cfg" ]]; then
        echo '{"mcpServers": {}}' > "$cfg"
    fi
}

mcp_cursor_list_current() {
    local cfg; cfg=$(mcp_cursor_config_path)
    [[ -f "$cfg" ]] || return 0
    jq -r '.mcpServers // {} | keys[]' "$cfg" 2>/dev/null | sort -u
}

mcp_cursor_remove() {
    local name="$1" cfg tmp
    cfg=$(mcp_cursor_config_path)
    [[ -f "$cfg" ]] || return 0
    tmp=$(mktemp)
    jq --arg n "$name" 'if .mcpServers then .mcpServers |= del(.[$n]) else . end' "$cfg" > "$tmp" \
        && mv "$tmp" "$cfg"
}

mcp_cursor_current_signature() {
    local cfg; cfg=$(mcp_cursor_config_path)
    [[ -f "$cfg" ]] || { printf '\t\t\n'; return; }
    local entry
    entry=$(jq --arg n "$1" '.mcpServers[$n] // empty' "$cfg" 2>/dev/null)
    [[ -z "$entry" || "$entry" == "null" ]] && { printf '\t\t\n'; return; }
    local cmd args env_json env_csv
    cmd=$(     jq -r '.command // ""'                       <<<"$entry")
    args=$(    jq -r '(.args // []) | join(" ")'             <<<"$entry")
    env_json=$(jq -c '.env // {}'                            <<<"$entry")
    env_csv=$(mcp_resolved_env_csv "$env_json")
    printf '%s\t%s\t%s\n' "$cmd" "$args" "$env_csv"
}

mcp_cursor_add() {
    local name="$1" cfg cmd args_array env_json entry tmp
    cfg=$(mcp_cursor_config_path)
    mcp_cursor_ensure_config
    cmd=$(jq -r --arg n "$name" '.[$n].command' <<<"$HARNESS_DESIRED_JSON")
    args_array=$(jq -c --arg n "$name" '.[$n].args // []' <<<"$HARNESS_DESIRED_JSON")
    env_json=$(mcp_opencode_build_env_json "$name") || return 1
    entry=$(jq -n --arg cmd "$cmd" --argjson args "$args_array" --argjson env "$env_json" '
        {command:$cmd, args:$args}
        + (if ($env | length) > 0 then {env:$env} else {} end)')
    tmp=$(mktemp)
    jq --arg n "$name" --argjson entry "$entry" \
        '.mcpServers = ((.mcpServers // {}) | .[$n] = $entry)' "$cfg" > "$tmp" \
        && mv "$tmp" "$cfg"
}

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
    local name="$1" harness="${2:-}" cmd args env_json env_csv
    cmd=$(jq      -r --arg n "$name" '.[$n].command // ""'        <<<"$HARNESS_DESIRED_JSON")
    args=$(jq     -r --arg n "$name" '.[$n].args // [] | join(" ")' <<<"$HARNESS_DESIRED_JSON")
    env_json=$(jq -c --arg n "$name" '.[$n].env // {}'              <<<"$HARNESS_DESIRED_JSON")
    env_csv=$(mcp_resolved_env_csv "$env_json")
    # opencode entries carry an `enabled` flag; sync always writes it true,
    # so append it to the signature so user-disabled servers register as drift.
    if [[ "$harness" == "opencode" ]]; then
        printf '%s\t%s\t%s\ttrue\n' "$cmd" "$args" "$env_csv"
    else
        printf '%s\t%s\t%s\n' "$cmd" "$args" "$env_csv"
    fi
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
    # Join with commas via parameter expansion; avoids forking `paste`.
    [[ -n "$env_block" ]] && env_csv="${env_block//$'\n'/,}"
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

# opencode stores command + args as a single JSON array under `.command`.
# Split into "cmd" (first element) and "args" (rest, space-joined) so the
# signature lines up with mcp_desired_signature's format. `enabled` is
# included so a user-flipped enabled:false is detected as drift — sync
# always writes enabled:true via mcp_opencode_add.
mcp_opencode_current_signature() {
    local cfg; cfg=$(mcp_opencode_config_path)
    [[ -f "$cfg" ]] || { printf '\t\t\ttrue\n'; return; }
    local entry
    entry=$(jq --arg n "$1" '.mcp[$n] // empty' "$cfg" 2>/dev/null)
    [[ -z "$entry" || "$entry" == "null" ]] && { printf '\t\t\ttrue\n'; return; }
    local cmd args env_json env_csv enabled
    cmd=$(     jq -r '(.command // [])[0] // ""'              <<<"$entry")
    args=$(    jq -r '(.command // [])[1:] | join(" ")'       <<<"$entry")
    env_json=$(jq -c '.environment // {}'                     <<<"$entry")
    env_csv=$(mcp_resolved_env_csv "$env_json")
    # `// true` would also default on enabled:false (jq treats false as empty).
    enabled=$( jq -r 'if has("enabled") then .enabled else true end | tostring' <<<"$entry")
    printf '%s\t%s\t%s\t%s\n' "$cmd" "$args" "$env_csv" "$enabled"
}

# ─── add ────────────────────────────────────────────────────────────────
# `env_flags` is returned via a global because bash 3.2 (macOS default)
# lacks namerefs for arrays. The caller must `env_flags=()` first.

# Yields TAB-separated "key<TAB>value" lines for the named registry entry's
# env block, with ${VAR} placeholders resolved against the live env. Returns
# 1 (and emits a diagnostic to stderr) if any referenced var is unset; empty
# env block returns 0 with no output. Shared by claude/codex flag builders
# and the opencode JSON builder so the resolve+diagnostic logic lives once.
_mcp_resolved_env_pairs() {
    local name="$1" env_json key val var
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
        printf '%s\t%s\n' "$key" "$val"
    done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$env_json")
}

# Echoes the name of the first ${VAR}-style env reference in the entry's env
# block that is unset in the live environment; empty output if all are set or
# there is no env block. Quiet (no diagnostics) — used to decide whether an
# `optional` MCP should be skipped non-fatally.
_mcp_first_unset_env_var() {
    local name="$1" env_json val var
    env_json=$(jq -c --arg n "$name" '.[$n].env // {}' <<<"$HARNESS_DESIRED_JSON")
    [[ "$env_json" == "{}" ]] && return 0
    while IFS= read -r val; do
        if [[ "$val" =~ ^\$\{([^}]+)\}$ ]]; then
            var="${BASH_REMATCH[1]}"
            [[ -z "${!var:-}" ]] && { printf '%s' "$var"; return 0; }
        fi
    done < <(jq -r '.[]' <<<"$env_json")
}

mcp_build_env_flags() {
    local name="$1" flag_prefix="$2"  # "-e" (claude) or "--env" (codex)
    env_flags=()
    local pairs key val
    pairs=$(_mcp_resolved_env_pairs "$name") || return 1
    [[ -z "$pairs" ]] && return 0
    while IFS=$'\t' read -r key val; do
        env_flags+=("$flag_prefix" "${key}=${val}")
    done <<<"$pairs"
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

# Build the JSON array opencode expects under `.command` — first element is
# the launcher, remaining elements are its args.
mcp_opencode_build_command_array() {
    jq -c --arg n "$1" '[.[$n].command] + (.[$n].args // [])' <<<"$HARNESS_DESIRED_JSON"
}

# Build opencode's JSON env object by collecting the shared resolved-pair
# stream into a jq-merged object. Returns 1 on any unset ${VAR} reference.
mcp_opencode_build_env_json() {
    local name="$1" pairs key val env_out='{}'
    pairs=$(_mcp_resolved_env_pairs "$name") || return 1
    [[ -z "$pairs" ]] && { echo '{}'; return 0; }
    while IFS=$'\t' read -r key val; do
        env_out=$(jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}' <<<"$env_out")
    done <<<"$pairs"
    echo "$env_out"
}

mcp_opencode_add() {
    local name="$1" cfg cmd_array env_json entry tmp
    cfg=$(mcp_opencode_config_path)
    mcp_opencode_ensure_config
    cmd_array=$(mcp_opencode_build_command_array "$name")
    env_json=$(mcp_opencode_build_env_json "$name") || return 1
    entry=$(jq -n --argjson cmd "$cmd_array" --argjson env "$env_json" '
        {type:"local", command:$cmd, enabled:true}
        + (if ($env | length) > 0 then {environment:$env} else {} end)')
    tmp=$(mktemp)
    jq --arg n "$name" --argjson entry "$entry" \
        '.mcp = ((.mcp // {}) | .[$n] = $entry)' "$cfg" > "$tmp" \
        && mv "$tmp" "$cfg"
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
        desired=$(mcp_desired_signature "$name" "$harness")
        case "$harness" in
            claude)   current=$(mcp_claude_current_signature   "$name") ;;
            codex)    current=$(mcp_codex_current_signature    "$name") ;;
            opencode) current=$(mcp_opencode_current_signature "$name") ;;
            cursor)   current=$(mcp_cursor_current_signature   "$name") ;;
        esac
        if [[ "$desired" != "$current" ]]; then
            echo "$name"
        fi
    done <<<"$EXISTING"
    return 0
}

# ─── per-harness orchestration ──────────────────────────────────────────
# Returns the count of failed adds via the global ADD_FAILURES so the
# parent exit code can reflect partial failures.

mcp_sync_harness() {
    local harness="$1"
    local rc=0
    _mcp_harness_cli_check "$harness" || rc=$?
    (( rc == 1 )) && return 0
    (( rc == 2 )) && return 1

    echo
    echo -e "${BLUE}━━━ ${harness} ━━━${NC}"

    HARNESS_DESIRED_JSON=$(mcp_filter_for_harness "$harness" "$REGISTRY_JSON")
    DESIRED_NAMES=$(jq -r 'keys[]' <<<"$HARNESS_DESIRED_JSON" | sort)

    _mcp_setup_harness_dispatch "$harness"

    sync_compute_diff

    local to_update; to_update=$(mcp_detect_drift "$harness")
    _mcp_inject_drift_into_adds "$to_update"

    sync_show_plan "$harness MCPs" || { [[ -z "$to_update" ]] && return 0; }

    _mcp_apply_updates "$harness" "$to_update"
    _mcp_apply_adds    "$harness"

    sync_handle_removals "$harness MCPs"
}

# Returns 0 if CLI is installed, 1 to skip (CLI absent), 2 on unknown harness.
_mcp_harness_cli_check() {
    local harness="$1"
    case "$harness" in
        claude)   command -v claude   &>/dev/null || { echo -e "${YELLOW}Skipping claude   (CLI not found)${NC}"; return 1; } ;;
        codex)    command -v codex    &>/dev/null || { echo -e "${YELLOW}Skipping codex    (CLI not found)${NC}"; return 1; } ;;
        opencode) command -v opencode &>/dev/null || { echo -e "${YELLOW}Skipping opencode (CLI not found)${NC}"; return 1; } ;;
        # Cursor has no CLI for MCP management — we jq-edit ~/.cursor/mcp.json
        # directly. Gate on a directory or app-bundle probe so we silently skip
        # machines that don't run Cursor. CURSOR_CONFIG overrides the probe for
        # tests (bats writes to a scratch path).
        cursor)
            if [[ -z "${CURSOR_CONFIG:-}" ]] \
                && [[ ! -d "$HOME/.cursor" ]] \
                && [[ ! -d "/Applications/Cursor.app" ]] \
                && ! command -v cursor &>/dev/null; then
                echo -e "${YELLOW}Skipping cursor   (no ~/.cursor, no Cursor.app, no CLI)${NC}"
                return 1
            fi
            ;;
        *) echo -e "${RED}Unknown harness: $harness${NC}" >&2; return 2 ;;
    esac
}

# Defines CURRENT_NAMES + the get_item_scope / remove_item / get_description
# closures consumed by sync-common.sh. One place to extend per new harness.
_mcp_setup_harness_dispatch() {
    local harness="$1"
    get_description() { jq -r --arg n "$1" '.[$n].description // ""' <<<"$HARNESS_DESIRED_JSON"; }
    case "$harness" in
        claude)
            CURRENT_NAMES=$(mcp_claude_list_current)
            get_item_scope() { mcp_claude_get_scope "$1"; }
            remove_item()    { mcp_claude_remove "$1" "$2"; }
            ;;
        codex)
            CURRENT_NAMES=$(mcp_codex_list_current)
            get_item_scope() { echo "user"; }
            remove_item()    { mcp_codex_remove "$1"; }
            ;;
        opencode)
            CURRENT_NAMES=$(mcp_opencode_list_current)
            get_item_scope() { echo "user"; }
            remove_item()    { mcp_opencode_remove "$1"; }
            ;;
        cursor)
            CURRENT_NAMES=$(mcp_cursor_list_current)
            get_item_scope() { echo "user"; }
            remove_item()    { mcp_cursor_remove "$1"; }
            ;;
    esac
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
        # Optional entries whose credentials aren't configured are skipped
        # non-fatally: keeps the registry entry without failing the sync when
        # the user hasn't set the API key (e.g. todoist without TODOIST_API_KEY).
        local optional unset_var
        optional=$(jq -r --arg n "$name" '.[$n].optional // false' <<<"$HARNESS_DESIRED_JSON")
        if [[ "$optional" == "true" ]]; then
            unset_var=$(_mcp_first_unset_env_var "$name")
            if [[ -n "$unset_var" ]]; then
                echo -e "  ${YELLOW}skipping $name (optional; \$$unset_var unset)${NC}"
                continue
            fi
        fi
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
            claude)   err=$(mcp_claude_add   "$name" 2>&1) || rc=$? ;;
            codex)    err=$(mcp_codex_add    "$name" 2>&1) || rc=$? ;;
            opencode) err=$(mcp_opencode_add "$name" 2>&1) || rc=$? ;;
            cursor)   err=$(mcp_cursor_add   "$name" 2>&1) || rc=$? ;;
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
