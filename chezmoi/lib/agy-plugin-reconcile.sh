#!/bin/bash
# agy-plugin-reconcile.sh — reconcile native Antigravity CLI plugins against
# chezmoi/.chezmoidata/agy.yaml.
#
# Sourced as a library (tested by tests/agy-config.bats). `.sync-lib.sh`'s
# `sync_agy_plugins` resolves desired entries from agy.yaml and dispatches here.
#
# Ownership boundary:
#   - Installs desired plugins missing from `agy plugin list --json`.
#   - Records plugins this run installed, plus earlier manifest entries that
#     stay desired. It never adopts a plugin installed by hand.
#   - Uninstalls retired plugins only when the manifest proves this reconciler
#     owns them. Hand-installed and built-in plugins (such as swarm) stay.
#   - After an install failure, it keeps every prior manifest entry, skips
#     pruning, and returns 1.
#   - Missing `agy` CLI warns and returns 0.
#
# Name lists are newline-separated strings. No mapfile or associative
# arrays — the code must run under macOS /bin/bash 3.2.

# _agy_has_line <needle> <newline_list>
_agy_has_line() {
    grep -qxF -- "$1" <<<"$2"
}

# _agy_install_missing <desired_tsv> <current_names>
# Prints the names it installs, one per line, on fd 3. Returns 1 on any failure.
_agy_install_missing() {
    local desired_tsv="$1" current_names="$2"
    local name source rc=0
    while IFS=$'\t' read -r name source; do
        [[ -z "$name" ]] && continue
        _agy_has_line "$name" "$current_names" && continue
        echo "  Installing agy plugin: $name ($source)"
        if agy plugin install "$source" >/dev/null 2>&1 </dev/null; then
            printf '%s\n' "$name" >&3
        else
            echo "  ERROR: 'agy plugin install $source' failed for $name" >&2
            rc=1
        fi
    done <<<"$desired_tsv"
    return "$rc"
}

# _agy_prune_retired <prior_names> <desired_names> <current_names>
_agy_prune_retired() {
    local prior_names="$1" desired_names="$2" current_names="$3"
    local old rc=0
    while IFS= read -r old; do
        [[ -z "$old" ]] && continue
        _agy_has_line "$old" "$desired_names" && continue
        _agy_has_line "$old" "$current_names" || continue
        echo "  Uninstalling retired agy plugin: $old"
        if ! agy plugin uninstall "$old" >/dev/null 2>&1 </dev/null; then
            echo "  ERROR: 'agy plugin uninstall $old' failed" >&2
            rc=1
        fi
    done <<<"$prior_names"
    return "$rc"
}

# _agy_write_manifest <manifest_path> <names>
_agy_write_manifest() {
    local manifest="$1" names="$2" manifest_tmp
    mkdir -p "$(dirname "$manifest")"
    manifest_tmp=$(mktemp "${manifest}.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$names" | { grep -v '^$' || true; } | sort -u > "$manifest_tmp"; then
        rm -f "$manifest_tmp"
        echo "  ERROR: could not write agy plugin manifest" >&2
        return 1
    fi
    if ! mv "$manifest_tmp" "$manifest"; then
        rm -f "$manifest_tmp"
        echo "  ERROR: could not replace agy plugin manifest" >&2
        return 1
    fi
}

# _agy_still_desired <prior_names> <desired_names>
# Prints the prior entries that remain desired.
_agy_still_desired() {
    local item
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        _agy_has_line "$item" "$2" && printf '%s\n' "$item"
    done <<<"$1"
    return 0
}

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
    if ! installed_json=$(agy plugin list --json 2>/dev/null </dev/null); then
        echo "  ERROR: 'agy plugin list --json' failed" >&2
        return 1
    fi
    if ! current_names=$(jq -r 'if type == "array" then .[].name else error("not an array") end' <<<"$installed_json" 2>/dev/null); then
        echo "  ERROR: 'agy plugin list --json' did not return a JSON array" >&2
        return 1
    fi

    local desired_names prior_names="" installed_now keep rc=0
    desired_names=$(cut -f1 <<<"$desired_tsv" | grep -v '^$' || true)
    if [[ -f "$manifest" ]] && ! prior_names=$(<"$manifest"); then
        echo "  ERROR: could not read agy plugin manifest: $manifest" >&2
        return 1
    fi

    installed_now=$(_agy_install_missing "$desired_tsv" "$current_names" 3>&1 1>&2) || rc=1
    if (( rc == 0 )); then
        _agy_prune_retired "$prior_names" "$desired_names" "$current_names" || rc=1
    fi

    # After a failure, keep every prior entry so a later run can retry the prune.
    if (( rc != 0 )); then
        keep="$prior_names"
    else
        keep=$(_agy_still_desired "$prior_names" "$desired_names")
    fi
    _agy_write_manifest "$manifest" "$installed_now"$'\n'"$keep" || rc=1
    return "$rc"
}
