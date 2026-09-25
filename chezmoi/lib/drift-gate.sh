# shellcheck shell=sh
# Shared unknown-key gate for the harness settings guards:
#   chezmoi/dot_claude/modify_settings.json      (~/.claude/settings.json)
#   chezmoi/dot_omp/private_agent/modify_config.yml   (~/.omp/agent/config.yml)
#   chezmoi/dot_pi/private_agent/modify_settings.json (~/.pi/agent/settings.json)
#
# Policy: preserve and warn. A live key-path that the repo does not know about
# is a key the harness introduced. The guard keeps its live value, prints a
# warning, and records it in a state file. The guard does not halt the apply:
# a halt stops every later chezmoi target and run_onchange installer.
# Fold each reported key into the registry. List it in the guard's ignore
# file instead, when the harness owns the key at runtime.
#
# Source this file from a POSIX sh modify_ script. It needs jq.

# jq definitions shared by the helpers below. The $names are jq variables.
# shellcheck disable=SC2016
DRIFT_JQ_DEFS='
def sig: [ .[] | strings ];
def under($prefixes): . as $p | any($prefixes[]; . as $pre | $p[0:($pre | length)] == $pre);
'

# drift_ignore_paths FILE
# Print the ignore file as a JSON array of key paths. Each line holds one
# dot-path; "#" comments and blank lines are allowed. A missing file gives [].
drift_ignore_paths() {
    if [ -f "$1" ]; then
        jq -R -s '
            split("\n")
            | map(gsub("#.*"; "") | gsub("^[ \t]+|[ \t]+$"; ""))
            | map(select(length > 0) | split("."))
        ' "$1"
    else
        printf '[]\n'
    fi
}

# drift_overlay_ignored LIVE DESIRED IGNORE_PATHS
# Copy each live leaf under an ignore prefix onto DESIRED when DESIRED does
# not already own that path. A leaf is a scalar, or an empty {} or []. Repo
# intent wins when DESIRED already has the path. Prints the document.
drift_overlay_ignored() {
    printf '%s' "$1" | jq --argjson desired "$2" --argjson ignore "$3" "$DRIFT_JQ_DEFS"'
        def leaf_ok: (type != "object" and type != "array") or . == {} or . == [];
        . as $live
        | ($desired | [paths]) as $dpaths
        | [ paths | select(under($ignore)) | select(. as $p | $live | getpath($p) | leaf_ok) ] as $overlay
        | reduce $overlay[] as $p
            ($desired; if ($p | IN($dpaths[])) then . else setpath($p; $live | getpath($p)) end)
    '
}

# drift_unknown LIVE DESIRED EXEMPT_PATHS [EXTRA_KNOWN_PATHS]
# Print a JSON array of live key-path signatures (array indices dropped) that
# DESIRED does not contain and that no EXEMPT prefix covers. Every node path
# counts, so a new key whose value is {}, [] or null is found too.
drift_unknown() {
    printf '%s' "$1" | jq -c --argjson desired "$2" --argjson exempt "$3" \
        --argjson extra "${4:-[]}" "$DRIFT_JQ_DEFS"'
        (([ $desired | paths | sig ] + $extra) | unique) as $known
        | [ paths | sig ]
        | unique
        | map(select(. as $p | ($p | IN($known[])) == false and ($p | under($exempt)) == false))
    '
}

# drift_preserve LIVE DESIRED UNKNOWN
# Copy the live value of each outermost unknown key-path onto DESIRED.
# Prints {"doc": <document>, "preserved": [dot-paths], "dropped": [dot-paths],
# "dropReasons": {dot-path: "list"|"owned-scalar"}}.
# A path drops as "owned-scalar" when a shorter prefix already holds a scalar
# value in DESIRED. A path drops as "list" when reaching it in LIVE needs an
# array index, so it has no stable slot in DESIRED.
drift_preserve() {
    printf '%s' "$1" | jq -c --argjson desired "$2" --argjson unknown "$3" "$DRIFT_JQ_DEFS"'
        . as $live
        | ($unknown | map(select(. as $p
              | any($unknown[]; . as $q | $q != $p and ($p | under([$q]))) | not))) as $roots
        | ($desired | [paths]) as $dpaths
        | [ $live | paths | select(all(.[]; type == "string")) ] as $addressable
        | reduce $roots[] as $p ({doc: $desired, preserved: [], dropped: [], dropReasons: {}};
            ($p | join(".")) as $key
            | ( [ range(1; $p | length) | $p[0:.] ]
                | map(select(. | IN($dpaths[])))
                | map(select(. as $q | ($desired | getpath($q) | type) as $t | $t != "object" and $t != "array"))
              ) as $scalarPrefixes
            | if ($scalarPrefixes | length) > 0 then
                .dropped += [$p] | .dropReasons[$key] = "owned-scalar"
              elif (($p | IN($addressable[])) | not) then
                .dropped += [$p] | .dropReasons[$key] = "list"
              else
                ((try (.doc | setpath($p; $live | getpath($p))) catch null)) as $next
                | if $next == null then
                    .dropped += [$p] | .dropReasons[$key] = "owned-scalar"
                  else .doc = $next | .preserved += [$p] end
              end)
        | .preserved |= map(join("."))
        | .dropped |= map(join("."))
    '
}

