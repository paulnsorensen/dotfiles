#!/usr/bin/env bash
# manifest.sh — Track files installed by each profile so uninstall is
# surgical. The manifest lives at <target>/.agent-profile/manifest.json
# and shapes as:
#   {
#     "<profile>": {
#       "files":       ["<rel-path>", ...],   # whole-file artifacts → rm
#       "agents_md":   ["AGENTS.md"],         # marker-block edits → strip
#       "merged_json": {...resolved profile manifest at install time...}
#     }
#   }
#
# `files` get rm'd on uninstall. `agents_md` entries get their marker
# block stripped (the file may have pre-existing content). `merged_json`
# is the full resolved profile passed to each renderer's `*_clean`
# function so it can surgically remove the entries it added to shared
# files (settings.local.json, opencode.json, .mcp.json) without nuking
# anything the user added by hand.

set -euo pipefail

ap_manifest_path() {
    echo "${1%/}/.agent-profile/manifest.json"
}

ap_manifest_init() {
    local target="$1"
    local path; path=$(ap_manifest_path "$target")
    mkdir -p "$(dirname "$path")"
    [[ -f "$path" ]] || echo '{}' > "$path"
}

ap_manifest_record_file() {
    local target="$1" profile="$2" rel_path="$3"
    ap_manifest_init "$target"
    local path; path=$(ap_manifest_path "$target")
    local tmp; tmp=$(mktemp)
    jq --arg p "$profile" --arg f "$rel_path" '
        .[$p] = ((.[$p] // {files: [], agents_md: []})
                 | .files = ((.files // []) + [$f] | unique))
    ' "$path" > "$tmp" && mv "$tmp" "$path"
}

ap_manifest_record_agents_md() {
    local target="$1" profile="$2" rel_path="$3"
    ap_manifest_init "$target"
    local path; path=$(ap_manifest_path "$target")
    local tmp; tmp=$(mktemp)
    jq --arg p "$profile" --arg f "$rel_path" '
        .[$p] = ((.[$p] // {files: [], agents_md: []})
                 | .agents_md = ((.agents_md // []) + [$f] | unique))
    ' "$path" > "$tmp" && mv "$tmp" "$path"
}

ap_manifest_files() {
    local target="$1" profile="$2"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || return 0
    jq -r --arg p "$profile" '.[$p].files[]? // empty' "$path"
}

ap_manifest_agents_md() {
    local target="$1" profile="$2"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || return 0
    jq -r --arg p "$profile" '.[$p].agents_md[]? // empty' "$path"
}

ap_manifest_clear() {
    local target="$1" profile="$2"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || return 0
    local tmp; tmp=$(mktemp)
    jq --arg p "$profile" 'del(.[$p])' "$path" > "$tmp" && mv "$tmp" "$path"
}

ap_manifest_profiles() {
    local target="$1"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || return 0
    jq -r 'keys[]? // empty' "$path"
}

ap_manifest_record_merged_json() {
    local target="$1" profile="$2" merged_json="$3"
    ap_manifest_init "$target"
    local path; path=$(ap_manifest_path "$target")
    local tmp; tmp=$(mktemp)
    jq --arg p "$profile" --argjson m "$merged_json" '
        .[$p] = ((.[$p] // {files: [], agents_md: []})
                 | .merged_json = $m)
    ' "$path" > "$tmp" && mv "$tmp" "$path"
}

ap_manifest_merged_json() {
    local target="$1" profile="$2"
    local path; path=$(ap_manifest_path "$target")
    [[ -f "$path" ]] || { echo ""; return 0; }
    jq -c --arg p "$profile" '.[$p].merged_json // empty' "$path"
}
