#!/bin/bash
# lib.sh — Hook-specific helpers for agents/hooks/sync.sh.
#
# Sourced by sync.sh and by bats tests. Functions take their inputs as args
# or read declared globals (REGISTRY_JSON, HARNESS_DESIRED_JSON, DRY_RUN,
# FORCE, CLAUDE_SETTINGS_FILE, CODEX_CONFIG_FILE) populated by sync.sh; no
# hidden environment beyond that.
#
# Drift signature (per entry, per harness):
#   <resolved-command>\t<event>\t<matcher>\t<timeout>\t<async>
# `resolved-command` is the final command string — `bash "<deployed-path>"`
# for a `script` entry, or the literal `command` verbatim. Comparable across
# harnesses; recomputed from desired state and from the harness's persisted
# state, then equality-checked. `event` is part of the signature so two
# entries pointing at the same command but at different event slots don't
# collide on drift detection. `async` is claude-only (empty for codex).
#
# Claude backend reconciles claude/settings.json (in-repo, jq in-place).
# Codex backend reconciles ~/.codex/config.toml (yq -p=toml -o=toml).
# Only the event slot named by each registered hook is managed; all other
# top-level keys and unmanaged hook entries (other events, other commands)
# are preserved.
#
# shellcheck disable=SC2034,SC2329
#   SC2034: exports consumed by sync-common.sh
#   SC2329: get_description called indirectly by sync-common.sh

set -euo pipefail

# Supported hook event types. Adding a new event needs:
#   1) Bats coverage for the new event in tests/agents-hooks-sync.bats.
#   2) If the harness writes a matcher field into the outer block for the
#      new event, extend _hook_event_uses_matcher accordingly.
#
# PermissionRequest is claude-only — codex doesn't fire it. The codex
# backend will still happily write the entry if a registry author opts
# codex in, but at run time codex won't trigger it.
HOOK_EVENTS_VALID=(SessionStart UserPromptSubmit PreToolUse PostToolUse Stop SubagentStop PermissionRequest)

# Returns 0 iff the harness writes a `matcher` field into the outer block
# for that (event, harness) pair.
#   claude — PreToolUse / PostToolUse (matcher = tool-name regex).
#            SessionStart, UserPromptSubmit, Stop have no matcher.
#   codex  — SessionStart (matcher = source regex: startup|resume|clear) and
#            PreToolUse / PostToolUse (matcher = tool-name regex).
# Anything not listed here writes the inner hook entry without a matcher
# wrapper, and any registry-provided matcher is silently dropped for that
# (event, harness) pair.
_hook_event_uses_matcher() {
    local event="$1" harness="$2"
    case "$harness:$event" in
        claude:PreToolUse|claude:PostToolUse) return 0 ;;
        codex:SessionStart|codex:PreToolUse|codex:PostToolUse) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── registry filtering ─────────────────────────────────────────────────
#
# Validates that every entry declares a known `event`, then filters to the
# subset that opts into the requested harness.

