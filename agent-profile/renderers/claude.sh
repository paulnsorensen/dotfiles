#!/usr/bin/env bash
# claude.sh — Render an agent profile into Claude Code's project layout.
#
# Writes (under <target>):
#   .claude/agents/<profile>--<name>.md       (subagent definitions)
#   .claude/skills/<profile>--<name>/...      (skill packs, copied)
#   .claude/commands/<profile>--<name>.md     (slash commands)
#   .claude/hooks/<profile>--<name>--<i>.sh   (hook scripts, copied)
#   .claude/settings.local.json               (merged: permissions.allow + hooks)
#   .mcp.json                                 (project-scope MCPs, merged)
#   AGENTS.md                                 (marker block)
#
# Skill / agent / command fallback="inline" entries are folded into the
# AGENTS.md block instead of getting native files — that way harnesses
# without a real skills concept still see the instructions in context.

set -euo pipefail

claude_render() {
    local merged_json="$1" target="$2"
    local profile; profile=$(jq -r '.name' <<<"$merged_json")

    local claude_dir="$target/.claude"
    mkdir -p "$claude_dir/agents" "$claude_dir/skills" \
             "$claude_dir/commands" "$claude_dir/hooks"

    _claude_write_agents     "$merged_json" "$target" "$profile"
    _claude_write_skills     "$merged_json" "$target" "$profile"
    _claude_write_commands   "$merged_json" "$target" "$profile"
    _claude_write_hooks_dir  "$merged_json" "$target" "$profile"
    _claude_write_settings   "$merged_json" "$target" "$profile"
    _claude_write_mcp_json   "$merged_json" "$target" "$profile"
    _claude_write_agents_md  "$merged_json" "$target" "$profile"
}

# ─── agents ────────────────────────────────────────────────────────────
# Native agents go to .claude/agents/<profile>--<name>.md with YAML
# frontmatter. fallback=="inline" entries are deferred to the AGENTS.md
# write step (handled there) so they still surface as guidance.

