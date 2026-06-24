#!/bin/bash
# install-claude-assets.sh — deploy Claude's repo-owned asset directories
# (commands/, hooks/, reference/, workflows/) into ~/.claude as ONE-WAY
# COPIES, replacing the legacy whole-dir symlinks the old claude/.sync made.
#
# Why copy, not symlink: a symlinked directory lets anything written into
# ~/.claude/<dir> flow back through the link into the dotfiles repo. Copy
# keeps the repo as the one-way source of truth; runtime writes stay in
# $HOME. (This mirrors the ~/.cursor fix — see SYNC_SKIP_LIST in .sync-lib.sh.)
#
# Self-migrating: if a target dir is still a legacy symlink (into the repo),
# it is removed and replaced with a real directory before copying — so this
# is safe to run regardless of ordering against the old symlink sync.
#
# Manifest-tracked (mirrors install-cursor-plugin.sh): each managed dir
# carries a <dir>/.dotfiles-managed-claude-assets manifest listing the
# entries we deployed. Entries dropped from the repo are removed on the next
# run; pre-existing user-authored items at the target are preserved.
#
# Bash 3.2 compatible (macOS /bin/bash).
#
# Usage:
#   install-claude-assets.sh <claude_source_dir> [claude_home]
#     claude_home defaults to ${CLAUDE_HOME:-$HOME/.claude}

set -euo pipefail

src_root="${1:?usage: install-claude-assets.sh <claude_source_dir> [claude_home]}"
claude_home="${2:-${CLAUDE_HOME:-$HOME/.claude}}"
manifest_stem=".dotfiles-managed-claude-assets"

# Directories deployed by copy. Each is wholly repo-owned today, but the
# manifest still preserves any user-authored items that appear alongside.
COLLECTIONS="commands hooks reference workflows"

if [[ ! -d "$src_root" ]]; then
    echo "install-claude-assets.sh: source not found: $src_root" >&2
    exit 1
fi
mkdir -p "$claude_home"

# ─── manifest helpers (parity with install-cursor-plugin.sh) ─────────────

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

# Remove items previously deployed under our manifest but absent from the new
# install set, then stamp the fresh manifest. User-authored items (never in
# the manifest) are left untouched.
#
# Args: <target_dir> <new_basenames…>
sync_collection() {
    local target="$1"; shift
    local manifest_file="$target/$manifest_stem"
    local old_managed new_names="" name entry
    mkdir -p "$target"
    old_managed=$(read_manifest "$manifest_file")
    for name in "$@"; do
        new_names="${new_names:+$new_names$'\n'}$name"
    done
    if [[ -n "$old_managed" ]]; then
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            # Manifest entries are basenames only. Reject any path separator or
            # parent ref so a corrupted/hand-edited manifest can't steer the
            # `rm -rf` below outside the target dir (e.g. `../../foo`).
            case "$entry" in
                */*|..) echo "  Skipped suspicious manifest entry: $entry" >&2; continue ;;
            esac
            if ! printf '%s\n' "$new_names" | grep -Fxq "$entry"; then
                rm -rf -- "${target:?}/$entry"
                echo "  Removed (dropped from repo): $target/$entry"
            fi
        done <<<"$old_managed"
    fi
    if (($#)); then
        write_manifest "$manifest_file" "$@"
    else
        write_manifest "$manifest_file"
    fi
}

# ─── go ───────────────────────────────────────────────────────────────────

for coll in $COLLECTIONS; do
    src_dir="$src_root/$coll"
    dst_dir="$claude_home/$coll"
    [[ -d "$src_dir" ]] || continue

    # Self-migrate: a legacy symlink target must become a real dir, else the
    # copy below would write straight back into the repo through the link.
    if [[ -L "$dst_dir" ]]; then
        rm "$dst_dir"
        echo "  Removed legacy ~/.claude/$coll symlink (now copied)"
    fi

    names=()
    shopt -s nullglob dotglob
    for src in "$src_dir"/*; do
        base="$(basename "$src")"
        # Skip our own manifest and any stray VCS/sync droppings.
        case "$base" in
            "$manifest_stem"|.sync|.git|.DS_Store) continue ;;
        esac
        names+=("$base")
    done
    shopt -u nullglob dotglob

    # `${names[@]+"${names[@]}"}` keeps an empty array safe under `set -u`
    # on bash 3.2 (macOS) — same idiom as install-cursor-plugin.sh.
    sync_collection "$dst_dir" ${names[@]+"${names[@]}"}
    for name in ${names[@]+"${names[@]}"}; do
        rm -rf -- "${dst_dir:?}/$name"
        cp -R "$src_dir/$name" "$dst_dir/$name"
    done

    echo "  Deployed claude/$coll → $dst_dir (${#names[@]} items)"
done