# drift_state_dir
# Print the directory that holds harness-drift state files.
drift_state_dir() {
    printf '%s/harness-drift\n' "${DOTFILES_STATE_DIR:-$HOME/.local/state/dotfiles}"
}

# drift_state_file NAME
# Print the state-file path that records unfolded keys for one harness file.
drift_state_file() {
    printf '%s/%s\n' "$(drift_state_dir)" "$1"
}

# drift_clear_state NAME
# Remove the drift state file of one harness. Warn on failure. Never fail the
# guard.
drift_clear_state() {
    _dcs_state=$(drift_state_file "$1")
    if ! rm -f "$_dcs_state" 2>/dev/null; then
        printf 'WARNING: could not remove stale drift state file: %s\n' "$_dcs_state" >&2
    fi
}

# drift_print_recorded INDENT
# Print every non-empty harness-drift state file under a shared heading, each
# line prefixed by INDENT. Set DRIFT_RECORDED_COUNT to the file count.
# Return 1 and print nothing when no state file holds recorded drift.
# Return 2 and warn on stderr when the state directory cannot be read.
drift_print_recorded() {
    _dpr_indent=${1:-}
    _dpr_dir=$(drift_state_dir)
    DRIFT_RECORDED_COUNT=0
    [ -d "$_dpr_dir" ] || return 1
    if [ ! -r "$_dpr_dir" ] || [ ! -x "$_dpr_dir" ]; then
        printf 'WARNING: cannot read drift state directory: %s\n' "$_dpr_dir" >&2
        return 2
    fi
    for _dpr_file in "$_dpr_dir"/*; do
        [ -s "$_dpr_file" ] || continue
        DRIFT_RECORDED_COUNT=$((DRIFT_RECORDED_COUNT + 1))
        printf '%sUnfolded harness settings in %s (kept or dropped; see below):\n' \
            "$_dpr_indent" "${_dpr_file##*/}"
        sed "s/^/$_dpr_indent/" "$_dpr_file"
    done
    [ "$DRIFT_RECORDED_COUNT" -gt 0 ]
}

# drift_report NAME LABEL RESULT FOLD_TARGET...
# Warn on stderr about the preserved and dropped paths in RESULT (the
# drift_preserve output). Record them in the state file, or remove the state
# file when there are none. A state-file error warns but never fails the
# guard.
drift_report() {
    _dr_name=$1 _dr_label=$2 _dr_result=$3
    shift 3
    _dr_state=$(drift_state_file "$_dr_name")
    _dr_lines=$(printf '%s' "$_dr_result" | jq -r '
        (.preserved[] | "preserved " + .), (.dropped[] | "dropped " + .)')
    if [ -z "$_dr_lines" ]; then
        drift_clear_state "$_dr_name"
        return 0
    fi
    {
        printf 'WARNING: %s has key-path(s) the repo does not know about.\n' "$_dr_label"
        printf '%s' "$_dr_result" | jq -r '
            (.dropReasons // {}) as $reasons
            | (.preserved[] | "  + " + . + "  (live value kept)"),
              (.dropped[] | . as $p
                  | ($reasons[$p] // "list") as $reason
                  | "  - " + $p + "  (" +
                      (if $reason == "owned-scalar" then "under a repo-owned value" else "inside a managed list" end) +
                      "; live value not kept)")'
        printf '  The harness likely introduced these. The sync continues.\n'
        printf '  Fold each into the source, or list app-owned keys in the ignore file:\n'
        for _dr_target in "$@"; do printf '    %s\n' "$_dr_target"; done
    } >&2
    if mkdir -p "${_dr_state%/*}" 2>/dev/null && printf '%s\n' "$_dr_lines" > "$_dr_state" 2>/dev/null; then
        :
    else
        printf 'WARNING: could not persist drift state file: %s\n' "$_dr_state" >&2
    fi
}
