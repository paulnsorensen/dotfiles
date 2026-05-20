#!/bin/bash
# lib.sh — Hook-specific helpers for agents/hooks/sync.sh.
#
# Sourced by sync.sh and by bats tests. Functions take their inputs as args
# or read declared globals (REGISTRY_JSON, HARNESS_DESIRED_JSON, DRY_RUN,
# FORCE, CLAUDE_SETTINGS_FILE, CODEX_CONFIG_FILE) populated by sync.sh; no
# hidden environment beyond that.
#
# Drift signature (per entry, per harness):
#   <deployed-script-path>\t<matcher>\t<timeout>
# Comparable across harnesses; recomputed from desired state and from the
# harness's persisted state, then equality-checked.
#
# Claude backend reconciles claude/settings.json (in-repo, jq in-place).
# Codex backend reconciles ~/.codex/config.toml (yq -p=toml -o=toml).
# Only the SessionStart and Stop slots for each registered hook are managed; all
# other top-level keys and unmanaged hook entries are preserved.
#
# shellcheck disable=SC2034,SC2329
#   SC2034: exports consumed by sync-common.sh
#   SC2329: get_description called indirectly by sync-common.sh

set -euo pipefail

# ─── registry filtering ─────────────────────────────────────────────────
#
# Asserts every entry targets an event wired by the backends below. Routing a
# new event through this file before adding backend support would silently land
# in the wrong slot.

