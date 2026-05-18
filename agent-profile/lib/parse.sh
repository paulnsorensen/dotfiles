#!/usr/bin/env bash
# parse.sh — Manifest parsing + include resolution for agent profiles.
#
# A profile is a directory containing `profile.yaml` plus payload files
# (agents/, skills/, commands/, hooks/). `ap_parse_manifest` emits the
# fully-resolved manifest as a single JSON document on stdout: arrays
# from included profiles are concatenated (includes first), each item
# carries a `_source_dir` pointing at the profile dir that owns its
# payload files.
#
# Sourced by agent-profile/ap and the bats tests; not meant to be run
# standalone.
#
# Schema notes:
# - `models:` map on agent / command items is preserved verbatim so
#   renderers can branch on `.models.<harness>`. Sentinel value
#   `inherit` (Cursor) means "use session model" and renders no override.
# - Legacy `fallback:` and `agents_md_path:` fields are stripped at parse
#   time. The pre-reshape AGENTS.md splice path is gone — chezmoi owns
#   global AGENTS.md and per-repo profiles never edit any AGENTS.md.

set -euo pipefail

# ─── single-profile parse ───────────────────────────────────────────────
# Reads profile.yaml, returns normalized JSON with defaults filled in.
# Each item in agents/skills/commands/hooks gets a _source_dir field so
# renderers can resolve body_path/script/path against the right tree
# after includes flatten everything into one list.

ap_parse_one() {
    local profile_dir="$1"
    local manifest="$profile_dir/profile.yaml"
    [[ -f "$manifest" ]] || {
        echo "ap_parse_one: $manifest not found" >&2
        return 1
    }

    local json
    json=$(yq -o=json '.' "$manifest")

    local name
    name=$(jq -r '.name // ""' <<<"$json")
    [[ -n "$name" ]] || {
        echo "ap_parse_one: $manifest is missing required field 'name'" >&2
        return 1
    }

    # Inject _source_dir into every item-bearing array and assemble the
    # canonical structure. Defaults for absent sections = empty array/object.
    # `fallback` and `agents_md_path` are stripped — legacy splice path.
    jq \
        --arg sd "$profile_dir" \
        '
        {
          name:        (.name // ""),
          description: (.description // ""),
          include:     (.include // []),
          mcps:     ((.mcps     // []) | map(del(.fallback) + {_source_dir: $sd})),
          agents:   ((.agents   // []) | map(del(.fallback) + {_source_dir: $sd})),
          skills:   ((.skills   // []) | map(del(.fallback) + {_source_dir: $sd})),
          commands: ((.commands // []) | map(del(.fallback) + {_source_dir: $sd})),
          hooks:    ((.hooks    // []) | map(del(.fallback) + {_source_dir: $sd})),
          settings: (.settings // {})
        }' <<<"$json"
}

# ─── include resolution ─────────────────────────────────────────────────
# DFS over the include graph. Visited profiles are tracked by absolute
# dir path (newline-separated in $_AP_VISITED) so a cycle errors loudly
# instead of recursing forever.
#
# Search order for an include name: $PWD/.agent-profiles/<name> first,
# then $DOTFILES_DIR/profiles/<name>. Mirrors ap_find_profile_dir so an
# in-repo profile can extend a global one with the same name.

ap_parse_manifest() {
    local profile_dir="$1"
    profile_dir=$(cd "$profile_dir" && pwd)

    _AP_VISITED=""
    _ap_parse_with_includes "$profile_dir"
}

_ap_parse_with_includes() {
    local profile_dir="$1"
    case $'\n'"$_AP_VISITED"$'\n' in
        *$'\n'"$profile_dir"$'\n'*)
            echo "ap_parse_manifest: include cycle detected at $profile_dir" >&2
            return 1 ;;
    esac
    _AP_VISITED="${_AP_VISITED:+$_AP_VISITED$'\n'}$profile_dir"

    local self
    self=$(ap_parse_one "$profile_dir")

    local includes
    includes=$(jq -r '.include[]?' <<<"$self")

    # Resolve & parse each include, then fold them into an accumulator.
    # Includes come first so the current profile's overrides appear last
    # (i.e. take precedence in the merge).
    local merged='{
      "mcps": [], "agents": [], "skills": [],
      "commands": [], "hooks": [],
      "settings": {}
    }'

    local inc inc_dir inc_json
    while IFS= read -r inc; do
        [[ -z "$inc" ]] && continue
        inc_dir=$(ap_find_profile_dir "$inc") || {
            echo "ap_parse_manifest: include '$inc' not found (from $profile_dir)" >&2
            return 1
        }
        inc_json=$(_ap_parse_with_includes "$inc_dir") || return 1
        merged=$(_ap_merge_two "$merged" "$inc_json")
    done <<<"$includes"

    merged=$(_ap_merge_two "$merged" "$self")
    # Surface top-level identity from the outermost profile, not the
    # accumulator (which has no name/description of its own).
    jq \
        --arg name "$(jq -r '.name' <<<"$self")" \
        --arg desc "$(jq -r '.description' <<<"$self")" \
        '. + {name: $name, description: $desc}' <<<"$merged"
}

# Concatenate arrays, deep-merge settings.permissions_allow (uniq).
_ap_merge_two() {
    local a="$1" b="$2"
    jq -n --argjson a "$a" --argjson b "$b" '
        {
          mcps:     ($a.mcps     + $b.mcps),
          agents:   ($a.agents   + $b.agents),
          skills:   ($a.skills   + $b.skills),
          commands: ($a.commands + $b.commands),
          hooks:    ($a.hooks    + $b.hooks),
          settings: (
            ($a.settings // {}) * ($b.settings // {})
            | . + {
                permissions_allow: (
                  ((($a.settings.permissions_allow // [])
                  + ($b.settings.permissions_allow // []))) | unique
                )
              }
            | if .permissions_allow == [] then del(.permissions_allow) else . end
          )
        }'
}
