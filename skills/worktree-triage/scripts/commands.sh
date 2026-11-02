#!/usr/bin/env bash
# commands.sh <worktree-path> <remove|archive> — print (never execute) the
# recommended cleanup commands for one triaged worktree. The worktree can live
# anywhere (the `path:` line of ccw-sweep output); the repo root comes from its
# shared git dir. Derives the branch from the worktree itself and adds --force
# when the tree is dirty.
set -euo pipefail

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

common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { echo "commands.sh: $wt is not a git worktree" >&2; exit 1; }
repo="$(dirname "$common")"
if [[ "$(git -C "$wt" rev-parse --path-format=absolute --git-dir)" == "$common" ]]; then
    echo "commands.sh: $wt is the main checkout, not a linked worktree" >&2
    exit 1
fi
slug="$(basename "$wt")"

branch="$(git -C "$wt" symbolic-ref --short --quiet HEAD || true)"

force=""
if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    force=" --force"
fi

if [[ "$action" == "archive" ]]; then
    # Tag the branch, or the HEAD commit when the worktree is detached.
    target="${branch:-$(git -C "$wt" rev-parse HEAD)}"
    printf 'git -C %q tag %q %q\n' "$repo" "archive/$slug" "$target"
fi

# Repo-relative path for a worktree inside the repo, else the absolute path.
wt_arg="$wt"
[[ "$wt" == "$repo/"* ]] && wt_arg="${wt#"$repo/"}"
printf 'git -C %q worktree remove%s %q\n' "$repo" "$force" "$wt_arg"
if [[ -n "$branch" ]]; then
    printf 'git -C %q branch -D %q\n' "$repo" "$branch"
fi
