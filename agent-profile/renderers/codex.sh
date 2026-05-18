#!/usr/bin/env bash
# codex.sh — Render an agent profile into Codex CLI's project layout.
#
# Codex's repo-level surface is intentionally thin:
#   AGENTS.md        — primary instruction file (native)
#   .codex/          — not a Codex convention; we use it only as a
#                      sidecar for hooks/skills/commands we have to
#                      inline (so they're co-located with AGENTS.md
#                      and easy to inspect/version).
#
# Codex has no native concept of subagents, slash commands, hooks, or
# project-scope MCPs. The strategy: agents/skills get inlined into
# AGENTS.md when their `fallback` is "inline"; commands and hooks are
# logged as warnings and skipped.

set -euo pipefail

codex_render() {
    local merged_json="$1" target="$2"
    local profile; profile=$(jq -r '.name' <<<"$merged_json")

    _codex_warn_unsupported "$merged_json"

    # Build a list of "title:tmpfile" pairs for ap_build_agents_md_body
    # to splice into the AGENTS.md block alongside the profile's own
    # markdown.
    local inline_args=()
    local cleanup=()

    _codex_collect_inline_agents "$merged_json" inline_args cleanup
    _codex_collect_inline_skills "$merged_json" inline_args cleanup

    local body
    body=$(ap_build_agents_md_body "$merged_json" "${inline_args[@]}")
    if [[ -n "$body" ]]; then
        local out="$target/AGENTS.md"
        ap_splice_agents_md "$out" "$profile" "$body"
        _AP_AGENTS_MD_FILES+=("${out#"$target"/}")
    fi

    # Best-effort: tmpfiles from the collectors above.
    local f
    for f in "${cleanup[@]+"${cleanup[@]}"}"; do rm -f "$f"; done
}

_codex_warn_unsupported() {
    local merged_json="$1"
    local has
    has=$(jq -r '(.commands | length) > 0' <<<"$merged_json")
    if [[ "$has" == "true" ]]; then echo "    codex: slash commands not supported, skipping" >&2; fi
    has=$(jq -r '[.hooks[] | select((.harnesses // ["claude"]) | index("codex"))] | length > 0' <<<"$merged_json")
    if [[ "$has" == "true" ]]; then echo "    codex: hooks not supported, skipping" >&2; fi
    has=$(jq -r '(.mcps | length) > 0' <<<"$merged_json")
    if [[ "$has" == "true" ]]; then echo "    codex: project-scope MCPs not supported; user-scope MCPs come from agents/mcp/registry.yaml" >&2; fi
    return 0
}

# Inline agents: build a per-agent tmpfile that becomes a section
# titled "Agent: <name>" inside AGENTS.md. We respect fallback=="skip"
# (omit silently) and fallback=="inline" (include).
_codex_collect_inline_agents() {
    local merged_json="$1"
    # shellcheck disable=SC2178  # nameref to an array in the caller
    local -n _args=$2
    # shellcheck disable=SC2178
    local -n _cleanup=$3

    local count; count=$(jq -r '.agents | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".agents[$i]" <<<"$merged_json")
        local fb; fb=$(jq -r '.fallback // "skip"' <<<"$item")
        if [[ "$fb" != "inline" ]]; then i=$((i+1)); continue; fi

        local name desc body_path source_dir
        name=$(       jq -r '.name'              <<<"$item")
        desc=$(       jq -r '.description // ""' <<<"$item")
        body_path=$(  jq -r '.body_path // ""'   <<<"$item")
        source_dir=$( jq -r '._source_dir'       <<<"$item")

        local tmp; tmp=$(mktemp)
        if [[ -n "$desc" ]]; then printf '%s\n\n' "$desc" >> "$tmp"; fi
        if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
            cat "$source_dir/$body_path" >> "$tmp"
        fi
        _args+=("Agent: $name" "$tmp")
        _cleanup+=("$tmp")
        i=$((i + 1))
    done
}

_codex_collect_inline_skills() {
    local merged_json="$1"
    # shellcheck disable=SC2178  # nameref to an array in the caller
    local -n _args=$2
    # shellcheck disable=SC2178
    local -n _cleanup=$3

    local count; count=$(jq -r '.skills | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".skills[$i]" <<<"$merged_json")
        local fb; fb=$(jq -r '.fallback // "skip"' <<<"$item")
        if [[ "$fb" != "inline" ]]; then i=$((i+1)); continue; fi

        local name path source_dir
        name=$(      jq -r '.name'         <<<"$item")
        path=$(      jq -r '.path // ""'   <<<"$item")
        source_dir=$(jq -r '._source_dir'  <<<"$item")

        local skill_md="$source_dir/$path/SKILL.md"
        if [[ ! -f "$skill_md" ]]; then i=$((i+1)); continue; fi

        local tmp; tmp=$(mktemp)
        # Strip frontmatter so the section is readable inline.
        awk 'BEGIN{state=0}
             state==0 && /^---$/ {state=1; next}
             state==1 && /^---$/ {state=2; next}
             state==1 {next}
             {print}' "$skill_md" > "$tmp"
        _args+=("Skill: $name" "$tmp")
        _cleanup+=("$tmp")
        i=$((i + 1))
    done
}

codex_clean() {
    : # AGENTS.md stripping is handled by ap_strip_agents_md in the CLI.
}
