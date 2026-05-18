#!/usr/bin/env bash
# opencode.sh — Render an agent profile into opencode's project layout.
#
# Writes:
#   AGENTS.md                         (marker block — opencode's primary)
#   .opencode/agent/<profile>--<n>.md (subagents, opencode supports these)
#   .opencode/command/<profile>--<n>.md
#   opencode.json                     (merge mcp + permissions)
#
# Hooks: opencode has no native pre-tool-call hook surface; we skip
# with a warning, same shape as the codex renderer.

set -euo pipefail

opencode_render() {
    local merged_json="$1" target="$2"
    local profile; profile=$(jq -r '.name' <<<"$merged_json")

    mkdir -p "$target/.opencode/agent" "$target/.opencode/command"

    _opencode_warn_unsupported "$merged_json"

    _opencode_write_agents     "$merged_json" "$target" "$profile"
    _opencode_write_commands   "$merged_json" "$target" "$profile"
    _opencode_write_opencode_json "$merged_json" "$target" "$profile"
    _opencode_write_agents_md  "$merged_json" "$target" "$profile"
}

_opencode_warn_unsupported() {
    local merged_json="$1"
    local has
    has=$(jq -r '[.hooks[] | select((.harnesses // ["claude"]) | index("opencode"))] | length > 0' <<<"$merged_json")
    if [[ "$has" == "true" ]]; then echo "    opencode: hooks not supported, skipping" >&2; fi
    has=$(jq -r '(.skills | length) > 0' <<<"$merged_json")
    if [[ "$has" == "true" ]]; then echo "    opencode: skills inline into AGENTS.md (opencode has no native skills concept)" >&2; fi
    return 0
}

