#!/usr/bin/env bash
# claude.sh — Render an agent profile as a Claude Code native plugin.
#
# Layout (under <target>):
#   .claude/plugins/local/<profile>/
#     plugin.json                       (curd-spec marker manifest at root)
#     .claude-plugin/plugin.json        (manifest Claude actually loads)
#     agents/<name>.md                  (subagent files, plugin-scoped)
#     skills/<name>/SKILL.md            (skill trees, copied from profile)
#     commands/<name>.md                (slash commands)
#     hooks/<script>                    (hook scripts; event wiring lives
#                                        in .claude-plugin/plugin.json)
#     .mcp.json                         (mcpServers for harnesses⊇claude)
#     settings.json                     (permissions.allow from manifest)
#
# Plus the cross-harness shared path:
#   .claude/agents/<name>.md            (also read by opencode + Cursor;
#                                        emitted via ap_write_shared_claude_agent)
#
# models.claude: when set on an agent or command, emit `model: <value>`
# in YAML frontmatter for that file (plugin-scoped only; the shared
# .claude/agents/<n>.md stays neutral so opencode/Cursor read it cleanly).

set -euo pipefail

claude_render() {
    local merged_json="$1" target="$2"
    local profile desc
    profile=$(jq -r '.name' <<<"$merged_json")
    desc=$(jq -r '.description // ""' <<<"$merged_json")

    local plugin_dir="$target/.claude/plugins/local/$profile"
    mkdir -p "$plugin_dir/.claude-plugin" "$plugin_dir/agents" \
             "$plugin_dir/skills" "$plugin_dir/commands" "$plugin_dir/hooks"

    _claude_write_manifests   "$merged_json" "$target" "$profile" "$desc"
    _claude_write_agents      "$merged_json" "$target" "$profile"
    _claude_write_skills      "$merged_json" "$target" "$profile"
    _claude_write_commands    "$merged_json" "$target" "$profile"
    _claude_write_hooks       "$merged_json" "$target" "$profile"
    _claude_write_mcp_json    "$merged_json" "$target" "$profile"
    _claude_write_settings    "$merged_json" "$target" "$profile"
}

# Track a file relative to <target>, deduping.
_claude_track() {
    local target="$1" abs="$2"
    local rel="${abs#"$target"/}"
    local f
    for f in "${_AP_OUT_FILES[@]+"${_AP_OUT_FILES[@]}"}"; do
        [[ "$f" == "$rel" ]] && return 0
    done
    _AP_OUT_FILES+=("$rel")
}

# Curd-spec marker at plugin root + the manifest Claude actually reads.
_claude_write_manifests() {
    local merged_json="$1" target="$2" profile="$3" desc="$4"
    local plugin_dir="$target/.claude/plugins/local/$profile"
    local manifest
    manifest=$(jq -n \
        --arg name "$profile" --arg desc "$desc" \
        '{name:$name, version:"1.0.0", description:$desc}')
    printf '%s\n' "$manifest" > "$plugin_dir/plugin.json"
    printf '%s\n' "$manifest" > "$plugin_dir/.claude-plugin/plugin.json"
    _claude_track "$target" "$plugin_dir/plugin.json"
    _claude_track "$target" "$plugin_dir/.claude-plugin/plugin.json"
}

