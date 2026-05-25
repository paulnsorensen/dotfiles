#!/usr/bin/env bash
# cursor.sh — Render an agent profile into Cursor's project layout.
#
# Cursor reads two cross-harness shared paths natively:
#   .claude/agents/<n>.md       — subagent body (Cursor + Claude + opencode)
#   .agents/skills/<n>/SKILL.md — skill tree (Cursor + Codex + opencode)
#
# We delegate those writes to `ap_write_shared_claude_agent` and
# `ap_copy_shared_skill` from `lib/shared_writer.sh` — each profile only
# pays the write cost once per artefact regardless of how many harnesses
# consume it.
#
# Cursor-specific surfaces:
#   .cursor/commands/<n>.md     — slash commands (per Cursor docs)
#   .cursor/hooks.json          — JSON array of hook entries (22 events)
#   .cursor/mcp.json            — {mcpServers: {...}} (merge with user)
#   .cursor/agents/<n>.md       — only when `models.cursor` is a real
#                                 value (not `inherit` or absent), as a
#                                 per-harness model override.
#
# Permissions are UI-only on Cursor — skipped with a warning.
# AGENTS.md is owned globally by chezmoi — never touched here.

set -euo pipefail

cursor_render() {
    local merged_json="$1" target="$2"

    _cursor_warn_unsupported "$merged_json"

    _cursor_write_agents   "$merged_json" "$target"
    _cursor_write_skills   "$merged_json" "$target"
    _cursor_write_commands "$merged_json" "$target"
    _cursor_write_hooks    "$merged_json" "$target"
    _cursor_write_mcp_json "$merged_json" "$target"
}

_cursor_warn_unsupported() {
    local merged_json="$1"
    local has
    has=$(jq -r '(.settings.permissions_allow // []) | length > 0' <<<"$merged_json")
    if [[ "$has" == "true" ]]; then
        echo "    cursor: permissions are UI-only, skipping permission entries" >&2
    fi
    return 0
}

# Subagents: always write the shared `.claude/agents/<n>.md`. If a
# `models.cursor` override is set and not the `inherit` sentinel, also
# write `.cursor/agents/<n>.md` with `model:` frontmatter — Cursor's
# precedence rules pick up the cursor-specific file for cursor sessions
# while other harnesses keep reading the shared one.
_cursor_write_agents() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.agents | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".agents[$i]" <<<"$merged_json")
        local name body_path source_dir frontmatter_json model
        name=$(       jq -r '.name'                      <<<"$item")
        body_path=$(  jq -r '.body_path // ""'           <<<"$item")
        source_dir=$( jq -r '._source_dir'               <<<"$item")
        model=$(      jq -r '.models.cursor // ""'       <<<"$item")
        frontmatter_json=$(jq -c '
            {
              name: .name,
              description: (.description // ""),
              tools: (if (.tools // [] | length) > 0 then (.tools | join(", ")) else empty end)
            }
            | with_entries(select(.value != "" and .value != null))
        ' <<<"$item")

        if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
            ap_write_shared_claude_agent "$target" "$name" "$source_dir/$body_path" "$frontmatter_json"
            if [[ -n "$model" && "$model" != "inherit" ]]; then
                ap_render_model_override "$target" cursor agent "$name" "$source_dir/$body_path" "$model"
            fi
        fi
        ((++i))
    done
}

_cursor_write_skills() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.skills | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".skills[$i]" <<<"$merged_json")
        local name path source_dir src
        name=$(      jq -r '.name'         <<<"$item")
        path=$(      jq -r '.path // ""'   <<<"$item")
        source_dir=$(jq -r '._source_dir'  <<<"$item")
        src="$source_dir/$path"
        if [[ -n "$path" && -d "$src" ]]; then
            ap_copy_shared_skill "$target" "$name" "$src"
        fi
        ((++i))
    done
}

_cursor_write_commands() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.commands | length' <<<"$merged_json")
    (( count > 0 )) || return 0
    mkdir -p "$target/.cursor/commands"
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".commands[$i]" <<<"$merged_json")
        local name desc body_path source_dir model
        name=$(       jq -r '.name'              <<<"$item")
        desc=$(       jq -r '.description // ""' <<<"$item")
        body_path=$(  jq -r '.body_path // ""'   <<<"$item")
        source_dir=$( jq -r '._source_dir'       <<<"$item")
        model=$(      jq -r '.models.cursor // ""' <<<"$item")

        local out="$target/.cursor/commands/${name}.md"
        {
            # Emit frontmatter when we have anything to declare.
            if [[ -n "$desc" || ( -n "$model" && "$model" != "inherit" ) ]]; then
                printf -- '---\n'
                [[ -n "$desc" ]] && printf 'description: %s\n' "$desc"
                if [[ -n "$model" && "$model" != "inherit" ]]; then
                    printf 'model: %s\n' "$model"
                fi
                printf -- '---\n\n'
            fi
            if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
                cat "$source_dir/$body_path"
            fi
        } > "$out"
        _AP_OUT_FILES+=("${out#"$target"/}")
        ((++i))
    done
}