hook_filter_for_harness() {
    local harness="$1" json="$2"
    local missing bad_name bad_event both_set neither_set
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
    # Validate event ∈ supported set. The jq passes the set in as JSON so
    # the check stays in one place — no per-entry bash loop.
    local valid_events_json
    valid_events_json=$(printf '%s\n' "${HOOK_EVENTS_VALID[@]}" | jq -R . | jq -s .)
    bad_name=$(jq -r --argjson valid "$valid_events_json" <<<"$json" '
        to_entries
        | map(select((.value.event as $e | $valid | index($e)) == null))
        | .[0].key // ""')
    if [[ -n "$bad_name" ]]; then
        bad_event=$(jq -r --arg n "$bad_name" '.[$n].event' <<<"$json")
        echo -e "${RED}hook_filter_for_harness: entry '$bad_name' has unsupported event '$bad_event';${NC}" >&2
        echo -e "${RED}  supported: ${HOOK_EVENTS_VALID[*]}. Add the event to HOOK_EVENTS_VALID and${NC}" >&2
        echo -e "${RED}  extend _hook_event_uses_matcher if the harness uses a matcher there.${NC}" >&2
        return 1
    fi
    # `script` and `command` are mutually exclusive (script → deployed path,
    # command → literal external command). Exactly one must be set.
    both_set=$(jq -r <<<"$json" '
        to_entries
        | map(select((.value.script // "") != "" and (.value.command // "") != ""))
        | .[0].key // ""')
    if [[ -n "$both_set" ]]; then
        echo -e "${RED}hook_filter_for_harness: entry '$both_set' sets both 'script' and 'command';${NC}" >&2
        echo -e "${RED}  these are mutually exclusive — pick one.${NC}" >&2
        return 1
    fi
    neither_set=$(jq -r <<<"$json" '
        to_entries
        | map(select((.value.script // "") == "" and (.value.command // "") == ""))
        | .[0].key // ""')
    if [[ -n "$neither_set" ]]; then
        echo -e "${RED}hook_filter_for_harness: entry '$neither_set' has neither 'script' nor 'command';${NC}" >&2
        echo -e "${RED}  set 'script: <repo-relative-path>' for a deployed hook, or${NC}" >&2
        echo -e "${RED}  'command: <literal>' for an external binary.${NC}" >&2
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
# Quoted so a $HOME containing whitespace doesn't word-split.
hook_codex_command() {
    local script_rel="$1"
    local base; base=$(basename "$script_rel")
    # shellcheck disable=SC2016
    # The single-quoted $HOME is intentional — it lands in the TOML file
    # literally and Codex's hook runner expands it at hook run-time.
    printf 'bash "$HOME/.codex/hooks/%s"\n' "$base"
}

# Resolve the final command string for a registry entry. Mutually exclusive
# fields:
#   script:   repo-relative path. Deployed under $HOME/.<harness>/hooks/;
#             command is `bash "<deployed-path>"`.
#   command:  literal command. Used verbatim, no deploy. The string is
#             written into the hook entry as-is (caller is responsible for
#             any $HOME-style quoting).
# If both are set the registry is malformed (caller validates before this
# point). If neither is set, returns empty — *_apply functions guard.
# shellcheck disable=SC2016
#   The literal `$HOME` in the claude command is intentional — it is written
#   verbatim into settings.json and expanded by Claude at runtime, not bash.
_hook_resolve_command() {
    local name="$1" harness="$2"
    local script command_literal
    script=$(         jq -r --arg n "$name" '.[$n].script  // ""' <<<"$HARNESS_DESIRED_JSON")
    command_literal=$(jq -r --arg n "$name" '.[$n].command // ""' <<<"$HARNESS_DESIRED_JSON")

    if [[ -n "$command_literal" ]]; then
        printf '%s\n' "$command_literal"
        return 0
    fi
    if [[ -n "$script" ]]; then
        case "$harness" in
            claude) printf 'bash "$HOME/.claude/hooks/%s"\n' "$(basename "$script")" ;;
            codex)  hook_codex_command "$script" ;;
            *)      return 1 ;;
        esac
        return 0
    fi
    return 1
}

# ─── drift signature ────────────────────────────────────────────────────
# Five tab-separated fields: <resolved-command> <event> <matcher> <timeout> <async>.
# `event` is included so two entries with the same command but different
# event slots don't collide. `matcher` is preserved verbatim from the
# registry even when the (event, harness) pair doesn't use one — current
# signature normalizes the same way (see *_current_signature below) so
# equality still holds in the irrelevant-matcher case.
# `async` is claude-only; codex ignores. Empty when unset.

hook_desired_signature() {
    local name="$1" harness="$2" event matcher timeout async_field cmd
    event=$(    jq -r --arg n "$name" '.[$n].event   // ""'      <<<"$HARNESS_DESIRED_JSON")
    matcher=$(  jq -r --arg n "$name" '.[$n].matcher // ""'      <<<"$HARNESS_DESIRED_JSON")
    timeout=$(  jq -r --arg n "$name" '.[$n].timeout // empty'   <<<"$HARNESS_DESIRED_JSON")
    # jq's `//` operator treats both `null` AND `false` as fallback triggers,
    # so `.async // empty` silently drops `async: false`. has("async") gates
    # on key presence so an explicit `false` survives.
    async_field=$(jq -r --arg n "$name" \
        '.[$n] as $h | if ($h | has("async")) then $h.async | tostring else "" end' \
        <<<"$HARNESS_DESIRED_JSON")
    cmd=$(_hook_resolve_command "$name" "$harness") || cmd=""
    # async is claude-only — codex never writes it, so normalize to empty
    # when computing the codex desired signature.
    [[ "$harness" == "codex" ]] && async_field=""
    printf '%s\t%s\t%s\t%s\t%s\n' "$cmd" "$event" "$matcher" "$timeout" "$async_field"
}

# ─── Claude: jq over claude/settings.json ───────────────────────────────
# The settings file is checked into the repo; sync writes it in place.

hook_claude_current_signature() {
    local name="$1" event matcher cmd
    local current_cmd current_matcher current_timeout current_async
    [[ -f "$CLAUDE_SETTINGS_FILE" ]] || { printf '\t\t\t\t\n'; return; }

    event=$(  jq -r --arg n "$name" '.[$n].event   // ""' <<<"$HARNESS_DESIRED_JSON")
    matcher=$(jq -r --arg n "$name" '.[$n].matcher // ""' <<<"$HARNESS_DESIRED_JSON")
    cmd=$(_hook_resolve_command "$name" claude) || cmd=""

    # Find the outer block whose first hook command matches.
    local block_json
    block_json=$(jq --arg e "$event" --arg c "$cmd" '
        .hooks[$e] // []
        | map(select(((.hooks // [])[0].command // "") == $c))
        | .[0] // {}
    ' "$CLAUDE_SETTINGS_FILE")

    current_cmd=$(jq -r     '(.hooks // [])[0].command // ""'        <<<"$block_json")
    current_matcher=$(jq -r '.matcher // ""'                         <<<"$block_json")
    current_timeout=$(jq -r '(.hooks // [])[0].timeout // empty'     <<<"$block_json")
    # has("async") to preserve a literal `false` on disk; `//` would drop it.
    current_async=$(jq -r '
        (.hooks // [])[0] as $h
        | if ($h != null) and ($h | has("async")) then $h.async | tostring else "" end
    ' <<<"$block_json")

    if [[ -z "$current_cmd" ]]; then
        printf '\t\t\t\t\n'
        return
    fi
    # For (event, claude) pairs that don't use matcher, normalize current
    # to the desired matcher so signatures stay equal once installed.
    if ! _hook_event_uses_matcher "$event" claude; then
        current_matcher="$matcher"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$cmd" "$event" "$current_matcher" "$current_timeout" "$current_async"
}

# Build the inner hook entry — { type: "command", command, [timeout], [async] }.
# `async` is claude-only — caller must pass empty for codex (the *_apply
# functions enforce this by reading the registry async field only for claude).
_hook_build_inner() {
    local cmd="$1" timeout="$2" async_field="${3:-}"
    local inner
    inner=$(jq -n --arg c "$cmd" '{type: "command", command: $c}')
    if [[ -n "$timeout" ]]; then
        inner=$(jq --argjson t "$timeout" '. + {timeout: $t}' <<<"$inner")
    fi
    if [[ -n "$async_field" ]]; then
        inner=$(jq --argjson a "$async_field" '. + {async: $a}' <<<"$inner")
    fi
    printf '%s\n' "$inner"
}

# Build the outer block. Includes `matcher` iff matcher is non-empty AND
# the (event, harness) pair uses a matcher. The optional async_field is
# threaded into the inner entry (claude-only; codex callers must pass "").
_hook_build_outer() {
    local event="$1" harness="$2" cmd="$3" matcher="$4" timeout="$5" async_field="${6:-}"
    local inner
    inner=$(_hook_build_inner "$cmd" "$timeout" "$async_field")
    if [[ -n "$matcher" ]] && _hook_event_uses_matcher "$event" "$harness"; then
        jq -n --arg m "$matcher" --argjson h "$inner" '{matcher: $m, hooks: [$h]}'
    else
        jq -n --argjson h "$inner" '{hooks: [$h]}'
    fi
}

# Upsert the hook entry in claude/settings.json. Idempotent. Strips any
# prior entry under the same event slot whose first command matches, then
# appends a fresh one.
hook_claude_apply() {
    local name="$1" event matcher timeout async_field cmd
    event=$(    jq -r --arg n "$name" '.[$n].event   // ""'     <<<"$HARNESS_DESIRED_JSON")
    matcher=$(  jq -r --arg n "$name" '.[$n].matcher // ""'     <<<"$HARNESS_DESIRED_JSON")
    timeout=$(  jq -r --arg n "$name" '.[$n].timeout // empty' <<<"$HARNESS_DESIRED_JSON")
    # has("async") gates on key presence — `//` would drop async:false (jq
    # treats false the same as null for the alternative operator).
    async_field=$(jq -r --arg n "$name" \
        '.[$n] as $h | if ($h | has("async")) then $h.async | tostring else "" end' \
        <<<"$HARNESS_DESIRED_JSON")
    cmd=$(_hook_resolve_command "$name" claude) \
        || { echo -e "${RED}    hook entry '$name' has neither script nor command${NC}" >&2; return 1; }

    [[ -f "$CLAUDE_SETTINGS_FILE" ]] \
        || { echo -e "${RED}    claude settings file not found: $CLAUDE_SETTINGS_FILE${NC}" >&2; return 1; }

    local outer
    outer=$(_hook_build_outer "$event" claude "$cmd" "$matcher" "$timeout" "$async_field")

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/hook-sync.XXXXXX.json")
    jq --arg e "$event" --arg c "$cmd" --argjson b "$outer" '
        .hooks //= {}
        | .hooks[$e] //= []
        | .hooks[$e] |= (map(select(((.hooks // [])[0].command // "") != $c)))
        | .hooks[$e] += [$b]
    ' "$CLAUDE_SETTINGS_FILE" > "$tmp"
    mv "$tmp" "$CLAUDE_SETTINGS_FILE"
}

# ─── Codex: yq over ~/.codex/config.toml ────────────────────────────────
# Preserves every other top-level key (approval_policy, sandbox_mode,
# [mcp_servers], …) and every other event slot. Only the entry under the
# named event with a matching command gets rewritten.

hook_codex_current_signature() {
    local name="$1" event matcher cmd
    local current_cmd current_matcher current_timeout
    [[ -f "$CODEX_CONFIG_FILE" ]] || { printf '\t\t\t\t\n'; return; }

    event=$(  jq -r --arg n "$name" '.[$n].event   // ""' <<<"$HARNESS_DESIRED_JSON")
    matcher=$(jq -r --arg n "$name" '.[$n].matcher // ""' <<<"$HARNESS_DESIRED_JSON")
    cmd=$(_hook_resolve_command "$name" codex) || cmd=""

    # yq toml→json (scoped to the event slot) then jq finds the matching
    # block. env() keeps the event name out of the yq path-injection space.
    local block_json
    block_json=$(HOOK_EVENT="$event" yq -p=toml -o=json '.hooks[env(HOOK_EVENT)] // []' "$CODEX_CONFIG_FILE" 2>/dev/null \
                 | jq --arg c "$cmd" '
                     map(select(((.hooks // [])[0].command // "") == $c))
                     | .[0] // {}' 2>/dev/null) || { printf '\t\t\t\t\n'; return; }

    current_cmd=$(jq -r     '(.hooks // [])[0].command // ""'    <<<"$block_json")
    current_matcher=$(jq -r '.matcher // ""'                     <<<"$block_json")
    current_timeout=$(jq -r '(.hooks // [])[0].timeout // empty' <<<"$block_json")

    if [[ -z "$current_cmd" ]]; then
        printf '\t\t\t\t\n'
        return
    fi
    if ! _hook_event_uses_matcher "$event" codex; then
        current_matcher="$matcher"
    fi
    # async is claude-only — emit empty so codex desired/current signatures match.
    printf '%s\t%s\t%s\t%s\t\n' "$cmd" "$event" "$current_matcher" "$current_timeout"
}

# Read the current Codex config and print JSON for the merge step on stdout.
# Empty file → '{}' (first-time init). Non-empty + unparseable → abort with
# the yq diagnostic — the file is the user's config in a broken state, and
# overwriting it with '{}' would silently nuke their settings.
_hook_codex_read_current_json() {
    [[ ! -s "$CODEX_CONFIG_FILE" ]] && { printf '%s\n' '{}'; return 0; }

    local yq_err out rc=0
    yq_err=$(mktemp "${TMPDIR:-/tmp}/hook-sync.XXXXXX.err")
    out=$(yq -p=toml -o=json '.' "$CODEX_CONFIG_FILE" 2>"$yq_err") || rc=$?
    if (( rc != 0 )); then
        echo -e "${RED}    refusing to overwrite unparseable $CODEX_CONFIG_FILE:${NC}" >&2
        sed 's/^/      /' "$yq_err" >&2
        rm -f "$yq_err"
        return 1
    fi
    rm -f "$yq_err"
    [[ -z "$out" ]] && out='{}'
    printf '%s\n' "$out"
}

# Round-trip read-back + top-level key preservation. Refuses the mv if yq
# can't re-parse the freshly written TOML, if the pre-image was non-empty
# but unparseable (sentinel for malformed user file we just regenerated
# from current_json), or if any top-level key from the pre-image is
# missing in the post-image — silently truncating the user's codex
# config is the regression this guard exists to prevent.
#
# Capture each `yq` exit status explicitly: under `set -e`, an unguarded
# `$(yq ...)` that returns non-zero aborts the function before the temp
# file is cleaned up.
_hook_codex_validate_writeback() {
    local tmp="$1"
    local rc=0
    yq -p=toml '.' "$tmp" >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        echo -e "${RED}    yq emitted unparseable TOML; refusing to overwrite $CODEX_CONFIG_FILE${NC}" >&2
        return 1
    fi
    [[ -s "$CODEX_CONFIG_FILE" ]] || return 0

    local before_keys after_keys
    rc=0
    before_keys=$(yq -p=toml -o=json 'keys | sort | .[]' "$CODEX_CONFIG_FILE" 2>/dev/null) || rc=$?
    if (( rc != 0 )) || [[ -z "$before_keys" ]]; then
        echo -e "${RED}    refusing to overwrite $CODEX_CONFIG_FILE: pre-image is non-empty but yq cannot parse it${NC}" >&2
        return 1
    fi
    rc=0
    after_keys=$(yq -p=toml -o=json 'keys | sort | .[]' "$tmp" 2>/dev/null) || rc=$?
    if (( rc != 0 )); then
        echo -e "${RED}    yq failed to read back $tmp for key comparison${NC}" >&2
        return 1
    fi

    local missing
    missing=$(comm -23 <(echo "$before_keys") <(echo "$after_keys"))
    if [[ -n "$missing" ]]; then
        echo -e "${RED}    refusing to overwrite $CODEX_CONFIG_FILE: rewrite would drop top-level key(s):${NC}" >&2
        local indented="${missing//$'\n'/$'\n      '}"
        printf '      %s\n' "$indented" >&2
        return 1
    fi
}

hook_codex_apply() {
    local name="$1" event matcher timeout cmd
    event=$(  jq -r --arg n "$name" '.[$n].event   // ""'     <<<"$HARNESS_DESIRED_JSON")
    matcher=$(jq -r --arg n "$name" '.[$n].matcher // ""'     <<<"$HARNESS_DESIRED_JSON")
    timeout=$(jq -r --arg n "$name" '.[$n].timeout // empty' <<<"$HARNESS_DESIRED_JSON")
    cmd=$(_hook_resolve_command "$name" codex) \
        || { echo -e "${RED}    hook entry '$name' has neither script nor command${NC}" >&2; return 1; }

    mkdir -p "$(dirname "$CODEX_CONFIG_FILE")"
    [[ -f "$CODEX_CONFIG_FILE" ]] || : > "$CODEX_CONFIG_FILE"

    # Merge plan: TOML → JSON → drop prior entry for this command (under
    # the same event slot) → append fresh entry → JSON → TOML. Helpers
    # handle reading the pre-image, building the desired block, and
    # validating the post-image. async_field is intentionally "" — codex
    # doesn't use it.
    local current_json desired_block merged tmp
    current_json=$(_hook_codex_read_current_json) || return 1
    desired_block=$(_hook_build_outer "$event" codex "$cmd" "$matcher" "$timeout" "")

    merged=$(jq --arg e "$event" --arg c "$cmd" --argjson b "$desired_block" '
        .hooks //= {}
        | .hooks[$e] //= []
        | .hooks[$e] |= (map(select(((.hooks // [])[0].command // "") != $c)))
        | .hooks[$e] += [$b]
    ' <<<"$current_json")

    tmp=$(mktemp "${TMPDIR:-/tmp}/hook-sync.XXXXXX.toml")
    if ! yq -p=json -o=toml '.' <<<"$merged" > "$tmp" 2>/dev/null; then
        echo -e "${RED}    yq failed to emit TOML; refusing to overwrite $CODEX_CONFIG_FILE${NC}" >&2
        rm -f "$tmp"
        return 1
    fi
    if ! _hook_codex_validate_writeback "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
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
