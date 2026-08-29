#!/usr/bin/env bash
# commands.sh <repo-root> <slug> <remove|archive> — print (never execute) the
# recommended cleanup commands for one triaged worktree. Derives the branch
# from the worktree itself and adds --force when the tree is dirty.
set -euo pipefail

repo="${1:?usage: commands.sh <repo-root> <slug> <remove|archive>}"
slug="${2:?usage: commands.sh <repo-root> <slug> <remove|archive>}"
action="${3:?usage: commands.sh <repo-root> <slug> <remove|archive>}"

wt="$repo/.worktrees/$slug"
[[ -d "$wt" ]] || { echo "commands.sh: no worktree at $wt" >&2; exit 1; }

branch="$(git -C "$wt" symbolic-ref --short --quiet HEAD || true)"

force=""
if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    force=" --force"
fi

case "$action" in
    archive)
        if [[ -z "$branch" ]]; then
            echo "commands.sh: $wt is on a detached HEAD — nothing to tag" >&2
            exit 1
        fi
        printf 'git -C %q tag archive/%s %q\n' "$repo" "$slug" "$branch"
        ;;
    remove) ;;
    *)
        echo "commands.sh: unknown action '$action' (want remove|archive)" >&2
        exit 2
        ;;
esac

printf 'git -C %q worktree remove%s .worktrees/%s\n' "$repo" "$force" "$slug"
if [[ -n "$branch" ]]; then
    printf 'git -C %q branch -D %q\n' "$repo" "$branch"
fi