hook_filter_for_harness() {
    local harness="$1" json="$2"
    local missing bad
    # Require `event` explicitly — silently defaulting it would let a typo
    # ("evnt: PostToolUse") land in the SessionStart slot.
    missing=$(jq -r <<<"$json" '
        to_entries
        | map(select(.value.event == null))
        | .[0].key // ""')
    if [[ -n "$missing" ]]; then
        echo -e "${RED}hook_filter_for_harness: entry '$missing' is missing the required 'event' field.${NC}" >&2
        return 1
    fi
    bad=$(jq -r <<<"$json" '
        to_entries
        | map(select((.value.event | IN("SessionStart", "Stop")) | not))
        | .[0].key // ""')
    if [[ -n "$bad" ]]; then
        echo -e "${RED}hook_filter_for_harness: entry '$bad' has unsupported event;${NC}" >&2
        echo -e "${RED}  only SessionStart and Stop are wired in this sync. Add backend support before registering.${NC}" >&2
        return 1
    fi
    jq --arg h "$harness" <<<"$json" '
        to_entries
        | map(select(((.value.harnesses // ["claude","codex"]) | index($h)) != null))
        | from_entries'
}

# ─── deployed paths ─────────────────────────────────────────────────────
# Where the hook script lives at runtime, per harness. Used for the
# command field and for drift comparison.

hook_deployed_path() {
    local harness="$1" script_rel="$2"
    local base; base=$(basename "$script_rel")
    case "$harness" in
        claude) printf '%s\n' "\$HOME/.claude/hooks/$base" ;;
        codex)  printf '%s\n' "\$HOME/.codex/hooks/$base" ;;
        *) return 1 ;;
    esac
}

# Codex uses a literal command string; the bash invocation gets the
# deployed path inlined with $HOME expanded by the shell at hook run-time.
hook_codex_command() {
    local script_rel="$1"
    local base; base=$(basename "$script_rel")
    # shellcheck disable=SC2016
    # The single-quoted $HOME is intentional — it lands in the TOML file
    # literally and Codex's hook runner expands it at hook run-time.
    printf 'bash $HOME/.codex/hooks/%s\n' "$base"
}

hook_event() {
    local name="$1"
    jq -r --arg n "$name" '.[$n].event' <<<"$HARNESS_DESIRED_JSON"
}

# ─── drift signature ────────────────────────────────────────────────────

hook_desired_signature() {
    local name="$1" harness="$2" script matcher timeout deployed
    script=$( jq -r --arg n "$name" '.[$n].script // ""'      <<<"$HARNESS_DESIRED_JSON")
    matcher=$(jq -r --arg n "$name" '.[$n].matcher // ""'     <<<"$HARNESS_DESIRED_JSON")
    timeout=$(jq -r --arg n "$name" '.[$n].timeout // empty' <<<"$HARNESS_DESIRED_JSON")
    deployed=$(hook_deployed_path "$harness" "$script")
    printf '%s\t%s\t%s\n' "$deployed" "$matcher" "$timeout"
}

# ─── Claude: jq over claude/settings.json ───────────────────────────────
# The settings file is checked into the repo; sync writes it in place.

hook_claude_current_signature() {
    local name="$1" event script matcher timeout deployed cmd current_cmd current_timeout
    [[ -f "$CLAUDE_SETTINGS_FILE" ]] || { printf '\t\t\n'; return; }

    event=$( hook_event "$name" )
    script=$( jq -r --arg n "$name" '.[$n].script // ""'  <<<"$HARNESS_DESIRED_JSON")
    matcher=$(jq -r --arg n "$name" '.[$n].matcher // ""' <<<"$HARNESS_DESIRED_JSON")
    deployed=$(hook_deployed_path claude "$script")
    cmd="bash \"$deployed\""

    # Find the first entry for the target event whose first hook command matches.
    current_cmd=$(jq -r --arg e "$event" --arg c "$cmd" '
        .hooks[$e] // []
        | map(select((.hooks // [])[0].command == $c))
        | (.[0].hooks // [])[0].command // ""
    ' "$CLAUDE_SETTINGS_FILE")
    current_timeout=$(jq -r --arg e "$event" --arg c "$cmd" '
        .hooks[$e] // []
        | map(select((.hooks // [])[0].command == $c))
        | (.[0].hooks // [])[0].timeout // empty
    ' "$CLAUDE_SETTINGS_FILE")

    if [[ -z "$current_cmd" ]]; then
        printf '\t\t\n'
        return
    fi
    # Claude has no matcher for these events; reuse the desired matcher
    # for comparison so signatures stay equal once installed.
    printf '%s\t%s\t%s\n' "$deployed" "$matcher" "$current_timeout"
}

# Upsert the hook entry in claude/settings.json. Idempotent.
hook_claude_apply() {
    local name="$1" event script timeout deployed cmd
    event=$( hook_event "$name" )
    script=$( jq -r --arg n "$name" '.[$n].script // ""'      <<<"$HARNESS_DESIRED_JSON")
    timeout=$(jq -r --arg n "$name" '.[$n].timeout // empty' <<<"$HARNESS_DESIRED_JSON")
    deployed=$(hook_deployed_path claude "$script")
    cmd="bash \"$deployed\""

    [[ -f "$CLAUDE_SETTINGS_FILE" ]] \
        || { echo -e "${RED}    claude settings file not found: $CLAUDE_SETTINGS_FILE${NC}" >&2; return 1; }

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/hook-sync.XXXXXX.json")
    # Strip any prior entry for this command, then append a fresh one.
    if [[ -n "$timeout" ]]; then
        jq --arg e "$event" --arg c "$cmd" --argjson t "$timeout" '
            .hooks //= {}
            | .hooks[$e] //= []
            | .hooks[$e] |= (map(select(((.hooks // [])[0].command // "") != $c)))
            | .hooks[$e] += [{ "hooks": [{ "type": "command", "command": $c, "timeout": $t }] }]
        ' "$CLAUDE_SETTINGS_FILE" > "$tmp"
    else
        jq --arg e "$event" --arg c "$cmd" '
            .hooks //= {}
            | .hooks[$e] //= []
            | .hooks[$e] |= (map(select(((.hooks // [])[0].command // "") != $c)))
            | .hooks[$e] += [{ "hooks": [{ "type": "command", "command": $c }] }]
        ' "$CLAUDE_SETTINGS_FILE" > "$tmp"
    fi
    mv "$tmp" "$CLAUDE_SETTINGS_FILE"
}

# ─── Codex: yq over ~/.codex/config.toml ────────────────────────────────
# Preserves every other top-level key (approval_policy, sandbox_mode,
# [mcp_servers], …). Only entries under the target hook event with a matching
# command get rewritten.

hook_codex_current_signature() {
    local name="$1" event script matcher timeout deployed cmd current_cmd current_matcher current_timeout
    [[ -f "$CODEX_CONFIG_FILE" ]] || { printf '\t\t\n'; return; }

    event=$( hook_event "$name" )
    script=$( jq -r --arg n "$name" '.[$n].script // ""'  <<<"$HARNESS_DESIRED_JSON")
    matcher=$(jq -r --arg n "$name" '.[$n].matcher // ""' <<<"$HARNESS_DESIRED_JSON")
    cmd=$(hook_codex_command "$script")
    deployed=$(hook_deployed_path codex "$script")

    # yq toml→json then jq finds the target-event block whose inner hook command matches.
    local block_json
    block_json=$(yq -p=toml -o=json '.' "$CODEX_CONFIG_FILE" 2>/dev/null \
                 | jq --arg e "$event" --arg c "$cmd" '
                     .hooks[$e] // []
                     |
                     map(select(((.hooks // [])[0].command // "") == $c))
                     | .[0] // {}' 2>/dev/null) || { printf '\t\t\n'; return; }

    current_cmd=$(jq -r '(.hooks // [])[0].command // ""'  <<<"$block_json")
    current_matcher=$(jq -r '.matcher // ""'              <<<"$block_json")
    current_timeout=$(jq -r '(.hooks // [])[0].timeout // empty' <<<"$block_json")

    if [[ -z "$current_cmd" ]]; then
        printf '\t\t\n'
        return
    fi
    printf '%s\t%s\t%s\n' "$deployed" "$current_matcher" "$current_timeout"
}

hook_codex_apply() {
    local name="$1" event script matcher timeout cmd
    event=$( hook_event "$name" )
    script=$( jq -r --arg n "$name" '.[$n].script // ""'      <<<"$HARNESS_DESIRED_JSON")
    matcher=$(jq -r --arg n "$name" '.[$n].matcher // ""'     <<<"$HARNESS_DESIRED_JSON")
    timeout=$(jq -r --arg n "$name" '.[$n].timeout // empty' <<<"$HARNESS_DESIRED_JSON")
    cmd=$(hook_codex_command "$script")

    mkdir -p "$(dirname "$CODEX_CONFIG_FILE")"
    [[ -f "$CODEX_CONFIG_FILE" ]] || : > "$CODEX_CONFIG_FILE"

    # Build the desired block as JSON, then merge:
    #   1. Convert current TOML to JSON.
    #   2. Drop any pre-existing entry for this event whose first hook command matches.
    #   3. Append the fresh entry.
    #   4. Convert merged JSON back to TOML.
    #
    # Treat an empty file (first-time init) as {} so a fresh install works.
    # A non-empty file that fails to parse is the user's config in a broken
    # state — abort with a diagnostic rather than overwrite it with {}.
    local current_json desired_block merged tmp yq_err
    if [[ -s "$CODEX_CONFIG_FILE" ]]; then
        yq_err=$(mktemp "${TMPDIR:-/tmp}/hook-sync.XXXXXX.err")
        if ! current_json=$(yq -p=toml -o=json '.' "$CODEX_CONFIG_FILE" 2>"$yq_err"); then
            echo -e "${RED}    refusing to overwrite unparseable $CODEX_CONFIG_FILE:${NC}" >&2
            sed 's/^/      /' "$yq_err" >&2
            rm -f "$yq_err"
            return 1
        fi
        rm -f "$yq_err"
    else
        current_json='{}'
    fi
    [[ -z "$current_json" ]] && current_json='{}'

    local inner
    inner='{"type":"command","command":'"$(jq -Rn --arg c "$cmd" '$c')"'}'
    if [[ -n "$timeout" ]]; then
        inner=$(jq --argjson t "$timeout" '. + {timeout: $t}' <<<"$inner")
    fi
    if [[ -n "$matcher" ]]; then
        desired_block=$(jq -n --arg m "$matcher" --argjson h "$inner" \
            '{matcher: $m, hooks: [$h]}')
    else
        desired_block=$(jq -n --argjson h "$inner" '{hooks: [$h]}')
    fi

    merged=$(jq --arg e "$event" --arg c "$cmd" --argjson b "$desired_block" '
        .hooks //= {}
        | .hooks[$e] //= []
        | .hooks[$e] |= (map(select(((.hooks // [])[0].command // "") != $c)))
        | .hooks[$e] += [$b]
    ' <<<"$current_json")

    tmp=$(mktemp "${TMPDIR:-/tmp}/hook-sync.XXXXXX.toml")
    yq -p=json -o=toml '.' <<<"$merged" > "$tmp"
    mv "$tmp" "$CODEX_CONFIG_FILE"
}

# ─── drift detection ────────────────────────────────────────────────────
# Iterate every desired hook; emit names that are missing OR drifted.
# Returns 0 always (output-driven; non-empty means work to do).

hook_detect_changes() {
    local harness="$1"
    local desired_names; desired_names=$(jq -r 'keys[]' <<<"$HARNESS_DESIRED_JSON")
    local name desired current
    while read -r name; do
        [[ -z "$name" ]] && continue
        desired=$(hook_desired_signature "$name" "$harness")
        case "$harness" in
            claude) current=$(hook_claude_current_signature "$name") ;;
            codex)  current=$(hook_codex_current_signature  "$name") ;;
        esac
        if [[ "$desired" != "$current" ]]; then
            echo "$name"
        fi
    done <<<"$desired_names"
    return 0
}

# ─── per-harness orchestration ──────────────────────────────────────────

hook_sync_harness() {
    local harness="$1"

    case "$harness" in
        claude)
            if [[ ! -f "$CLAUDE_SETTINGS_FILE" ]]; then
                echo -e "${YELLOW}Skipping claude (settings file not found: $CLAUDE_SETTINGS_FILE)${NC}"
                return 0
            fi
            ;;
        codex)
            # No CLI dependency for the Codex backend — it's pure file
            # editing — but if the user has never run Codex on this box
            # the codex/ home dir might not exist yet. Create it on first
            # write inside hook_codex_apply.
            command -v yq &>/dev/null \
                || { echo -e "${YELLOW}Skipping codex (yq not found)${NC}"; return 0; }
            ;;
        *) echo -e "${RED}Unknown harness: $harness${NC}" >&2; return 1 ;;
    esac

    echo
    echo -e "${BLUE}━━━ ${harness} ━━━${NC}"

    HARNESS_DESIRED_JSON=$(hook_filter_for_harness "$harness" "$REGISTRY_JSON")

    local to_change; to_change=$(hook_detect_changes "$harness")

    local desired_count change_count
    desired_count=$(jq -r 'keys | length' <<<"$HARNESS_DESIRED_JSON")
    change_count=$(_count_nonempty "$to_change")

    echo "Registry: $desired_count hook(s) defined"

    if [[ -z "$to_change" ]]; then
        echo -e "${GREEN}Everything in sync!${NC}"
        return 0
    fi

    echo -e "${YELLOW}To upsert ($change_count):${NC}"
    while read -r name; do
        [[ -z "$name" ]] && continue
        local desc; desc=$(jq -r --arg n "$name" '.[$n].description // ""' <<<"$HARNESS_DESIRED_JSON")
        echo "  ~ $name: $desc"
    done <<<"$to_change"
    echo

    if $DRY_RUN; then
        echo -e "${BLUE}[dry-run]${NC} No changes applied"
        return 0
    fi

    echo -e "${GREEN}Applying hook upserts...${NC}"
    while read -r name; do
        [[ -z "$name" ]] && continue
        echo -n "  Upserting $name... "
        local err rc=0
        case "$harness" in
            claude) err=$(hook_claude_apply "$name" 2>&1) || rc=$? ;;
            codex)  err=$(hook_codex_apply  "$name" 2>&1) || rc=$? ;;
        esac
        if (( rc == 0 )); then
            echo -e "${GREEN}done${NC}"
        else
            echo -e "${RED}failed${NC}"
            [[ -n "$err" ]] && echo -e "    ${RED}$err${NC}"
            ADD_FAILURES=$((ADD_FAILURES + 1))
        fi
    done <<<"$to_change"
    echo
}
