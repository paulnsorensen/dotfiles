#!/usr/bin/env bash
# codex.sh — Render an agent profile into Codex CLI's project layout.
#
# Codex natively reads:
#   .codex/agents/<n>.toml        — subagents (TOML)
#   .agents/skills/<n>/SKILL.md   — skills (cross-harness shared dir;
#                                    also read by opencode + Cursor)
#   .codex/hooks.json             — hooks (JSON array, 6-event surface)
#   .codex/config.toml            — [mcp_servers] entries
#
# Slash commands are deprecated on Codex (use skills); we skip with a
# warning. AGENTS.md is owned globally by chezmoi and is never touched.
#
# Bash 3.2 compatible: no `local -n`, no `declare -A`, no bash-4+
# features. All argument plumbing uses jq-on-stdin / jq-on-arg patterns.

set -euo pipefail

codex_render() {
    local merged_json="$1" target="$2"

    _codex_write_agents "$merged_json" "$target"
    _codex_write_skills "$merged_json" "$target"
    _codex_write_hooks  "$merged_json" "$target"
    _codex_write_mcps   "$merged_json" "$target"
    _codex_warn_commands "$merged_json"
}

# ─── subagents ──────────────────────────────────────────────────────────
# Each agent lands at .codex/agents/<name>.toml with TOML fields:
#   name, description, developer_instructions (multiline), optional model.
# Body is read from <source_dir>/<body_path> and inlined as a TOML
# triple-quoted basic string. Backslashes and `"""` sequences are
# escaped so the body round-trips intact.

