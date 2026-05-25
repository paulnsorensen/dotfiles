#!/usr/bin/env bash
# shared_writer.sh — Cross-harness shared-path writers.
#
# Several harnesses read the same on-disk file shape:
#   - `.claude/agents/<n>.md`   → Claude (via plugin), opencode, Cursor
#   - `.agents/skills/<n>/`     → Codex, opencode, Cursor
#
# To avoid each renderer re-implementing identical copy logic, every
# renderer sources this lib and calls:
#
#   ap_write_shared_claude_agent <target> <name> <body_path> <frontmatter_json>
#   ap_copy_shared_skill         <target> <name> <source_dir>
#   ap_render_model_override     <target> <harness> <kind> <name> <body_path> <model>
#
# All helpers append every file they write to the caller's _AP_OUT_FILES
# (relative to <target>) so the install manifest tracks them and uninstall
# is exact.

set -euo pipefail

# Append a relative path to _AP_OUT_FILES, deduping. Renderers reset
# _AP_OUT_FILES per-harness in `ap`'s cmd_install loop.
_ap_track_file() {
    local rel="$1"
    local f
    for f in "${_AP_OUT_FILES[@]+"${_AP_OUT_FILES[@]}"}"; do
        [[ "$f" == "$rel" ]] && return 0
    done
    _AP_OUT_FILES+=("$rel")
}

# Write `.claude/agents/<name>.md` under <target>. Body is read from
# <body_path>. If <frontmatter_json> is non-empty, render it as YAML
# frontmatter at the top of the file (---\n...\n---\n).
#
# Idempotent on content: re-writing the same body produces the same file.
ap_write_shared_claude_agent() {
    local target="$1" name="$2" body_path="$3" frontmatter_json="${4:-}"
    local rel=".claude/agents/${name}.md"
    local abs="${target%/}/${rel}"

    [[ -f "$body_path" ]] || {
        echo "ap_write_shared_claude_agent: body not found: $body_path" >&2
        return 1
    }

    mkdir -p "$(dirname "$abs")"
    {
        if [[ -n "$frontmatter_json" && "$frontmatter_json" != "null" && "$frontmatter_json" != "{}" ]]; then
            printf -- '---\n'
            jq -r 'to_entries[] | "\(.key): \(.value)"' <<<"$frontmatter_json"
            printf -- '---\n'
        fi
        cat "$body_path"
    } > "$abs"

    _ap_track_file "$rel"
}

# Copy a skill tree into the shared `.agents/skills/<name>/` path.
# Source dir typically lives under <profile>/skills/<name>/.
ap_copy_shared_skill() {
    local target="$1" name="$2" source_dir="$3"
    local rel=".agents/skills/${name}"
    local abs="${target%/}/${rel}"

    [[ -d "$source_dir" ]] || {
        echo "ap_copy_shared_skill: source not a dir: $source_dir" >&2
        return 1
    }

    rm -rf "$abs"
    mkdir -p "$(dirname "$abs")"
    cp -R "$source_dir" "$abs"

    _ap_track_file "$rel"
}

# Render a per-harness model override file. Writes:
#   - agents:   <target>/.<harness>/agents/<name>.md
#   - commands: <target>/.<harness>/commands/<name>.md
#
# Body is read from <body_path>; a `model: <value>` line is prepended in
# YAML frontmatter. If <model> is the sentinel `inherit`, no override is
# written (the harness reads the shared path instead) and we return 0.
#
# Cursor uses `.cursor/agents/` and `.cursor/commands/`.
# opencode uses `.opencode/agent/` (singular) for agents and
# `.opencode/commands/` (plural) for commands — caller passes those paths
# explicitly via <kind> = `agent_singular_dir` if needed; default is the
# `agents/` plural convention.
ap_render_model_override() {
    local target="$1" harness="$2" kind="$3" name="$4" body_path="$5" model="$6"

    [[ "$model" == "inherit" || -z "$model" ]] && return 0

    [[ -f "$body_path" ]] || {
        echo "ap_render_model_override: body not found: $body_path" >&2
        return 1
    }

    local subdir
    case "$kind" in
        agent|agents)             subdir="agents" ;;
        agent_singular|opencode_agent) subdir="agent" ;;
        command|commands)         subdir="commands" ;;
        *) echo "ap_render_model_override: unknown kind '$kind'" >&2; return 1 ;;
    esac

    local rel=".${harness}/${subdir}/${name}.md"
    local abs="${target%/}/${rel}"

    mkdir -p "$(dirname "$abs")"
    {
        printf -- '---\nmodel: %s\n---\n' "$model"
        cat "$body_path"
    } > "$abs"

    _ap_track_file "$rel"
}
