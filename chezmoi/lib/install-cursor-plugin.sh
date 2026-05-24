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
# Ownership model (machine-level, multi-plugin):
#   - Whole-file/dir artifacts (skills/, rules/, commands/, hook scripts)
#     are tracked in ONE ref-counted manifest at
#     ~/.cursor/.dotfiles-cursor-manifest.json, keyed by plugin:
#       { "<plugin>": { "files": ["skills/<name>", "commands/<n>.md", …] } }
#     Items dropped from a plugin's source are removed on the next run,
#     unless another plugin still claims the same path (ref-count).
#   - Items present on disk but claimed by NO dotfiles plugin (gh-installed
#     skills, hand-authored files) read as foreign: a same-named deploy
#     warns loudly and skips, never clobbers (collision guard).
#   - hooks.json / modes.json entries are tagged with `"_plugin": "<name>"`
#     rather than tracked in the manifest (they are merged, not whole-file).
#
# Bash 3.2 compatible (macOS /bin/bash).
#
# Usage:
#   install-cursor-plugin.sh <plugin_source_dir> [cursor_home]
#     cursor_home defaults to ${CURSOR_HOME:-$HOME/.cursor}

set -euo pipefail

die() {
    echo "install-cursor-plugin.sh: $*" >&2
    exit 1
}

# Absolute, symlink-normalized path. Works for non-existent leaves by
# resolving the nearest existing ancestor with `pwd -P`.
_abspath() {
    local p="$1" dir base
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    if [[ -d "$p" ]]; then ( cd "$p" && pwd -P ); return; fi
    dir=$(dirname "$p"); base=$(basename "$p")
    if [[ -d "$dir" ]]; then echo "$( cd "$dir" && pwd -P )/$base"; else echo "$p"; fi
}

# ─── target guard ───────────────────────────────────────────────────────
# Refuse to deploy into the dotfiles repo itself. A deploy pointed at the
# repo (instead of ~/.cursor) is the stray-artifact bug this prevents.

