#!/bin/bash
# install-cursor-plugin.sh — deploy a Cursor plugin's contents into the
# user-level Cursor auto-discovery directories.
#
# Source layout (per the Cursor 2.5 plugin spec):
#   <plugin>/
#     skills/<name>/SKILL.md      → ~/.cursor/skills/<name>/
#     rules/*.mdc                 → ~/.cursor/rules/<name>.mdc
#     commands/*.md               → ~/.cursor/commands/<name>.md
#     hooks/*.sh                  → ~/.cursor/hooks/<name>.sh (+x)
#     hooks.json                  → merged into ~/.cursor/hooks.json
#     modes/<name>.json           → merged into ~/.cursor/modes.json
#                                   under .modes.<name>
#     .cursor-plugin/plugin.json  → (source-only; not deployed)
#     README.md / LICENSE         → (source-only)
#
# Coexistence rules (mirror chezmoi/lib/install-local.sh):
#   - Each deploy target tracks ownership via a per-dir
#     <target>/.dotfiles-managed-cheese-grok manifest. The manifest
#     stem matches the plugin name so multiple plugins can coexist
#     without trampling each other's items.
#   - Items dropped from the plugin source are removed from the target
#     on the next run, but only if the manifest claims them.
#   - Pre-existing user-authored items at the target are preserved.
#
# Bash 3.2 compatible (macOS /bin/bash).
#
# Usage:
#   install-cursor-plugin.sh <plugin_source_dir> [cursor_home]
#     cursor_home defaults to ${CURSOR_HOME:-$HOME/.cursor}

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <plugin_source_dir> [cursor_home]" >&2
    exit 2
fi

plugin_dir="$1"
cursor_home="${2:-${CURSOR_HOME:-$HOME/.cursor}}"

if [[ ! -d "$plugin_dir" ]]; then
    echo "install-cursor-plugin.sh: source not found: $plugin_dir" >&2
    exit 1
fi
if [[ ! -f "$plugin_dir/.cursor-plugin/plugin.json" ]]; then
    echo "install-cursor-plugin.sh: missing .cursor-plugin/plugin.json in $plugin_dir" >&2
    exit 1
fi

plugin_name=$(jq -r '.name // ""' "$plugin_dir/.cursor-plugin/plugin.json")
if [[ -z "$plugin_name" || "$plugin_name" == "null" ]]; then
    echo "install-cursor-plugin.sh: plugin.json missing .name" >&2
    exit 1
fi

manifest_stem=".dotfiles-managed-$plugin_name"

mkdir -p "$cursor_home"

# ─── helpers ────────────────────────────────────────────────────────────

read_manifest() {
    local f="$1"
    [[ -f "$f" ]] && cat "$f" || true
}

