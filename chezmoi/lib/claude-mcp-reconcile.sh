#!/bin/bash
# claude-mcp-reconcile.sh — reconcile user-scope MCP servers in ~/.claude.json
# against the claude registry (chezmoi/.chezmoidata/claude.yaml `mcps` block).
#
# Sourced as a lib (tested by tests/claude-mcp-reconcile.bats); the thin
# run_onchange script parses the registry and dispatches here.
#
# Contract (spec: chezmoi-authoritative-claude, decision C2):
#   * All writes go through the `claude mcp` CLI (add-json / remove, user
#     scope) — never a direct edit of ~/.claude.json.
#   * A manifest (~/.claude/.chezmoi-mcp-manifest) records which live entries
#     this reconciler owns. On first run (no manifest), pre-existing live
#     entries that match a registry name are ADOPTED.
#   * Registry entries are authoritative for their names: added when missing,
#     re-added when the live config drifted.
#   * Manifest entries no longer in the registry are REMOVED from live.
#   * Live entries outside both registry and manifest were added by hand —
#     they are flagged in output and never touched.
#   * The manifest is rewritten to exactly the registry names on success.
#
# Env values keep their literal "${VAR}" passthrough form — Claude resolves
# them at server spawn; no secret is ever materialized here.

# Canonicalize one registry entry to Claude's stored shape.
# $1 = mcps JSON object, $2 = server name → JSON on stdout
_claude_mcp_desired_json() {
    jq -c --arg name "$2" '
        .[$name] | { type: "stdio", command, args: (.args // []), env: (.env // {}) }
    ' <<<"$1"
}

# claude_mcp_reconcile <mcps_json> <claude_json_path> <manifest_path>
#   mcps_json         — the registry `mcps` block as a JSON object string
#   claude_json_path  — path to the live ~/.claude.json
#   manifest_path     — path to the ownership manifest
claude_mcp_reconcile() {
    local mcps_json="$1" claude_json="$2" manifest="$3"

    # Fail loud, not skip: exiting 0 would let chezmoi record the run_onchange
    # as done for the current mcps hash, silently deferring reconcile until the
    # registry next changes. A nonzero exit re-runs it on the next apply.
    if ! command -v claude >/dev/null 2>&1; then
        echo "  ERROR: claude CLI not found — MCP reconcile cannot run." >&2
        echo "         Install the claude CLI and rerun 'dots sync'." >&2
        return 1
    fi

    local live_json="{}"
    [[ -f "$claude_json" ]] && live_json=$(jq -c '.mcpServers // {}' "$claude_json")

    local first_run=false
    [[ -f "$manifest" ]] || first_run=true

    # No mapfile — must run under macOS /bin/bash 3.2 (chezmoi scripts).
    local -a desired_names=() live_names=() manifest_names=()
    local _n
    while IFS= read -r _n; do [[ -n "$_n" ]] && desired_names+=("$_n"); done \
        < <(jq -r 'keys[]' <<<"$mcps_json")
    while IFS= read -r _n; do [[ -n "$_n" ]] && live_names+=("$_n"); done \
        < <(jq -r 'keys[]' <<<"$live_json")
    if [[ -f "$manifest" ]]; then
        while IFS= read -r _n; do [[ -n "$_n" ]] && manifest_names+=("$_n"); done < "$manifest"
    fi

    _in() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

    local name desired live_entry rc=0
    # ${arr[@]:-} + empty-skip guards throughout: an unguarded empty-array
    # expansion is an unbound-variable crash under bash 3.2 + set -u (the
    # run_onchange shell), which would strand retired MCPs when the registry
    # empties out.
    for name in "${desired_names[@]:-}"; do
        [[ -z "$name" ]] && continue
        desired=$(_claude_mcp_desired_json "$mcps_json" "$name")
        if _in "$name" "${live_names[@]:-}"; then
            live_entry=$(jq -c --arg n "$name" '.[$n]' <<<"$live_json")
            if [[ "$(jq -S . <<<"$live_entry")" == "$(jq -S . <<<"$desired")" ]]; then
                $first_run && echo "  Adopted existing MCP: $name"
                continue
            fi
            if ! $first_run && ! _in "$name" "${manifest_names[@]:-}"; then
                echo "  WARN: MCP '$name' exists live but is not manifest-tracked; registry takes ownership" >&2
            fi
            echo "  Updating MCP: $name"
            claude mcp remove "$name" -s user >/dev/null || rc=1
            claude mcp add-json "$name" "$desired" -s user >/dev/null || rc=1
        else
            echo "  Adding MCP: $name"
            claude mcp add-json "$name" "$desired" -s user >/dev/null || rc=1
        fi
    done

    for name in "${manifest_names[@]:-}"; do
        [[ -z "$name" ]] && continue
        if ! _in "$name" "${desired_names[@]:-}"; then
            if _in "$name" "${live_names[@]:-}"; then
                echo "  Removing retired MCP: $name"
                claude mcp remove "$name" -s user >/dev/null || rc=1
            fi
        fi
    done

    for name in "${live_names[@]:-}"; do
        [[ -z "$name" ]] && continue
        if ! _in "$name" "${desired_names[@]:-}" && ! _in "$name" "${manifest_names[@]:-}"; then
            echo "  NOTE: MCP '$name' is hand-added (not in the claude registry) — left alone."
            echo "        Promote it to chezmoi/.chezmoidata/claude.yaml or remove it with:"
            echo "        claude mcp remove '$name' -s user"
        fi
    done

    if [[ $rc -eq 0 ]]; then
        mkdir -p "$(dirname "$manifest")"
        if [[ ${#desired_names[@]} -gt 0 ]]; then
            printf '%s\n' "${desired_names[@]}" | sort > "$manifest"
        else
            : > "$manifest"
        fi
    else
        echo "  ERROR: one or more claude mcp operations failed; manifest left unchanged" >&2
    fi
    return $rc
}
