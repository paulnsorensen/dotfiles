#!/usr/bin/env bash
# manifest.sh — Track files installed by each profile so uninstall is
# surgical. The manifest lives at <target>/.agent-profile/manifest.json
# and shapes as:
#   {
#     "<profile>": {
#       "files":       ["<rel-path>", ...],   # whole-file artifacts → rm
#       "merged_json": {...resolved profile manifest at install time...}
#     }
#   }
#
# `files` get rm'd on uninstall, but only when no *other* installed
# profile also claims the same path (ref-counting for shared files like
# `.mcp.json`, `opencode.json`, `.claude/agents/<shared>.md`).
# `merged_json` is the full resolved profile passed to each renderer's
# `*_clean` function so it can surgically remove the entries it added to
# shared files (settings.local.json, opencode.json, .mcp.json) without
# nuking anything the user added by hand.
#
# Every read validates the manifest parses as JSON and is shaped sanely
# (top-level object; per-profile entries are objects). Corruption fails
# loud — silent no-op on uninstall is a correctness bug.

set -euo pipefail

ap_manifest_path() {
    echo "${1%/}/.agent-profile/manifest.json"
}

# Validate that the manifest at <path> parses as JSON and is shaped as
# expected (top-level object, per-profile entries are objects). On
# failure: print `ap: manifest at <path> is corrupt: <reason>` and exit 1.
# Callers may pass --quiet-missing to treat a non-existent file as a no-op.
_ap_manifest_validate() {
    local path="$1"
    [[ -f "$path" ]] || return 0

    if ! jq empty "$path" >/dev/null 2>&1; then
        echo "ap: manifest at $path is corrupt: not valid JSON" >&2
        exit 1
    fi

    local top_type
    top_type=$(jq -r 'type' "$path" 2>/dev/null || echo "error")
    if [[ "$top_type" != "object" ]]; then
        echo "ap: manifest at $path is corrupt: top-level must be an object, got $top_type" >&2
        exit 1
    fi

    # Every profile entry must itself be an object. Catches truncated /
    # half-written manifests where a key maps to a string or null.
    local bad
    bad=$(jq -r '[to_entries[] | select(.value | type != "object") | .key] | join(",")' "$path" 2>/dev/null || echo "")
    if [[ -n "$bad" ]]; then
        echo "ap: manifest at $path is corrupt: non-object entries for profile(s): $bad" >&2
        exit 1
    fi
}

ap_manifest_init() {
    local target="$1"
    local path; path=$(ap_manifest_path "$target")
    mkdir -p "$(dirname "$path")"
    [[ -f "$path" ]] || echo '{}' > "$path"
    _ap_manifest_validate "$path"
}

ap_manifest_record_file() {
    local target="$1" profile="$2" rel_path="$3"
    ap_manifest_init "$target"
    local path; path=$(ap_manifest_path "$target")
    local tmp; tmp=$(mktemp)
    jq --arg p "$profile" --arg f "$rel_path" '
        .[$p] = ((.[$p] // {files: []})
                 | .files = ((.files // []) + [$f] | unique))
    ' "$path" > "$tmp" && mv "$tmp" "$path"
}

ap_manifest_files() {
    local target="$1" profile="$2"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || return 0
    _ap_manifest_validate "$path"
    jq -r --arg p "$profile" '.[$p].files[]? // empty' "$path"
}

ap_manifest_clear() {
    local target="$1" profile="$2"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || return 0
    _ap_manifest_validate "$path"
    local tmp; tmp=$(mktemp)
    jq --arg p "$profile" 'del(.[$p])' "$path" > "$tmp" && mv "$tmp" "$path"
}

ap_manifest_profiles() {
    local target="$1"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || return 0
    _ap_manifest_validate "$path"
    jq -r 'keys[]? // empty' "$path"
}

ap_manifest_record_merged_json() {
    local target="$1" profile="$2" merged_json="$3"
    ap_manifest_init "$target"
    local path; path=$(ap_manifest_path "$target")
    local tmp; tmp=$(mktemp)
    jq --arg p "$profile" --argjson m "$merged_json" '
        .[$p] = ((.[$p] // {files: []})
                 | .merged_json = $m)
    ' "$path" > "$tmp" && mv "$tmp" "$path"
}

ap_manifest_merged_json() {
    local target="$1" profile="$2"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || { echo ""; return 0; }
    _ap_manifest_validate "$path"
    jq -c --arg p "$profile" '.[$p].merged_json // empty' "$path"
}

# Returns 0 (true) if any *other* installed profile in the manifest also
# records <file> in its files list. Used by uninstall to decide whether
# a tracked file is safe to delete: shared artefacts (`.mcp.json`,
# `opencode.json`, `.claude/agents/<shared>.md`) survive as long as some
# other profile still owns them.
ap_manifest_other_profiles_claim_file() {
    local target="$1" profile="$2" file="$3"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || return 1
    _ap_manifest_validate "$path"
    local hit
    hit=$(jq -r --arg p "$profile" --arg f "$file" '
        [to_entries[]
         | select(.key != $p)
         | select((.value.files // []) | index($f))] | length
    ' "$path")
    [[ "$hit" -gt 0 ]]
}

# On re-install of <profile>, compute `dropped = old_files - new_files`
# and physically remove every dropped path from <target>, then update the
# manifest to drop those entries. Files still claimed by another profile
# are kept on disk (ref-counted) but the dropped entry is still removed
# from *this* profile's record.
#
# <new_files_json> is a JSON array of relative paths the renderers just
# emitted for this profile (`_AP_OUT_FILES` flattened across all
# harnesses, deduped).
#
# Safe to call when no prior install exists (old_files is empty → no-op).
ap_manifest_diff_and_clean() {
    local target="$1" profile="$2" new_files_json="$3"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || return 0
    _ap_manifest_validate "$path"

    # Compute dropped = old - new.
    local dropped
    dropped=$(jq -r \
        --arg p "$profile" \
        --argjson new "$new_files_json" '
        ((.[$p].files // []) - $new)[]? // empty
    ' "$path")

    [[ -z "$dropped" ]] && return 0

    local f abs
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if ap_manifest_other_profiles_claim_file "$target" "$profile" "$f"; then
            # Another profile still owns it — leave the file on disk.
            continue
        fi
        abs="${target%/}/$f"
        if [[ -e "$abs" || -L "$abs" ]]; then
            rm -rf -- "$abs"
        fi
    done <<<"$dropped"
}