# Cursor hooks: JSON array of {event, matcher, command} objects.
# Only hooks whose `harnesses` includes `cursor` land here; if none
# qualify, no file is written.
_cursor_write_hooks() {
    local merged_json="$1" target="$2"
    local hooks_json
    hooks_json=$(jq -c '
        [.hooks[]
         | select((.harnesses // ["claude"]) | index("cursor") != null)
         | {
             event: .event,
             matcher: (.matcher // ""),
             command: (.script // "")
           }
        ]
    ' <<<"$merged_json")

    local count; count=$(jq -r 'length' <<<"$hooks_json")
    (( count > 0 )) || return 0

    mkdir -p "$target/.cursor"
    local out="$target/.cursor/hooks.json"

    # Copy each hook script into .cursor/hooks/ so its path resolves
    # inside the target dir.
    mkdir -p "$target/.cursor/hooks"
    local resolved='[]'
    local i=0
    while (( i < count )); do
        local h; h=$(jq -c ".[$i]" <<<"$hooks_json")
        local script_rel src dest_rel
        script_rel=$(jq -r '.command' <<<"$h")
        # The merged manifest preserves the original `_source_dir` per
        # hook item — pull it back so we can copy the script.
        local source_dir
        source_dir=$(jq -r --argjson idx "$i" '
            [.hooks[] | select((.harnesses // ["claude"]) | index("cursor") != null)][$idx]._source_dir
        ' <<<"$merged_json")
        src="$source_dir/$script_rel"
        if [[ ! -f "$src" ]]; then
            echo "cursor_render: hook script not found: $src" >&2
            return 1
        fi
        local base; base=$(basename "$script_rel")
        cp "$src" "$target/.cursor/hooks/$base"
        chmod +x "$target/.cursor/hooks/$base"
        dest_rel=".cursor/hooks/$base"
        _AP_OUT_FILES+=("$dest_rel")
        resolved=$(jq -c --argjson h "$h" --arg cmd "$dest_rel" '. + [$h | .command = $cmd]' <<<"$resolved")
        ((++i))
    done

    jq '.' <<<"$resolved" > "$out"
    _AP_OUT_FILES+=(".cursor/hooks.json")
}

# .cursor/mcp.json: {mcpServers: {<name>: {command, args, env}}}.
# Merge into any existing user file, preserving unknown top-level keys
# and entries we didn't add.
_cursor_write_mcp_json() {
    local merged_json="$1" target="$2"
    local mcps_filtered
    mcps_filtered=$(jq -c '
        [.mcps[] | select(
            (.harnesses // ["claude", "codex", "opencode", "cursor"])
            | index("cursor") != null
        )]
    ' <<<"$merged_json")

    local has_mcps; has_mcps=$(jq -r 'length' <<<"$mcps_filtered")
    (( has_mcps > 0 )) || return 0

    mkdir -p "$target/.cursor"
    local out="$target/.cursor/mcp.json"
    [[ -f "$out" ]] || echo '{}' > "$out"

    local tmp; tmp=$(mktemp)
    jq \
        --argjson mcps "$mcps_filtered" \
        '
        .mcpServers = (.mcpServers // {})
        | reduce $mcps[] as $m (.;
            .mcpServers[$m.name] = (
                {command: $m.command, args: ($m.args // [])}
                + (if $m.env then {env: $m.env} else {} end)
            )
          )
        ' "$out" > "$tmp" && mv "$tmp" "$out"
    # Merged file — uninstall handled by cursor_clean.
}

# Surgical undo for the merged `.cursor/mcp.json` — drop only the
# entries this profile added, leave user entries (and unrelated
# top-level keys) intact.
cursor_clean() {
    local merged_json="$1" target="$2"
    local cfg="$target/.cursor/mcp.json"
    [[ -f "$cfg" ]] || return 0

    local mcp_names
    mcp_names=$(jq -c '
        [.mcps[] | select(
            (.harnesses // ["claude","codex","opencode","cursor"])
            | index("cursor") != null
        ) | .name]
    ' <<<"$merged_json")

    local tmp; tmp=$(mktemp)
    jq \
        --argjson mcps "$mcp_names" \
        '
        .mcpServers = (
            (.mcpServers // {})
            | with_entries(select(.key as $k | $mcps | index($k) | not))
        )
        | if .mcpServers == {} then del(.mcpServers) else . end
        ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"

    # Bootstrapped file with no remaining content — clean it up so
    # uninstall on a fresh target leaves nothing behind. The install
    # path seeds `.cursor/mcp.json` with `{}` and then merges entries;
    # an empty `{}` after the surgical removal means we were the only
    # writer.
    if [[ "$(jq -c '.' "$cfg")" == "{}" ]]; then
        rm -f "$cfg"
    fi
}
