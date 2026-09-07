#!/bin/bash
# prune-stale-local-skills.sh — delete stale ap-era copies of dotfiles-owned
# skills from a harness skills dir so install-local.sh can adopt the names.
#
# `ap` once wrote real-directory copies of the repo-local skills into
# ~/.agents/skills/<name>. Those live installs are retired. install-local.sh
# never touches an unmanaged directory of a name it ships (it warns and
# skips), so the stale copies block adoption forever. This one-time prune
# removes them.
#
# <target_dir>/<name> is deleted only when ALL of these hold:
#   - <source_dir>/<name>/SKILL.md exists (the dotfiles source ships it);
#   - <target_dir>/<name> is a real directory, not a symlink;
#   - <name> is not listed in <target_dir>/.dotfiles-managed;
#   - no key in the lockfile's `.skills` map has basename <name>. Keys are
#     `name` or `owner/name`. A missing lockfile means no locked names.
#
# A lockfile that does not parse aborts the prune (exit 1): when the locked
# set is unknown, nothing is deleted.
#
# Bash 3.2 compatible (macOS /bin/bash).
#
# Usage:
#   prune-stale-local-skills.sh <source_dir> <target_dir> <lockfile>

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <source_dir> <target_dir> <lockfile>" >&2
    exit 2
fi

source_dir="$1"
target_dir="$2"
lockfile="$3"
manifest="$target_dir/.dotfiles-managed"

if [[ ! -d "$source_dir" ]]; then
    echo "prune-stale-local-skills.sh: source directory not found: $source_dir" >&2
    exit 1
fi

# No skills dir yet: nothing to prune.
[[ -d "$target_dir" ]] || exit 0

managed=""
if [[ -f "$manifest" ]]; then
    managed=$(cat "$manifest")
fi

is_managed() {
    [[ -n "$managed" ]] || return 1
    printf '%s\n' "$managed" | grep -Fxq "$1"
}

# Basename of every lock-tracked skill key, one per line.
locked=""
if [[ -f "$lockfile" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "prune-stale-local-skills.sh: jq is required to read $lockfile" >&2
        exit 1
    fi
    if ! locked=$(jq -r '(.skills // {}) | keys[] | split("/") | last' "$lockfile"); then
        echo "prune-stale-local-skills.sh: could not parse lockfile: $lockfile" >&2
        exit 1
    fi
fi

is_locked() {
    [[ -n "$locked" ]] || return 1
    printf '%s\n' "$locked" | grep -Fxq "$1"
}

for src in "$source_dir"/*/; do
    [[ -f "$src/SKILL.md" ]] || continue
    name=$(basename "$src")
    dst="$target_dir/$name"

    [[ -d "$dst" && ! -L "$dst" ]] || continue
    is_managed "$name" && continue
    is_locked "$name" && continue

    rm -rf -- "$dst"
    echo "  Removed stale local skill copy: $dst"
done