_claude_write_agents() {
    local merged_json="$1" target="$2" profile="$3"
    local count; count=$(jq -r '.agents | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".agents[$i]" <<<"$merged_json")
        local fb; fb=$(jq -r '.fallback // "skip"' <<<"$item")
        [[ "$fb" == "inline" && "${_CLAUDE_INLINE_NATIVE:-1}" == "0" ]] && { i=$((i+1)); continue; }

        local name desc tools body_path source_dir
        name=$(       jq -r '.name'        <<<"$item")
        desc=$(       jq -r '.description // ""' <<<"$item")
        tools=$(      jq -r '(.tools // []) | join(", ")' <<<"$item")
        body_path=$(  jq -r '.body_path // ""' <<<"$item")
        source_dir=$( jq -r '._source_dir' <<<"$item")

        local out="$target/.claude/agents/${profile}--${name}.md"
        {
            printf -- '---\n'
            printf 'name: %s\n' "$name"
            [[ -n "$desc" ]]  && printf 'description: %s\n' "$desc"
            [[ -n "$tools" ]] && printf 'tools: %s\n' "$tools"
            printf -- '---\n\n'
            if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
                cat "$source_dir/$body_path"
            fi
        } > "$out"
        _AP_OUT_FILES+=("${out#"$target"/}")
        i=$((i + 1))
    done
}

# ─── skills ────────────────────────────────────────────────────────────
# Native skills are full directories — copy the whole tree under
# .claude/skills/<profile>--<name>/. fallback=="inline" entries get
# their SKILL.md text spliced into AGENTS.md instead.

_claude_write_skills() {
    local merged_json="$1" target="$2" profile="$3"
    local count; count=$(jq -r '.skills | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".skills[$i]" <<<"$merged_json")
        local name path source_dir
        name=$(      jq -r '.name'         <<<"$item")
        path=$(      jq -r '.path // ""'   <<<"$item")
        source_dir=$(jq -r '._source_dir'  <<<"$item")

        local src="$source_dir/$path"
        local dst="$target/.claude/skills/${profile}--${name}"
        if [[ -d "$src" ]]; then
            rm -rf "$dst"
            cp -R "$src" "$dst"
            _AP_OUT_FILES+=("${dst#"$target"/}")
        fi
        i=$((i + 1))
    done
}

# ─── commands ──────────────────────────────────────────────────────────

_claude_write_commands() {
    local merged_json="$1" target="$2" profile="$3"
    local count; count=$(jq -r '.commands | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".commands[$i]" <<<"$merged_json")
        local fb; fb=$(jq -r '.fallback // "skip"' <<<"$item")
        local name desc body_path source_dir
        name=$(       jq -r '.name'              <<<"$item")
        desc=$(       jq -r '.description // ""' <<<"$item")
        body_path=$(  jq -r '.body_path // ""'   <<<"$item")
        source_dir=$( jq -r '._source_dir'       <<<"$item")

        local out="$target/.claude/commands/${profile}--${name}.md"
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

# ─── hooks ─────────────────────────────────────────────────────────────
# Two things to do for each hook:
#   1. Copy the script into .claude/hooks/ under a deterministic name
#      so the settings.json command path is stable across machines.
#   2. Track its (event, matcher, command) tuple so the settings writer
#      can fold it into the right hooks.<Event>[] array.

_claude_write_hooks_dir() {
    local merged_json="$1" target="$2" profile="$3"
    local count; count=$(jq -r '.hooks | length' <<<"$merged_json")
    local i=0
    _CLAUDE_HOOK_TUPLES='[]'
    while (( i < count )); do
        local item; item=$(jq -c ".hooks[$i]" <<<"$merged_json")
        # Allow per-hook harness gating; default = [claude].
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

        local script_basename="${profile}--$(basename "$script")"
        local dst="$target/.claude/hooks/$script_basename"
        cp "$src" "$dst"
        chmod +x "$dst"
        _AP_OUT_FILES+=("${dst#"$target"/}")

        # Hook command uses a relative path so .claude/ trees are
        # portable across checkout locations.
        _CLAUDE_HOOK_TUPLES=$(jq \
            --arg event   "$event" \
            --arg matcher "$matcher" \
            --arg cmd     ".claude/hooks/$script_basename" \
            '. + [{event: $event, matcher: $matcher, command: $cmd}]' \
            <<<"$_CLAUDE_HOOK_TUPLES")
        i=$((i + 1))
    done
}

# ─── settings.local.json ───────────────────────────────────────────────
# Project-scope settings file. Permissions.allow gets merged additively
# (unique), hooks.<Event>[] entries get appended (deduped on (matcher,
# command)). Anything else already in the file is preserved.

_claude_write_settings() {
    local merged_json="$1" target="$2" profile="$3"
    local allow_json
    allow_json=$(jq -c '(.settings.permissions_allow // [])' <<<"$merged_json")
    local hooks_json="${_CLAUDE_HOOK_TUPLES:-[]}"

    local out="$target/.claude/settings.local.json"
    [[ -f "$out" ]] || echo '{}' > "$out"

    local tmp; tmp=$(mktemp)
    jq \
        --argjson allow "$allow_json" \
        --argjson hooks "$hooks_json" \
        '
        .permissions = (.permissions // {})
        | .permissions.allow = (((.permissions.allow // []) + $allow) | unique)

        | .hooks = (.hooks // {})
        | reduce $hooks[] as $h (.;
            .hooks[$h.event] = (
                ((.hooks[$h.event] // []) + [{
                    matcher: $h.matcher,
                    hooks: [{type: "command", command: $h.command}]
                }])
                | unique_by([.matcher, (.hooks[0].command // "")])
            )
          )
        ' "$out" > "$tmp" && mv "$tmp" "$out"
    # NOT tracked in _AP_OUT_FILES — merged file, uninstall handled
    # surgically by claude_clean.
}

# ─── .mcp.json (project-scope) ─────────────────────────────────────────
# Project-scope MCP file picked up automatically by Claude Code.
# Codex doesn't read this; opencode has its own.

_claude_write_mcp_json() {
    local merged_json="$1" target="$2" profile="$3"
    local mcps_filtered
    mcps_filtered=$(jq -c '
        [.mcps[] | select(
            (.harnesses // ["claude", "codex", "opencode"])
            | index("claude") != null
        )]
    ' <<<"$merged_json")
    [[ "$(jq 'length' <<<"$mcps_filtered")" -eq 0 ]] && return 0

    local out="$target/.mcp.json"
    [[ -f "$out" ]] || echo '{}' > "$out"

    local tmp; tmp=$(mktemp)
    jq --argjson mcps "$mcps_filtered" '
        .mcpServers = (.mcpServers // {})
        | reduce $mcps[] as $m (.;
            .mcpServers[$m.name] = (
                {command: $m.command}
                + (if $m.args then {args: $m.args} else {} end)
                + (if $m.env  then {env: $m.env}   else {} end)
            )
          )
    ' "$out" > "$tmp" && mv "$tmp" "$out"
    # Merged file — uninstall handled by claude_clean.
}

# ─── AGENTS.md ─────────────────────────────────────────────────────────

_claude_write_agents_md() {
    local merged_json="$1" target="$2" profile="$3"
    local body; body=$(ap_build_agents_md_body "$merged_json")
    [[ -z "$body" ]] && return 0

    local out="$target/AGENTS.md"
    ap_splice_agents_md "$out" "$profile" "$body"
    _AP_AGENTS_MD_FILES+=("${out#"$target"/}")
}

# ─── clean ─────────────────────────────────────────────────────────────
# Surgically reverse what claude_render added to merged files
# (settings.local.json, .mcp.json). The merged_json from install-time
# tells us exactly which permissions/MCP names we authored, so we don't
# delete entries the user added by hand. AGENTS.md and per-file
# artifacts are handled by the CLI's generic uninstall pass.

claude_clean() {
    local merged_json="$1" target="$2"
    local profile; profile=$(jq -r '.name' <<<"$merged_json")

    local allow_json mcps_filtered
    allow_json=$(jq -c '(.settings.permissions_allow // [])' <<<"$merged_json")
    mcps_filtered=$(jq -c '
        [.mcps[] | select(
            (.harnesses // ["claude","codex","opencode"])
            | index("claude") != null
        ) | .name]
    ' <<<"$merged_json")

    # settings.local.json: strip hooks whose command lives under our
    # prefix, plus any permission.allow entries we contributed.
    local settings="$target/.claude/settings.local.json"
    if [[ -f "$settings" ]]; then
        local tmp; tmp=$(mktemp)
        jq \
            --arg profile "$profile" \
            --argjson allow "$allow_json" \
            '
            .hooks = (
                (.hooks // {})
                | with_entries(
                    .value = (.value | map(
                        select(
                            (.hooks // [])
                            | map(.command // "")
                            | all(startswith(".claude/hooks/" + $profile + "--") | not)
                        )
                    ))
                  )
                | with_entries(select(.value | length > 0))
            )
            | if (.permissions.allow // []) | length > 0 then
                  .permissions.allow = ((.permissions.allow // []) - $allow)
              else . end
            | if (.permissions.allow // []) == [] then
                  del(.permissions.allow)
              else . end
            | if (.permissions // {}) == {} then del(.permissions) else . end
            | if (.hooks // {}) == {} then del(.hooks) else . end
            ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    fi

    # .mcp.json: drop entries by name.
    local mcp_file="$target/.mcp.json"
    if [[ -f "$mcp_file" ]]; then
        local tmp; tmp=$(mktemp)
        jq --argjson names "$mcps_filtered" '
            .mcpServers = (
                (.mcpServers // {})
                | with_entries(select(.key as $k | $names | index($k) | not))
            )
            | if .mcpServers == {} then del(.mcpServers) else . end
        ' "$mcp_file" > "$tmp" && mv "$tmp" "$mcp_file"
    fi
}
