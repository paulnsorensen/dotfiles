#!/usr/bin/env bash
# commands.sh <worktree-path> <remove|archive> — print (never execute) the
# recommended cleanup commands for one triaged worktree, as one `&&` chain so
# removal never runs after a failed tag. The worktree can live anywhere (the
# `path:` line of ccw-sweep output). Derives the branch from the worktree
# itself and adds --force when the tree is dirty.
set -euo pipefail

# Shared helpers: the in-repo bin/lib, else the lib beside ccw-sweep on PATH
# (dots sync deploys this skill as a copy outside the repo).
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../bin/lib/worktree.sh"
if [[ ! -f "$lib" ]] && sweep="$(command -v ccw-sweep)"; then
    lib="$(dirname "$sweep")/lib/worktree.sh"
fi
[[ -f "$lib" ]] || { echo "commands.sh: cannot find bin/lib/worktree.sh; put the dotfiles bin/ on PATH" >&2; exit 1; }
# shellcheck source=bin/lib/worktree.sh
source "$lib"

usage='usage: commands.sh <worktree-path> <remove|archive>'
wt="${1:?$usage}"
action="${2:?$usage}"

[[ -d "$wt" ]] || { echo "commands.sh: no worktree at $wt" >&2; exit 1; }
wt="$(cd -P "$wt" && pwd)"

case "$action" in
    remove|archive) ;;
    *)
        echo "commands.sh: unknown action '$action' (want remove|archive)" >&2
        exit 2
        ;;
esac

repo="$(wt_main_checkout "$wt")" || { echo "commands.sh: $wt is not a git worktree" >&2; exit 1; }
repo="$(cd -P "$repo" && pwd)"
if [[ "$wt" == "$repo" ]]; then
    echo "commands.sh: $wt is the main checkout, not a linked worktree" >&2
    exit 1
fi
slug="${wt##*/}"
branch="$(git -C "$wt" symbolic-ref --short --quiet HEAD || true)"

force=""
if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    force=" --force"
fi

cmds=()
if [[ "$action" == "archive" ]]; then
    head="$(git -C "$wt" rev-parse HEAD)"
    tag="$(wt_archive_tag "$repo" "$slug" "$head")" \
        || { echo "commands.sh: no usable archive tag name for $wt" >&2; exit 1; }
    # A tag that already points at HEAD needs no new tag command.
    if ! git -C "$repo" show-ref --verify --quiet "refs/tags/${tag}"; then
        # Tag the branch, or the HEAD commit when the worktree is detached.
        cmds+=("$(printf 'git -C %q tag %q %q' "$repo" "$tag" "${branch:-$head}")")
    fi
fi

# Repo-relative path for a worktree inside the repo, else the absolute path.
wt_arg="$wt"
[[ "$wt" == "$repo/"* ]] && wt_arg="${wt#"$repo/"}"
cmds+=("$(printf 'git -C %q worktree remove%s %q' "$repo" "$force" "$wt_arg")")
if [[ -n "$branch" ]]; then
    cmds+=("$(printf 'git -C %q branch -D %q' "$repo" "$branch")")
fi

last=$(( ${#cmds[@]} - 1 ))
for i in "${!cmds[@]}"; do
    if (( i < last )); then
        printf '%s && \\\n' "${cmds[i]}"
    else
        printf '%s\n' "${cmds[i]}"
    fi
done
