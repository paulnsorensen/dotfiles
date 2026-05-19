#!/usr/bin/env bash
# copilot.sh — Render an agent profile into Copilot CLI's project layout.
#
# Unlike Codex/opencode/Cursor, Copilot reads from its own paths under
# `.github/` and `.copilot/` — it does not consume the shared
# `.claude/agents/` or `.agents/skills/` trees. So this renderer copies
# the skill tree directly into `.github/skills/<n>/` and emits an
# `.agent.md` file under `.github/agents/<n>.agent.md` per subagent.
#
# Writes:
#   .github/agents/<n>.agent.md     — subagents (whole-file)
#   .github/skills/<n>/             — skill trees (whole-tree)
#   .github/hooks/<n>.json          — one JSON file per copilot-harnessed hook
#   .copilot/mcp-config.json        — merged MCP entries (mandatory tools: ["*"])
#
# Skips:
#   commands     — Copilot CLI has no slash-command surface; warn.
#   permissions  — Copilot uses runtime `--deny-tool` flags, not config.
#   AGENTS.md    — never touched (chezmoi-managed globally).
#
# Models: Copilot ignores the `model` field on agents. If a profile sets
# `models.copilot`, strip it and warn.

set -euo pipefail

copilot_render() {
    local merged_json="$1" target="$2"

    _copilot_warn_unsupported "$merged_json"

    _copilot_write_agents "$merged_json" "$target"
    _copilot_write_skills "$merged_json" "$target"
    _copilot_write_hooks  "$merged_json" "$target"
    _copilot_write_mcp    "$merged_json" "$target"
}

_copilot_warn_unsupported() {
    local merged_json="$1"
    local has
    has=$(jq -r '(.commands | length) > 0' <<<"$merged_json")
    if [[ "$has" == "true" ]]; then
        local names
        names=$(jq -r '.commands[].name' <<<"$merged_json")
        local n
        while IFS= read -r n; do
            [[ -z "$n" ]] && continue
            echo "copilot: skipping command '$n' (no equivalent surface)" >&2
        done <<<"$names"
    fi
    return 0
}

# Subagents → `.github/agents/<name>.agent.md`.
#
# Frontmatter mirrors what `ap_write_shared_claude_agent` does: emit any
# scalar/array fields the profile declares (description, tools, ...) as
# YAML, then the body. The `model` field is intentionally stripped — per
# Copilot CLI docs, agents do not honor it.
_copilot_write_agents() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.agents | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".agents[$i]" <<<"$merged_json")
        local name body_path source_dir
        name=$(       jq -r '.name'              <<<"$item")
        body_path=$(  jq -r '.body_path // ""'   <<<"$item")
        source_dir=$( jq -r '._source_dir'       <<<"$item")

        # Strip model override if present (Copilot ignores it).
        local has_model
        has_model=$(jq -r '(.models.copilot // "") != ""' <<<"$item")
        if [[ "$has_model" == "true" ]]; then
            echo "copilot: model override on agent '$name' ignored (Copilot ignores model field)" >&2
        fi

        # Build frontmatter from item, stripping internal fields and the
        # models map. Anything left (name, description, tools, ...) goes
        # into the frontmatter block.
        local fm_json
        fm_json=$(jq -c 'del(._source_dir, .body_path, .models, .fallback, .agents_md_path)' <<<"$item")

        local rel=".github/agents/${name}.agent.md"
        local abs="${target%/}/${rel}"
        mkdir -p "$(dirname "$abs")"
        {
            printf -- '---\n'
            # Render each key/value as YAML. Arrays become inline `[a, b]`.
            jq -r '
                to_entries[]
                | if (.value | type) == "array"
                  then "\(.key): [\(.value | join(", "))]"
                  elif (.value | type) == "string"
                  then "\(.key): \(.value)"
                  else "\(.key): \(.value | tostring)"
                  end
            ' <<<"$fm_json"
            printf -- '---\n\n'
            if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
                cat "$source_dir/$body_path"
            fi
        } > "$abs"
        _AP_OUT_FILES+=("$rel")
        ((++i))
    done
}