_opencode_write_agents() {
    local merged_json="$1" target="$2" profile="$3"
    local count; count=$(jq -r '.agents | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".agents[$i]" <<<"$merged_json")
        local name desc body_path source_dir
        name=$(       jq -r '.name'              <<<"$item")
        desc=$(       jq -r '.description // ""' <<<"$item")
        body_path=$(  jq -r '.body_path // ""'   <<<"$item")
        source_dir=$( jq -r '._source_dir'       <<<"$item")

        local out="$target/.opencode/agent/${profile}--${name}.md"
        {
            printf -- '---\n'
            [[ -n "$desc" ]] && printf 'description: %s\n' "$desc"
            printf 'mode: subagent\n'
            printf -- '---\n\n'
            if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
                cat "$source_dir/$body_path"
            fi
        } > "$out"
        _AP_OUT_FILES+=("${out#"$target"/}")
        i=$((i + 1))
    done
}

_opencode_write_commands() {
    local merged_json="$1" target="$2" profile="$3"
    local count; count=$(jq -r '.commands | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".commands[$i]" <<<"$merged_json")
        local name desc body_path source_dir
        name=$(       jq -r '.name'              <<<"$item")
        desc=$(       jq -r '.description // ""' <<<"$item")
        body_path=$(  jq -r '.body_path // ""'   <<<"$item")
        source_dir=$( jq -r '._source_dir'       <<<"$item")

        local out="$target/.opencode/command/${profile}--${name}.md"
        {
            if [[ -n "$desc" ]]; then
                printf -- '---\n'
                printf 'description: %s\n' "$desc"
                printf -- '---\n\n'
            fi
            if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
                cat "$source_dir/$body_path"
            fi
        } > "$out"
        _AP_OUT_FILES+=("${out#"$target"/}")
        i=$((i + 1))
    done
}

# opencode.json merge: mcp servers + permissions.bash allow list.
#
# Permission translation: Claude's `Bash(cargo:*)` syntax does not map
# cleanly to opencode's shell-pattern `permission.bash` keys. We do a
# best-effort translation for the common `Bash(<prefix>:*)` form
# ("cargo *") and leave anything else as-is with a warning.
_opencode_write_opencode_json() {
    local merged_json="$1" target="$2" profile="$3"
    local mcps_filtered
    mcps_filtered=$(jq -c '
        [.mcps[] | select(
            (.harnesses // ["claude", "codex", "opencode"])
            | index("opencode") != null
        )]
    ' <<<"$merged_json")
    local allow_json
    allow_json=$(jq -c '
        [(.settings.permissions_allow // [])[] as $p
         | if ($p | test("^Bash\\([^:)]+:\\*\\)$"))
           then ($p | capture("^Bash\\((?<cmd>[^:)]+):\\*\\)$") | .cmd + " *")
           else $p end]
    ' <<<"$merged_json")

    local has_mcps has_allow
    has_mcps=$(jq -r 'length' <<<"$mcps_filtered")
    has_allow=$(jq -r 'length' <<<"$allow_json")
    (( has_mcps > 0 || has_allow > 0 )) || return 0

    local out="$target/opencode.json"
    # shellcheck disable=SC2016  # JSON literal key "$schema", not a shell var
    [[ -f "$out" ]] || echo '{"$schema": "https://opencode.ai/config.json"}' > "$out"

    local tmp; tmp=$(mktemp)
    jq \
        --argjson mcps  "$mcps_filtered" \
        --argjson allow "$allow_json" \
        '
        if ($mcps | length) > 0 then
            .mcp = (.mcp // {})
            | reduce $mcps[] as $m (.;
                .mcp[$m.name] = (
                    {type: "local", enabled: true, command: ([$m.command] + ($m.args // []))}
                    + (if $m.env then {environment: $m.env} else {} end)
                )
              )
        else . end
        | if ($allow | length) > 0 then
              .permission = (.permission // {})
              | .permission.bash = (.permission.bash // {})
              | reduce $allow[] as $a (.;
                    .permission.bash[$a] = "allow"
                )
          else . end
        ' "$out" > "$tmp" && mv "$tmp" "$out"
    # Merged file — uninstall handled by opencode_clean.
}

_opencode_write_agents_md() {
    local merged_json="$1" target="$2" profile="$3"
    # Inline skills (opencode has no native skill concept).
    local inline_args=() cleanup=()
    local count; count=$(jq -r '.skills | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".skills[$i]" <<<"$merged_json")
        local name path source_dir
        name=$(      jq -r '.name'         <<<"$item")
        path=$(      jq -r '.path // ""'   <<<"$item")
        source_dir=$(jq -r '._source_dir'  <<<"$item")
        local skill_md="$source_dir/$path/SKILL.md"
        [[ -f "$skill_md" ]] || { i=$((i+1)); continue; }
        local tmp; tmp=$(mktemp)
        awk 'BEGIN{s=0}
             s==0 && /^---$/ {s=1; next}
             s==1 && /^---$/ {s=2; next}
             s==1 {next}
             {print}' "$skill_md" > "$tmp"
        inline_args+=("Skill: $name" "$tmp")
        cleanup+=("$tmp")
        i=$((i + 1))
    done

    local body; body=$(ap_build_agents_md_body "$merged_json" "${inline_args[@]+"${inline_args[@]}"}")
    if [[ -n "$body" ]]; then
        local out="$target/AGENTS.md"
        ap_splice_agents_md "$out" "$profile" "$body"
        _AP_AGENTS_MD_FILES+=("${out#"$target"/}")
    fi

    local f; for f in "${cleanup[@]+"${cleanup[@]}"}"; do rm -f "$f"; done
}

opencode_clean() {
    local merged_json="$1" target="$2"
    local cfg="$target/opencode.json"
    [[ -f "$cfg" ]] || return 0

    local mcp_names allow_json
    mcp_names=$(jq -c '
        [.mcps[] | select(
            (.harnesses // ["claude","codex","opencode"])
            | index("opencode") != null
        ) | .name]
    ' <<<"$merged_json")
    allow_json=$(jq -c '
        [(.settings.permissions_allow // [])[] as $p
         | if ($p | test("^Bash\\([^:)]+:\\*\\)$"))
           then ($p | capture("^Bash\\((?<cmd>[^:)]+):\\*\\)$") | .cmd + " *")
           else $p end]
    ' <<<"$merged_json")

    local tmp; tmp=$(mktemp)
    jq \
        --argjson mcps  "$mcp_names" \
        --argjson allow "$allow_json" \
        '
        .mcp = (
            (.mcp // {})
            | with_entries(select(.key as $k | $mcps | index($k) | not))
        )
        | if .mcp == {} then del(.mcp) else . end
        | .permission = (
            (.permission // {})
            | .bash = (
                (.bash // {})
                | with_entries(select(.key as $k | $allow | index($k) | not))
            )
            | if .bash == {} then del(.bash) else . end
        )
        | if .permission == {} then del(.permission) else . end
        ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}