write_manifest() {
    local f="$1"; shift
    if (($#)); then
        printf '%s\n' "$@" | LC_ALL=C sort -u > "$f"
    else
        : > "$f"
    fi
}

manifest_contains() {
    local needle="$1" manifest="$2"
    [[ -z "$manifest" ]] && return 1
    printf '%s\n' "$manifest" | grep -Fxq "$needle"
}

# Remove items previously deployed under this plugin's manifest but
# absent from the new install set, then copy the new items.
#
# Args: <target_dir> <new_basenames…>
sync_collection() {
    local target="$1"; shift
    local manifest_file="$target/$manifest_stem"
    local old_managed name entry
    mkdir -p "$target"
    old_managed=$(read_manifest "$manifest_file")

    # Build the new-set string for membership checks.
    local new_names=""
    for name in "$@"; do
        new_names="${new_names:+$new_names$'\n'}$name"
    done

    # Drop anything claimed last time but not present now. The target var
    # is :?-guarded so an unset/empty `target` could never produce `rm -rf /`.
    if [[ -n "$old_managed" ]]; then
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            if ! printf '%s\n' "$new_names" | grep -Fxq "$entry"; then
                rm -rf -- "${target:?}/$entry"
                echo "  Removed (dropped from $plugin_name): $target/$entry"
            fi
        done <<<"$old_managed"
    fi

    # Stamp the new manifest (even if empty — preserves "we are managing
    # nothing here now" so a later removal can still clean up).
    if (($#)); then
        write_manifest "$manifest_file" "$@"
    else
        write_manifest "$manifest_file"
    fi
}

# ─── skills/<name>/ → ~/.cursor/skills/<name>/ ──────────────────────────

deploy_skills() {
    local src_dir="$plugin_dir/skills"
    local dst_dir="$cursor_home/skills"
    local names=()
    if [[ -d "$src_dir" ]]; then
        shopt -s nullglob
        for src in "$src_dir"/*/; do
            [[ -f "$src/SKILL.md" ]] || continue
            names+=("$(basename "$src")")
        done
        shopt -u nullglob
    fi
    sync_collection "$dst_dir" ${names[@]+"${names[@]}"}
    local name
    for name in ${names[@]+"${names[@]}"}; do
        rm -rf -- "${dst_dir:?}/$name"
        cp -R "$src_dir/$name" "$dst_dir/$name"
    done
}

# ─── rules/*.mdc → ~/.cursor/rules/ ─────────────────────────────────────

deploy_files() {
    local subdir="$1" ext="$2"
    local src_dir="$plugin_dir/$subdir"
    local dst_dir="$cursor_home/$subdir"
    local names=()
    if [[ -d "$src_dir" ]]; then
        shopt -s nullglob
        for src in "$src_dir"/*."$ext"; do
            names+=("$(basename "$src")")
        done
        shopt -u nullglob
    fi
    sync_collection "$dst_dir" ${names[@]+"${names[@]}"}
    local name
    for name in ${names[@]+"${names[@]}"}; do
        cp -- "$src_dir/$name" "$dst_dir/$name"
    done
}

# ─── hooks/*.sh → ~/.cursor/hooks/ (+x) ─────────────────────────────────

deploy_hook_scripts() {
    local src_dir="$plugin_dir/hooks"
    local dst_dir="$cursor_home/hooks"
    local names=()
    if [[ -d "$src_dir" ]]; then
        shopt -s nullglob
        for src in "$src_dir"/*.sh; do
            names+=("$(basename "$src")")
        done
        shopt -u nullglob
    fi
    sync_collection "$dst_dir" ${names[@]+"${names[@]}"}
    local name
    for name in ${names[@]+"${names[@]}"}; do
        cp -- "$src_dir/$name" "$dst_dir/$name"
        chmod +x "$dst_dir/$name"
    done
}

# ─── hooks.json → merge into ~/.cursor/hooks.json ───────────────────────
#
# Per-plugin authorship is tracked by tagging each merged entry with
# `"_plugin": "<plugin_name>"`. On re-deploy we strip our own entries
# first (preserving any user-authored ones) and re-add fresh. Cursor
# itself ignores unknown fields, so the tag is harmless at runtime.

merge_hooks_json() {
    local src="$plugin_dir/hooks.json"
    local dst="$cursor_home/hooks.json"
    local tmp; tmp=$(mktemp)
    local existing="{}"
    [[ -s "$dst" ]] && existing=$(cat "$dst")

    # Even when the plugin no longer ships hooks, we must still strip any
    # we authored last time so removals propagate. The default empty hook
    # set passes through the strip-and-concat below cleanly.
    local plugin_hooks='{}'
    if [[ -f "$src" ]]; then
        plugin_hooks=$(jq --arg base "$cursor_home/hooks" --arg plugin "$plugin_name" '
            .hooks
            | to_entries
            | map(.value |= map(
                (.command |= (if startswith("./hooks/") then $base + (. | sub("^\\./hooks"; "")) else . end))
                + {_plugin: $plugin}
              ))
            | from_entries' "$src")
    fi

    # Strip prior entries we authored, then concat our fresh entries.
    jq --argjson new "$plugin_hooks" --arg plugin "$plugin_name" '
        (.version //= 1)
        | (.hooks //= {})
        | .hooks |= (to_entries
            | map(.value |= map(select(._plugin != $plugin)))
            | from_entries)
        | reduce ($new | to_entries[]) as $e (.;
            .hooks[$e.key] = ((.hooks[$e.key] // []) + $e.value))
    ' <<<"$existing" > "$tmp"
    mv "$tmp" "$dst"
}

# ─── modes/<name>.json → merge into ~/.cursor/modes.json under .modes ───

merge_modes_json() {
    local src_dir="$plugin_dir/modes"
    local dst="$cursor_home/modes.json"
    local existing="{}"
    [[ -s "$dst" ]] && existing=$(cat "$dst")

    local merged="$existing"
    local plugin_modes_added=()
    if [[ -d "$src_dir" ]]; then
        shopt -s nullglob
        local f mode_name
        for f in "$src_dir"/*.json; do
            mode_name=$(jq -r '.name // ""' "$f")
            if [[ -z "$mode_name" || "$mode_name" == "null" ]]; then
                echo "install-cursor-plugin.sh: $f missing .name; skipping" >&2
                continue
            fi
            merged=$(jq --arg n "$mode_name" --arg plugin "$plugin_name" \
                        --slurpfile body "$f" '
                (.modes //= {})
                | .modes[$n] = ($body[0] + {_plugin: $plugin})
            ' <<<"$merged")
            plugin_modes_added+=("$mode_name")
        done
        shopt -u nullglob
    fi

    # Strip our prior modes that weren't re-added (so dropping a mode
    # from the plugin actually removes it).
    if (( ${#plugin_modes_added[@]} > 0 )); then
        # shellcheck disable=SC2207
        local keep_csv; keep_csv=$(printf '"%s",' "${plugin_modes_added[@]}")
        keep_csv="[${keep_csv%,}]"
        merged=$(jq --arg plugin "$plugin_name" --argjson keep "$keep_csv" '
            (.modes //= {})
            | .modes |= with_entries(
                if (.value._plugin == $plugin) and ((.key | IN($keep[])) | not)
                then empty else . end)
        ' <<<"$merged")
    else
        # Plugin contributes no modes now — strip any we authored before.
        merged=$(jq --arg plugin "$plugin_name" '
            (.modes //= {})
            | .modes |= with_entries(
                if .value._plugin == $plugin then empty else . end)
        ' <<<"$merged")
    fi

    local tmp; tmp=$(mktemp)
    printf '%s' "$merged" > "$tmp"
    mv "$tmp" "$dst"
}

# ─── go ─────────────────────────────────────────────────────────────────

deploy_skills
deploy_files rules    mdc
deploy_files commands md
deploy_hook_scripts
merge_hooks_json
merge_modes_json

echo "  Installed cursor plugin: $plugin_name → $cursor_home"