assert_target_outside_repo() {
    local home_abs repo_root
    home_abs=$(_abspath "$cursor_home")
    # Anchor on THIS script's own repo, not plugin_dir: the script always
    # lives in the dotfiles repo we're protecting, whereas a plugin (or a
    # test's scratch copy) may sit in some other enclosing git repo.
    repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null \
                || echo "${DOTFILES_DIR:-}")
    [[ -n "$repo_root" ]] || return 0   # can't determine repo root — don't block
    repo_root=$(_abspath "$repo_root")
    if [[ "$home_abs" == "$repo_root" || "$home_abs" == "$repo_root"/* ]]; then
        die "refusing to deploy into the dotfiles repo: cursor_home ($home_abs) is at or inside repo root ($repo_root). Point CURSOR_HOME at ~/.cursor."
    fi
}

# ─── merge integrity (PR #188 pattern) ──────────────────────────────────
# A jq merge that *succeeds* can still silently drop top-level keys. Before
# committing the merged temp file, refuse the mv if it would drop any
# top-level key present in the (non-empty) destination. Nested rewrites are
# allowed; losing a top-level key (hooks, version, modes, or a user's own)
# is not.

validated_mv() {
    local tmp="$1" dst="$2"
    jq -e . "$tmp" >/dev/null 2>&1 || die "refusing mv: $tmp is not valid JSON"
    if [[ -s "$dst" ]]; then
        local pre new dropped
        pre=$(jq -r 'keys[]' "$dst" 2>/dev/null | LC_ALL=C sort) \
            || die "refusing mv: existing $dst is non-empty but unparseable"
        new=$(jq -r 'keys[]' "$tmp" | LC_ALL=C sort)
        dropped=$(comm -23 <(printf '%s\n' "$pre") <(printf '%s\n' "$new"))
        [[ -n "$dropped" ]] && die "refusing mv: would drop top-level keys from $dst: ${dropped//$'\n'/ }"
    fi
    mv "$tmp" "$dst"
}

# ─── manifest primitives (machine-level, ref-counted) ───────────────────
# Mirrors the agent-profile manifest pattern (validate-on-read, ref-count,
# diff-and-clean) adapted to a single machine-scoped, plugin-keyed file.
# All read `$MANIFEST`; mutators are atomic (tmp + mv).

manifest_init() {
    [[ -f "$MANIFEST" ]] || echo '{}' > "$MANIFEST"
}

# Parse JSON; assert top-level object and per-plugin {files:[...]}. Corrupt
# manifest fails loud — a silent no-op on cleanup is a correctness bug.
manifest_validate() {
    [[ -f "$MANIFEST" ]] || return 0
    jq empty "$MANIFEST" >/dev/null 2>&1 || die "manifest corrupt (not valid JSON): $MANIFEST"
    local t; t=$(jq -r 'type' "$MANIFEST" 2>/dev/null || echo error)
    [[ "$t" == "object" ]] || die "manifest corrupt (top-level must be an object, got $t): $MANIFEST"
    local bad
    bad=$(jq -r '
        [to_entries[]
         | select((.value | type != "object") or ((.value.files // null) | type != "array"))
         | .key] | join(",")' "$MANIFEST" 2>/dev/null || echo "")
    [[ -z "$bad" ]] || die "manifest corrupt (entries missing files[] array: $bad): $MANIFEST"
}

# JSON array of the relpaths a plugin currently claims (or [] if none).
manifest_files_json() {
    local plugin="$1"
    [[ -f "$MANIFEST" ]] || { echo '[]'; return 0; }
    jq -c --arg p "$plugin" '.[$p].files // []' "$MANIFEST"
}

# Append a relpath to plugin.files[] (deduped, sorted by `unique`).
manifest_record() {
    local plugin="$1" relpath="$2" tmp
    manifest_init
    tmp=$(mktemp)
    jq --arg p "$plugin" --arg f "$relpath" '
        .[$p] = ((.[$p] // {files: []}) | .files = ((.files // []) + [$f] | unique))
    ' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# Drop a plugin's entry entirely.
manifest_clear() {
    local plugin="$1" tmp
    [[ -f "$MANIFEST" ]] || return 0
    tmp=$(mktemp)
    jq --arg p "$plugin" 'del(.[$p])' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# Name of another plugin claiming <relpath>, else "" (the ref-count key).
manifest_other_owner() {
    local relpath="$1" self="$2"
    [[ -f "$MANIFEST" ]] || { echo ""; return 0; }
    jq -r --arg f "$relpath" --arg self "$self" '
        [to_entries[]
         | select(.key != $self)
         | select((.value.files // []) | index($f))
         | .key][0] // ""' "$MANIFEST"
}

# dropped = old.files − new; rm -rf each dropped path UNLESS another plugin
# still claims it. Reads old from the (still-pristine) manifest; does not
# mutate it — main rewrites the entry afterward.
manifest_diff_clean() {
    local plugin="$1" new_json="$2" dropped f abs
    [[ -f "$MANIFEST" ]] || return 0
    dropped=$(jq -r --arg p "$plugin" --argjson new "$new_json" \
        '((.[$p].files // []) - $new)[]? // empty' "$MANIFEST")
    [[ -z "$dropped" ]] && return 0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ -n "$(manifest_other_owner "$f" "$plugin")" ]] && continue
        abs="$cursor_home/$f"
        if [[ -e "$abs" || -L "$abs" ]]; then
            rm -rf -- "$abs"
            echo "  Removed (dropped from $plugin): $f"
        fi
    done <<<"$dropped"
}

# ─── collision guard ────────────────────────────────────────────────────
# True when this plugin already owned <relpath> at the start of this run.
old_owns() {
    [[ -n "${OLD_FILES_JSON:-}" ]] || return 1
    jq -e --arg f "$1" 'index($f) != null' >/dev/null 2>&1 <<<"$OLD_FILES_JSON"
}

# Return 0 if this plugin may (over)write <relpath>; 1 (skip) if it is
# foreign — present on disk but owned by neither this plugin nor any other
# dotfiles plugin (i.e. gh-installed or hand-authored). Skips are loud and
# non-fatal so `dots sync` continues.
claim_or_skip() {
    local relpath="$1" dst="$2"
    if [[ -e "$dst" ]] && ! old_owns "$relpath" \
        && [[ -z "$(manifest_other_owner "$relpath" "$plugin_name")" ]]; then
        echo "  WARN: skipping $relpath: owned by gh/user, not $plugin_name" >&2
        return 1
    fi
    return 0
}

# ─── skills/<name>/ → ~/.cursor/skills/<name>/ ──────────────────────────

deploy_skills() {
    local src_dir="$plugin_dir/skills" dst_dir="$cursor_home/skills"
    [[ -d "$src_dir" ]] || return 0
    mkdir -p "$dst_dir"
    shopt -s nullglob
    local src name relpath dst
    for src in "$src_dir"/*/; do
        [[ -f "$src/SKILL.md" ]] || continue
        name=$(basename "$src"); relpath="skills/$name"; dst="$dst_dir/$name"
        claim_or_skip "$relpath" "$dst" || continue
        rm -rf -- "${dst:?}"
        cp -R "$src_dir/$name" "$dst"
        DEPLOYED+=("$relpath")
    done
    shopt -u nullglob
}

# ─── rules/*.mdc, commands/*.md → ~/.cursor/<subdir>/ ───────────────────

deploy_files() {
    local subdir="$1" ext="$2"
    local src_dir="$plugin_dir/$subdir" dst_dir="$cursor_home/$subdir"
    [[ -d "$src_dir" ]] || return 0
    mkdir -p "$dst_dir"
    shopt -s nullglob
    local src name relpath dst
    for src in "$src_dir"/*."$ext"; do
        name=$(basename "$src"); relpath="$subdir/$name"; dst="$dst_dir/$name"
        claim_or_skip "$relpath" "$dst" || continue
        cp -- "$src" "$dst"
        DEPLOYED+=("$relpath")
    done
    shopt -u nullglob
}

# ─── hooks/*.sh → ~/.cursor/hooks/ (+x) ─────────────────────────────────

deploy_hook_scripts() {
    local src_dir="$plugin_dir/hooks" dst_dir="$cursor_home/hooks"
    [[ -d "$src_dir" ]] || return 0
    mkdir -p "$dst_dir"
    shopt -s nullglob
    local src name relpath dst
    for src in "$src_dir"/*.sh; do
        name=$(basename "$src"); relpath="hooks/$name"; dst="$dst_dir/$name"
        claim_or_skip "$relpath" "$dst" || continue
        cp -- "$src" "$dst"
        chmod +x "$dst"
        DEPLOYED+=("$relpath")
    done
    shopt -u nullglob
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
    validated_mv "$tmp" "$dst"
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
    validated_mv "$tmp" "$dst"
}

# ─── legacy migration ───────────────────────────────────────────────────
# Per-dir .dotfiles-managed-<plugin> markers are superseded by the
# machine-level manifest. Remove any stragglers so the migration is clean.

remove_legacy_markers() {
    local sub
    for sub in skills rules commands hooks; do
        rm -f -- "$cursor_home/$sub/.dotfiles-managed-$plugin_name"
    done
}

# ─── main ─────────────────────────────────────────────────────────────────

main() {
    if [[ $# -lt 1 || $# -gt 2 ]]; then
        echo "Usage: $0 <plugin_source_dir> [cursor_home]" >&2
        exit 2
    fi

    plugin_dir="$1"
    cursor_home="${2:-${CURSOR_HOME:-$HOME/.cursor}}"

    [[ -d "$plugin_dir" ]] || die "source not found: $plugin_dir"
    [[ -f "$plugin_dir/.cursor-plugin/plugin.json" ]] \
        || die "missing .cursor-plugin/plugin.json in $plugin_dir"

    plugin_name=$(jq -r '.name // ""' "$plugin_dir/.cursor-plugin/plugin.json")
    [[ -n "$plugin_name" && "$plugin_name" != "null" ]] || die "plugin.json missing .name"

    assert_target_outside_repo

    MANIFEST="$cursor_home/.dotfiles-cursor-manifest.json"
    mkdir -p "$cursor_home"
    manifest_validate

    OLD_FILES_JSON=$(manifest_files_json "$plugin_name")
    DEPLOYED=()

    deploy_skills
    deploy_files rules    mdc
    deploy_files commands md
    deploy_hook_scripts
    merge_hooks_json
    merge_modes_json

    # Rewrite this plugin's manifest entry: clean dropped paths, then
    # re-record the set deployed this run.
    local new_json rel
    new_json=$(printf '%s\n' ${DEPLOYED[@]+"${DEPLOYED[@]}"} \
        | jq -R 'select(length > 0)' | jq -s 'unique')
    manifest_diff_clean "$plugin_name" "$new_json"
    manifest_clear "$plugin_name"
    for rel in ${DEPLOYED[@]+"${DEPLOYED[@]}"}; do
        manifest_record "$plugin_name" "$rel"
    done
    remove_legacy_markers

    echo "  Installed cursor plugin: $plugin_name → $cursor_home"
}

# Only run when executed directly; sourcing (e.g. from bats) is side-effect
# free so individual helpers can be unit-tested.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
