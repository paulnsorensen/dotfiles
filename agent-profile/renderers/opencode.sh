#!/usr/bin/env bash
# opencode.sh — Render an agent profile into opencode's project layout.
#
# Writes (default case, no models.opencode override):
#   .claude/agents/<n>.md         (shared path — opencode reads natively)
#   .agents/skills/<n>/SKILL.md   (shared path — opencode reads natively)
#   .opencode/commands/<n>.md     (plural per docs)
#   opencode.json                 (merge mcp + permissions)
#
# Override case (per-agent `models.opencode` set):
#   .opencode/agent/<n>.md        (singular, with `model:` frontmatter)
#
# Hooks: opencode's hook surface is TS plugins only, so we skip with a
# warning. AGENTS.md is owned by chezmoi globally and never edited from
# the per-repo profile system.

set -euo pipefail

opencode_render() {
    local merged_json="$1" target="$2"

    _opencode_warn_unsupported "$merged_json"

    _opencode_write_agents        "$merged_json" "$target"
    _opencode_write_skills        "$merged_json" "$target"
    _opencode_write_commands      "$merged_json" "$target"
    _opencode_write_opencode_json "$merged_json" "$target"
}

_opencode_warn_unsupported() {
    local merged_json="$1"
    local has
    has=$(jq -r '[.hooks[] | select((.harnesses // ["claude"]) | index("opencode"))] | length > 0' <<<"$merged_json")
    if [[ "$has" == "true" ]]; then echo "    opencode: hooks not supported (TS plugins only), skipping" >&2; fi
    return 0
}

# Default: write the cross-harness shared `.claude/agents/<n>.md`.
# Override: if `models.opencode` is set (and not "inherit"), write
# `.opencode/agent/<n>.md` instead — opencode picks its own override.
_opencode_write_agents() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.agents | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".agents[$i]" <<<"$merged_json")
        local name body_path source_dir model
        name=$(       jq -r '.name'                      <<<"$item")
        body_path=$(  jq -r '.body_path // ""'           <<<"$item")
        source_dir=$( jq -r '._source_dir'               <<<"$item")
        model=$(      jq -r '.models.opencode // empty'  <<<"$item")

        local body_abs=""
        if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
            body_abs="$source_dir/$body_path"
        fi
        [[ -n "$body_abs" ]] || { ((++i)); continue; }

        if [[ -n "$model" && "$model" != "inherit" ]]; then
            # opencode singular `.opencode/agent/<n>.md` override.
            ap_render_model_override "$target" opencode agent_singular \
                "$name" "$body_abs" "$model"
        else
            # Shared `.claude/agents/<n>.md` — opencode reads natively.
            local fm
            fm=$(jq -c '{
                name:        .name,
                description: (.description // ""),
                tools:       ((.tools // []) | join(", ")),
                mode:        "subagent"
            } | with_entries(select(.value != "" and .value != null))' <<<"$item")
            ap_write_shared_claude_agent "$target" "$name" "$body_abs" "$fm"
        fi
        ((++i))
    done
}

# Skills: copy the entire skill tree to the shared `.agents/skills/<n>/`
# path. Codex, opencode, and Cursor all read this location.
_opencode_write_skills() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.skills | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".skills[$i]" <<<"$merged_json")
        local name path source_dir
        name=$(      jq -r '.name'         <<<"$item")
        path=$(      jq -r '.path // ""'   <<<"$item")
        source_dir=$(jq -r '._source_dir'  <<<"$item")
        if [[ -n "$path" && -d "$source_dir/$path" ]]; then
            ap_copy_shared_skill "$target" "$name" "$source_dir/$path"
        fi
        ((++i))
    done
}

# Slash commands → `.opencode/commands/<n>.md` (plural, per docs).
# When `models.opencode` is set on a command, include `model:` in the
# frontmatter via the shared override writer.
_opencode_write_commands() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.commands | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".commands[$i]" <<<"$merged_json")
        local name desc body_path source_dir model
        name=$(       jq -r '.name'                      <<<"$item")
        desc=$(       jq -r '.description // ""'         <<<"$item")
        body_path=$(  jq -r '.body_path // ""'           <<<"$item")
        source_dir=$( jq -r '._source_dir'               <<<"$item")
        model=$(      jq -r '.models.opencode // empty'  <<<"$item")

        local body_abs=""
        if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
            body_abs="$source_dir/$body_path"
        fi
        [[ -n "$body_abs" ]] || { ((++i)); continue; }

        if [[ -n "$model" && "$model" != "inherit" ]]; then
            ap_render_model_override "$target" opencode command \
                "$name" "$body_abs" "$model"
        else
            local out_rel=".opencode/commands/${name}.md"
            local out="$target/$out_rel"
            mkdir -p "$(dirname "$out")"
            {
                if [[ -n "$desc" ]]; then
                    printf -- '---\n'
                    printf 'description: %s\n' "$desc"
                    printf -- '---\n\n'
                fi
                cat "$body_abs"
            } > "$out"
            _AP_OUT_FILES+=("$out_rel")
        fi
        ((++i))
    done
}

# opencode.json merge: mcp servers + permissions.bash allow list.
#
# Permission translation: Claude's `Bash(<cmd>:*)` syntax does not map
# perfectly onto opencode's shell-pattern `permission.bash` keys. We do
# a best-effort translation of the common prefix form (`Bash(cargo:*)`
# → `cargo *`) and leave anything else as-is. Anything more elaborate
# (e.g. `Bash(git push origin main)`) will not round-trip correctly —
# the user gets the raw Claude string in the file and may need to edit
# by hand. This limitation is intentional; opencode's bash-pattern
# surface is a shell glob, not a Claude permission expression.
_opencode_write_opencode_json() {
    local merged_json="$1" target="$2"
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
    # Merged file — uninstall handled by opencode_clean (surgical edit).
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

    # If we bootstrapped opencode.json (no pre-existing user content),
    # uninstall should leave a clean target. After the surgical edit
    # above the file contains only the schema stub we wrote in
    # `_opencode_write_opencode_json`. Treat that exact shape as
    # "owned by this profile" and remove the file.
    local remaining_keys schema_only
    remaining_keys=$(jq -c 'keys' "$cfg")
    # shellcheck disable=SC2016  # JSON literal — single quotes intentional
    schema_only='["$schema"]'
    if [[ "$remaining_keys" == "$schema_only" ]]; then
        rm -f "$cfg"
    fi
}