_codex_write_agents() {
    local merged_json="$1" target="$2"
    local count; count=$(jq -r '.agents | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local item; item=$(jq -c ".agents[$i]" <<<"$merged_json")
        local name desc body_path source_dir model
        name=$(       jq -r '.name'              <<<"$item")
        desc=$(       jq -r '.description // ""' <<<"$item")
        body_path=$(  jq -r '.body_path // ""'   <<<"$item")
        source_dir=$( jq -r '._source_dir'       <<<"$item")
        model=$(      jq -r '.models.codex // ""' <<<"$item")

        local body=""
        if [[ -n "$body_path" && -f "$source_dir/$body_path" ]]; then
            # Escape backslashes first, then triple-quotes, so the body is
            # a valid TOML basic-string payload inside """...""".
            body=$(_codex_escape_toml_triple <"$source_dir/$body_path")
        fi

        local rel=".codex/agents/${name}.toml"
        local abs="${target%/}/${rel}"
        mkdir -p "$(dirname "$abs")"
        {
            printf 'name = %s\n'        "$(_codex_toml_string "$name")"
            printf 'description = %s\n' "$(_codex_toml_string "$desc")"
            if [[ -n "$model" ]]; then
                printf 'model = %s\n'   "$(_codex_toml_string "$model")"
            fi
            printf 'developer_instructions = """\n%s"""\n' "$body"
        } > "$abs"
        _AP_OUT_FILES+=("$rel")

        i=$((i + 1))
    done
}

# Escape a string for use inside a TOML single-line basic string ("...").
# Handles \, ", newline, tab, carriage return.
_codex_toml_string() {
    jq -Rn --arg s "$1" '$s'
}

# Escape stdin for use inside a TOML triple-quoted basic string.
# Per TOML spec: backslash and `"""` need escaping; everything else
# (newlines, quotes-of-1-or-2) passes through. Preserves trailing newline.
_codex_escape_toml_triple() {
    # 1. Double every backslash.
    # 2. Replace """ with \"\"\".
    sed -e 's/\\/\\\\/g' -e 's/"""/\\"\\"\\"/g'
}

# ─── skills ─────────────────────────────────────────────────────────────
# Copy the entire skill tree to the cross-harness shared path
# .agents/skills/<name>/. Codex, opencode, and Cursor all read this.

_codex_write_skills() {
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
        if [[ -d "$src" ]]; then
            ap_copy_shared_skill "$target" "$name" "$src"
        else
            echo "    codex: skill '$name' source dir missing: $src" >&2
        fi
        i=$((i + 1))
    done
}

# ─── hooks ──────────────────────────────────────────────────────────────
# Codex reads .codex/hooks.json as a JSON array of hook records, each:
#   { "event": "...", "matcher": "...", "command": "...", "timeout": ... }
# We only write the file when at least one hook entry has `harnesses`
# including `codex`. Otherwise no file is produced. The hook script
# itself is copied to .codex/hooks/<basename> so the command resolves
# relative to the target dir.

_codex_write_hooks() {
    local merged_json="$1" target="$2"

    local count; count=$(jq -r '
        [.hooks[]
         | select(((.harnesses // ["claude"]) | index("codex")) != null)
        ] | length
    ' <<<"$merged_json")
    (( count > 0 )) || return 0

    local records="[]"
    local total; total=$(jq -r '.hooks | length' <<<"$merged_json")
    local i=0
    while (( i < total )); do
        local item; item=$(jq -c ".hooks[$i]" <<<"$merged_json")
        local in_codex; in_codex=$(jq -r '
            (.harnesses // ["claude"]) | index("codex") != null
        ' <<<"$item")
        if [[ "$in_codex" != "true" ]]; then
            i=$((i + 1)); continue
        fi

        local event matcher script source_dir timeout
        event=$(     jq -r '.event'              <<<"$item")
        matcher=$(   jq -r '.matcher // ""'      <<<"$item")
        script=$(    jq -r '.script  // ""'      <<<"$item")
        source_dir=$(jq -r '._source_dir'        <<<"$item")
        timeout=$(   jq -r '.timeout // empty'   <<<"$item")

        local base; base=$(basename "$script")
        local rel_script=".codex/hooks/${base}"
        local abs_script="${target%/}/${rel_script}"

        mkdir -p "$(dirname "$abs_script")"
        if [[ -n "$script" && -f "$source_dir/$script" ]]; then
            cp "$source_dir/$script" "$abs_script"
            chmod +x "$abs_script"
            _AP_OUT_FILES+=("$rel_script")
        fi

        records=$(jq \
            --arg ev "$event" \
            --arg ma "$matcher" \
            --arg cm "bash ${rel_script}" \
            --arg to "$timeout" \
            '. + [({event:$ev, command:$cm}
                    + (if $ma == "" then {} else {matcher:$ma} end)
                    + (if $to == "" then {} else {timeout:($to|tonumber)} end))]' \
            <<<"$records")

        i=$((i + 1))
    done

    local rel=".codex/hooks.json"
    local abs="${target%/}/${rel}"
    mkdir -p "$(dirname "$abs")"
    jq '.' <<<"$records" > "$abs"
    _AP_OUT_FILES+=("$rel")
}

# ─── MCPs ───────────────────────────────────────────────────────────────
# Merge codex-harnessed MCPs into .codex/config.toml under [mcp_servers].
# Preserves every other top-level key (approval_policy, sandbox_mode,
# user-managed mcp entries, …). Uses the same yq -p=toml -o=toml pattern
# as agents/hooks/sync.sh.

_codex_write_mcps() {
    local merged_json="$1" target="$2"
    local mcps_json
    mcps_json=$(jq -c '
        [.mcps[]
         | select(((.harnesses // ["claude","codex"]) | index("codex")) != null)
        ]
    ' <<<"$merged_json")

    local count; count=$(jq -r 'length' <<<"$mcps_json")
    (( count > 0 )) || return 0

    local cfg="$target/.codex/config.toml"
    mkdir -p "$(dirname "$cfg")"

    local current_json='{}'
    if [[ -s "$cfg" ]]; then
        local yq_err
        yq_err=$(mktemp "${TMPDIR:-/tmp}/codex-render.XXXXXX.err")
        if ! current_json=$(yq -p=toml -o=json '.' "$cfg" 2>"$yq_err"); then
            echo "    codex: refusing to overwrite unparseable $cfg:" >&2
            sed 's/^/      /' "$yq_err" >&2
            rm -f "$yq_err"
            return 1
        fi
        rm -f "$yq_err"
    fi

    local merged
    merged=$(jq --argjson m "$mcps_json" '
        .mcp_servers = (.mcp_servers // {})
        | reduce $m[] as $item (.;
            .mcp_servers[$item.name] = (
                {command: $item.command}
                + (if ($item.args // null)  != null then {args:  $item.args}  else {} end)
                + (if ($item.env  // null)  != null then {env:   $item.env}   else {} end)
            )
        )
    ' <<<"$current_json")

    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/codex-render.XXXXXX.toml")
    yq -p=json -o=toml '.' <<<"$merged" > "$tmp"
    mv "$tmp" "$cfg"
    # config.toml is a merged file — never tracked as a whole-file artifact;
    # codex_clean surgically removes our [mcp_servers] entries by name.
}

# ─── commands (deprecated on Codex — skip with warning) ─────────────────

_codex_warn_commands() {
    local merged_json="$1"
    local count; count=$(jq -r '.commands | length' <<<"$merged_json")
    local i=0
    while (( i < count )); do
        local name; name=$(jq -r ".commands[$i].name" <<<"$merged_json")
        echo "    codex: skipping command '$name' (slash commands deprecated, use skills)" >&2
        i=$((i + 1))
    done
}

# ─── clean ──────────────────────────────────────────────────────────────
# Remove our entries from .codex/config.toml's [mcp_servers] table by
# name. The wholesale .codex/agents/*.toml, .codex/hooks.json, and
# .agents/skills/<n>/ files are deleted by cmd_uninstall's manifest sweep.

codex_clean() {
    local merged_json="$1" target="$2"
    local cfg="$target/.codex/config.toml"
    [[ -f "$cfg" ]] || return 0

    local mcp_names
    mcp_names=$(jq -c '
        [.mcps[]
         | select(((.harnesses // ["claude","codex"]) | index("codex")) != null)
         | .name
        ]
    ' <<<"$merged_json")

    local count; count=$(jq -r 'length' <<<"$mcp_names")
    (( count > 0 )) || return 0

    local current_json
    if ! current_json=$(yq -p=toml -o=json '.' "$cfg" 2>/dev/null); then
        echo "    codex_clean: cannot parse $cfg, skipping" >&2
        return 0
    fi

    local merged
    merged=$(jq --argjson names "$mcp_names" '
        if (.mcp_servers // null) == null then .
        else
            .mcp_servers = (
                .mcp_servers
                | with_entries(select(.key as $k | $names | index($k) | not))
            )
            | if .mcp_servers == {} then del(.mcp_servers) else . end
        end
    ' <<<"$current_json")

    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/codex-clean.XXXXXX.toml")
    if [[ "$(jq -r 'keys | length' <<<"$merged")" == "0" ]]; then
        # File would be empty — remove it.
        rm -f "$cfg"
        rm -f "$tmp"
        return 0
    fi
    yq -p=json -o=toml '.' <<<"$merged" > "$tmp"
    mv "$tmp" "$cfg"
}