# Each agent lands at plugin agents/<n>.md (plugin-discoverable) AND
# .claude/agents/<n>.md via the shared writer (opencode/Cursor read this).
# models.claude → plugin-local frontmatter override; shared stays neutral.
_claude_write_agents() {
    local merged_json="$1" target="$2" profile="$3"
    local plugin_dir="$target/.claude/plugins/local/$profile"
    local count; count=$(jq -r '.agents | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".agents[$i]" <<<"$merged_json")
        local name desc tools body_path source_dir model
        name=$(       jq -r '.name'                          <<<"$item")
        desc=$(       jq -r '.description // ""'             <<<"$item")
        tools=$(      jq -r '(.tools // []) | join(", ")'    <<<"$item")
        body_path=$(  jq -r '.body_path // ""'               <<<"$item")
        source_dir=$( jq -r '._source_dir'                   <<<"$item")
        model=$(      jq -r '.models.claude // ""'           <<<"$item")

        local body_abs=""
        [[ -n "$body_path" && -f "$source_dir/$body_path" ]] && body_abs="$source_dir/$body_path"

        # Plugin-scoped agent file (with optional model frontmatter).
        local out="$plugin_dir/agents/${name}.md"
        {
            printf -- '---\n'
            printf 'name: %s\n' "$name"
            [[ -n "$desc" ]]  && printf 'description: %s\n' "$desc"
            [[ -n "$tools" ]] && printf 'tools: %s\n' "$tools"
            [[ -n "$model" ]] && printf 'model: %s\n' "$model"
            printf -- '---\n\n'
            [[ -n "$body_abs" ]] && cat "$body_abs"
        } > "$out"
        _claude_track "$target" "$out"

        # Cross-harness shared write (no model frontmatter — neutral body
        # for opencode/Cursor; Claude reads its own plugin-scoped copy).
        if [[ -n "$body_abs" ]]; then
            local fm
            fm=$(jq -n \
                --arg name "$name" --arg desc "$desc" --arg tools "$tools" \
                '{name:$name}
                 + (if $desc != "" then {description:$desc} else {} end)
                 + (if $tools != "" then {tools:$tools} else {} end)')
            ap_write_shared_claude_agent "$target" "$name" "$body_abs" "$fm"
        fi
        i=$((i + 1))
    done
}

# Skills copy as full trees into plugin skills/<n>/.
_claude_write_skills() {
    local merged_json="$1" target="$2" profile="$3"
    local plugin_dir="$target/.claude/plugins/local/$profile"
    local count; count=$(jq -r '.skills | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".skills[$i]" <<<"$merged_json")
        local name path source_dir
        name=$(      jq -r '.name'         <<<"$item")
        path=$(      jq -r '.path // ""'   <<<"$item")
        source_dir=$(jq -r '._source_dir'  <<<"$item")
        local src="$source_dir/$path"
        local dst="$plugin_dir/skills/${name}"
        if [[ -d "$src" ]]; then
            rm -rf "$dst"
            cp -R "$src" "$dst"
            _claude_track "$target" "$dst"
        fi
        i=$((i + 1))
    done
}

_claude_write_commands() {
    local merged_json="$1" target="$2" profile="$3"
    local plugin_dir="$target/.claude/plugins/local/$profile"
    local count; count=$(jq -r '.commands | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".commands[$i]" <<<"$merged_json")
        local name desc body_path source_dir model
        name=$(       jq -r '.name'               <<<"$item")
        desc=$(       jq -r '.description // ""'  <<<"$item")
        body_path=$(  jq -r '.body_path // ""'    <<<"$item")
        source_dir=$( jq -r '._source_dir'        <<<"$item")
        model=$(      jq -r '.models.claude // ""' <<<"$item")

        local out="$plugin_dir/commands/${name}.md"
        {
            if [[ -n "$desc" || -n "$model" ]]; then
                printf -- '---\n'
                [[ -n "$desc" ]]  && printf 'description: %s\n' "$desc"
                [[ -n "$model" ]] && printf 'model: %s\n' "$model"
                printf -- '---\n\n'
            fi
            [[ -n "$body_path" && -f "$source_dir/$body_path" ]] && cat "$source_dir/$body_path"
        } > "$out"
        _claude_track "$target" "$out"
        i=$((i + 1))
    done
}

# Hooks scoped to harness=claude only. Scripts land under plugin hooks/;
# event wiring is merged into .claude-plugin/plugin.json's `hooks` field
# (Claude reads this inline shape per docs).
_claude_write_hooks() {
    local merged_json="$1" target="$2" profile="$3"
    local plugin_dir="$target/.claude/plugins/local/$profile"
    local manifest="$plugin_dir/.claude-plugin/plugin.json"
    local root_manifest="$plugin_dir/plugin.json"
    local count; count=$(jq -r '.hooks | length' <<<"$merged_json")
    local i=0 wrote_any=0
    local hook_entries='{}'
    while (( i < count )); do
        local item; item=$(jq -c ".hooks[$i]" <<<"$merged_json")
        local harnesses
        harnesses=$(jq -r '(.harnesses // ["claude"]) | join(",")' <<<"$item")
        case ",$harnesses," in *,claude,*) ;; *) i=$((i+1)); continue ;; esac

        local event matcher script source_dir
        event=$(     jq -r '.event'         <<<"$item")
        matcher=$(   jq -r '.matcher // ""' <<<"$item")
        script=$(    jq -r '.script // ""'  <<<"$item")
        source_dir=$(jq -r '._source_dir'   <<<"$item")
        local src="$source_dir/$script"
        [[ -f "$src" ]] || { i=$((i+1)); continue; }

        local basename; basename=$(basename "$script")
        local dst="$plugin_dir/hooks/$basename"
        cp "$src" "$dst"
        chmod +x "$dst"
        _claude_track "$target" "$dst"

        # Append the matcher/command tuple under the event key.
        hook_entries=$(jq \
            --arg event "$event" \
            --arg matcher "$matcher" \
            --arg cmd "\${CLAUDE_PLUGIN_ROOT}/hooks/$basename" \
            '
            .[$event] = ((.[$event] // []) + [{
                matcher: $matcher,
                hooks: [{type:"command", command:$cmd}]
            }])
            ' <<<"$hook_entries")
        wrote_any=1
        i=$((i + 1))
    done

    [[ "$wrote_any" -eq 1 ]] || return 0

    # Merge hook entries into both manifests so the on-disk JSON Claude
    # reads (.claude-plugin/plugin.json) gets the wiring; the root
    # marker stays in sync for inspection.
    local mf
    for mf in "$manifest" "$root_manifest"; do
        local tmp; tmp=$(mktemp)
        jq --argjson h "$hook_entries" '.hooks = $h' "$mf" > "$tmp" && mv "$tmp" "$mf"
    done
}

# .mcp.json at plugin root. Whole-file artefact owned by this profile —
# tracked in _AP_OUT_FILES so uninstall rms it. The pre-reshape merge
# logic against a target-root .mcp.json is dropped (each plugin owns its
# own; ref-counting across plugins is unnecessary).
_claude_write_mcp_json() {
    local merged_json="$1" target="$2" profile="$3"
    local plugin_dir="$target/.claude/plugins/local/$profile"
    local mcps_filtered
    mcps_filtered=$(jq -c '
        [.mcps[] | select(
            (.harnesses // ["claude","codex","opencode"])
            | index("claude") != null
        )]
    ' <<<"$merged_json")
    [[ "$(jq 'length' <<<"$mcps_filtered")" -eq 0 ]] && return 0

    local out="$plugin_dir/.mcp.json"
    jq -n --argjson mcps "$mcps_filtered" '
        {mcpServers:
            ($mcps | map({(.name): (
                {command:.command}
                + (if .args then {args:.args} else {} end)
                + (if .env  then {env:.env}   else {} end)
            )}) | add // {})
        }
    ' > "$out"
    _claude_track "$target" "$out"
}

# settings.json with just permissions.allow. Whole-file artefact owned
# by this plugin.
_claude_write_settings() {
    local merged_json="$1" target="$2" profile="$3"
    local plugin_dir="$target/.claude/plugins/local/$profile"
    local allow_json
    allow_json=$(jq -c '(.settings.permissions_allow // [])' <<<"$merged_json")
    [[ "$(jq 'length' <<<"$allow_json")" -eq 0 ]] && return 0
    local out="$plugin_dir/settings.json"
    jq -n --argjson allow "$allow_json" '{permissions:{allow:$allow}}' > "$out"
    _claude_track "$target" "$out"
}

# Uninstall: every file we wrote (including the shared
# .claude/agents/<n>.md entries and the plugin dir tree) is tracked in
# _AP_OUT_FILES at install time and recorded in the manifest. The CLI's
# rm pass handles them — claude_clean has no merged-file surgery to
# perform (no shared .claude/settings.local.json or root .mcp.json under
# the new layout).
claude_clean() {
    :
}
