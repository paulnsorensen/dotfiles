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
# Fold each reported key into the registry, or list it in the guard's ignore
# file when the harness owns it at runtime.
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
# Copy each live scalar under an ignore prefix onto DESIRED when DESIRED does
# not already own that leaf. Repo intent wins a conflict. Prints the document.
drift_overlay_ignored() {
    printf '%s' "$1" | jq --argjson desired "$2" --argjson ignore "$3" "$DRIFT_JQ_DEFS"'
        . as $live
        | [ paths(scalars) | select(under($ignore)) ] as $overlay
        | reduce $overlay[] as $p
            ($desired; if getpath($p) == null then setpath($p; $live | getpath($p)) else . end)
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
# Prints {"doc": <document>, "preserved": [dot-paths], "dropped": [dot-paths]}.
# A path is dropped when it sits inside a list, or under a scalar that the
# repo owns: the live value then has no stable place in DESIRED.
drift_preserve() {
    printf '%s' "$1" | jq -c --argjson desired "$2" --argjson unknown "$3" "$DRIFT_JQ_DEFS"'
        . as $live
        | ($unknown | map(select(. as $p
              | any($unknown[]; . as $q | $q != $p and ($p | under([$q]))) | not))) as $roots
        | [ $live | paths | select(all(.[]; type == "string")) ] as $addressable
        | reduce $roots[] as $p ({doc: $desired, preserved: [], dropped: []};
            if ($p | IN($addressable[])) then
                ((try (.doc | setpath($p; $live | getpath($p))) catch null)) as $next
                | if $next == null then .dropped += [$p]
                  else .doc = $next | .preserved += [$p] end
            else .dropped += [$p] end)
        | .preserved |= map(join("."))
        | .dropped |= map(join("."))
    '
}

# drift_state_file NAME
# Print the state-file path that records unfolded keys for one harness file.
drift_state_file() {
    printf '%s/harness-drift/%s\n' "${DOTFILES_STATE_DIR:-$HOME/.local/state/dotfiles}" "$1"
}

# drift_report NAME LABEL RESULT FOLD_TARGET...
# Warn on stderr about the preserved and dropped paths in RESULT (the
# drift_preserve output). Record them in the state file, or remove the state
# file when there are none. A state-file error never fails the guard.
drift_report() {
    _dr_name=$1 _dr_label=$2 _dr_result=$3
    shift 3
    _dr_state=$(drift_state_file "$_dr_name")
    _dr_lines=$(printf '%s' "$_dr_result" | jq -r '
        (.preserved[] | "preserved " + .), (.dropped[] | "dropped " + .)')
    if [ -z "$_dr_lines" ]; then
        rm -f "$_dr_state" 2>/dev/null || true
        return 0
    fi
    {
        echo "WARNING: $_dr_label has key-path(s) the repo does not know about."
        printf '%s' "$_dr_result" | jq -r '
            (.preserved[] | "  + " + . + "  (live value kept)"),
            (.dropped[] | "  - " + . + "  (inside a managed list; live value not kept)")'
        echo "  The harness likely introduced these. The sync continues."
        echo "  Fold each into the source, or list app-owned keys in the ignore file:"
        for _dr_target in "$@"; do echo "    $_dr_target"; done
    } >&2
    if mkdir -p "${_dr_state%/*}" 2>/dev/null; then
        printf '%s\n' "$_dr_lines" > "$_dr_state" 2>/dev/null || true
    fi
}
