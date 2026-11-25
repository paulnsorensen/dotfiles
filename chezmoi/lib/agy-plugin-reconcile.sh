#!/bin/bash
# agy-plugin-reconcile.sh — reconcile native Antigravity CLI plugins against
# chezmoi/.chezmoidata/agy.yaml.
#
# Sourced as a library (tested by tests/agy-config.bats). `.sync-lib.sh`'s
# `sync_agy_plugins` resolves desired entries from agy.yaml and dispatches here.
#
# Ownership boundary:
#   - Installs desired plugins missing from `agy plugin list --json`.
#   - Records managed plugin names in a manifest file
#     (~/.gemini/config/.chezmoi-plugin-manifest).
#   - Uninstalls retired plugins only when the manifest proves this reconciler
#     owns them. Hand-installed and built-in plugins (such as swarm) stay.
#   - Missing `agy` CLI warns and returns 0.

# agy_plugin_reconcile <desired_tsv> <manifest_path>
#   desired_tsv   — newline-separated `<name>\t<source>` lines
#   manifest_path — path to the ownership manifest
agy_plugin_reconcile() {
    local desired_tsv="$1" manifest="$2"

    if ! command -v agy >/dev/null 2>&1; then
        echo "  WARN: agy CLI not found — skipping Antigravity plugin reconcile" >&2
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "  WARN: jq not found — skipping Antigravity plugin reconcile" >&2
        return 0
    fi

    local installed_json current_names=""
    if ! installed_json=$(agy plugin list --json 2>/dev/null); then
        echo "  ERROR: 'agy plugin list --json' failed" >&2
        return 1
    fi
    if ! current_names=$(jq -r 'if type == "array" then .[].name else empty end' <<<"$installed_json" 2>/dev/null); then
        echo "  ERROR: 'agy plugin list --json' returned invalid JSON" >&2
        return 1
    fi

    # No mapfile — must run under macOS /bin/bash 3.2.
    local -a desired_names=() prior_names=()
    local name source rc=0

    _agy_in() {
        local needle="$1"; shift
        local item
        for item in "$@"; do
            [[ "$item" == "$needle" ]] && return 0
        done
        return 1
    }

    while IFS=$'\t' read -r name source; do
        [[ -z "$name" ]] && continue
        desired_names+=("$name")
        if grep -qxF "$name" <<<"$current_names"; then
            continue
        fi
        echo "  Installing agy plugin: $name ($source)"
        if ! agy plugin install "$source" >/dev/null 2>&1; then
            echo "  ERROR: 'agy plugin install $source' failed for $name" >&2
            rc=1
        fi
    done <<<"$desired_tsv"

    if [[ -f "$manifest" ]]; then
        local prior
        while IFS= read -r prior; do
            [[ -n "$prior" ]] && prior_names+=("$prior")
        done < "$manifest"
    fi

    # Prune only manifest-owned plugins, and only when every install succeeded.
    if (( rc == 0 )); then
        local old
        for old in "${prior_names[@]:-}"; do
            [[ -z "$old" ]] && continue
            _agy_in "$old" "${desired_names[@]:-}" && continue
            if grep -qxF "$old" <<<"$current_names"; then
                echo "  Uninstalling retired agy plugin: $old"
                if ! agy plugin uninstall "$old" >/dev/null 2>&1; then
                    echo "  ERROR: 'agy plugin uninstall $old' failed" >&2
                    rc=1
                fi
            fi
        done
    fi

    if (( rc == 0 )); then
        mkdir -p "$(dirname "$manifest")"
        local manifest_tmp
        manifest_tmp=$(mktemp "${manifest}.tmp.XXXXXX") || return 1
        if (( ${#desired_names[@]} > 0 )); then
            if ! printf '%s\n' "${desired_names[@]}" | sort -u > "$manifest_tmp"; then
                rm -f "$manifest_tmp"
                echo "  ERROR: could not write agy plugin manifest" >&2
                return 1
            fi
        else
            : > "$manifest_tmp"
        fi
        if ! mv "$manifest_tmp" "$manifest"; then
            rm -f "$manifest_tmp"
            echo "  ERROR: could not replace agy plugin manifest" >&2
            return 1
        fi
    fi

    return "$rc"
}