# Skills → `.github/skills/<name>/`. Copy the source skill dir directly
# (Copilot reads from its own path, not the shared `.agents/skills/`).
_copilot_write_skills() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.skills | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".skills[$i]" <<<"$merged_json")
        local name path source_dir
        name=$(      jq -r '.name'         <<<"$item")
        path=$(      jq -r '.path // ""'   <<<"$item")
        source_dir=$(jq -r '._source_dir'  <<<"$item")

        local src="$source_dir/$path"
        if [[ ! -d "$src" ]]; then
            echo "copilot: skill '$name' source dir not found: $src" >&2
            ((++i))
            continue
        fi

        local rel=".github/skills/${name}"
        local abs="${target%/}/${rel}"
        rm -rf "$abs"
        mkdir -p "$(dirname "$abs")"
        cp -R "$src" "$abs"
        _AP_OUT_FILES+=("$rel")
        ((++i))
    done
}

# Hooks → `.github/hooks/<n>.json`. One JSON file per hook, only when the
# hook's `harnesses` list includes `copilot`.
_copilot_write_hooks() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.hooks | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".hooks[$i]" <<<"$merged_json")
        local in_scope
        in_scope=$(jq -r '(.harnesses // ["claude"]) | index("copilot") != null' <<<"$item")
        if [[ "$in_scope" != "true" ]]; then ((++i)); continue; fi

        local event script source_dir
        event=$(     jq -r '.event'         <<<"$item")
        script=$(    jq -r '.script // ""'  <<<"$item")
        source_dir=$(jq -r '._source_dir'   <<<"$item")

        # Derive a hook name from the script basename (sans ext), falling
        # back to event when no script is set.
        local base name
        if [[ -n "$script" ]]; then
            base=$(basename "$script")
            name="${base%.*}"
        else
            name="$event"
        fi

        local rel=".github/hooks/${name}.json"
        local abs="${target%/}/${rel}"
        mkdir -p "$(dirname "$abs")"
        # Strip internal fields; the rest of the item becomes the hook
        # JSON. Copy the script alongside if provided.
        local payload
        payload=$(jq -c 'del(._source_dir, .harnesses, .fallback)' <<<"$item")
        if [[ -n "$script" && -f "$source_dir/$script" ]]; then
            local script_rel; script_rel=".github/hooks/$(basename "$script")"
            local script_abs="${target%/}/${script_rel}"
            cp "$source_dir/$script" "$script_abs"
            chmod +x "$script_abs" 2>/dev/null || true
            payload=$(jq -c --arg s "$script_rel" '.script = $s' <<<"$payload")
            _AP_OUT_FILES+=("$script_rel")
        fi
        jq '.' <<<"$payload" > "$abs"
        _AP_OUT_FILES+=("$rel")
        ((++i))
    done
}

# MCPs → `.copilot/mcp-config.json` with `{mcpServers: {...}}` shape.
# Every entry carries `tools: ["*"]` per Copilot CLI docs (mandatory).
_copilot_write_mcp() {
    local merged_json="$1" target="$2"
    local mcps_filtered
    mcps_filtered=$(jq -c '
        [.mcps[] | select(
            (.harnesses // ["claude", "codex"])
            | index("copilot") != null
        )]
    ' <<<"$merged_json")

    local n; n=$(jq -r 'length' <<<"$mcps_filtered")
    (( n > 0 )) || return 0

    local out="$target/.copilot/mcp-config.json"
    mkdir -p "$(dirname "$out")"
    [[ -f "$out" ]] || echo '{"mcpServers": {}}' > "$out"

    local tmp; tmp=$(mktemp)
    jq \
        --argjson mcps "$mcps_filtered" \
        '
        .mcpServers = (.mcpServers // {})
        | reduce $mcps[] as $m (.;
            .mcpServers[$m.name] = (
                {command: $m.command, args: ($m.args // [])}
                + (if $m.env then {env: $m.env} else {} end)
                + {tools: ["*"]}
            )
          )
        ' "$out" > "$tmp" && mv "$tmp" "$out"
    # Merged file — uninstall handled by copilot_clean (no _AP_OUT_FILES entry).
}

# copilot_clean: remove only the MCP entries this profile added to the
# shared `.copilot/mcp-config.json`. Whole-file artefacts (agents,
# skills, hooks) are tracked in `_AP_OUT_FILES` and removed by
# `cmd_uninstall`'s `rm -rf` loop.
copilot_clean() {
    local merged_json="$1" target="$2"
    local cfg="$target/.copilot/mcp-config.json"
    [[ -f "$cfg" ]] || return 0

    local mcp_names
    mcp_names=$(jq -c '
        [.mcps[] | select(
            (.harnesses // ["claude","codex"])
            | index("copilot") != null
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
}
