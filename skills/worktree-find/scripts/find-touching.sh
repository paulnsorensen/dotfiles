#!/usr/bin/env bash
# find-touching.sh <pathspec> [ccw-find flags...] — worktrees whose uncommitted
# diff or unmerged commits touch <pathspec> (a git pathspec, e.g. 'src/auth/*'
# or '*login*'). Extra flags narrow the candidate set via ccw-find; with none,
# all worktrees under ~/Dev are candidates.
# Output per match: path<TAB>branch (age), then the touched files indented.
set -euo pipefail

spec="${1:?usage: find-touching.sh <pathspec> [ccw-find flags...]}"
shift
[[ $# -eq 0 ]] && set -- --root "${HOME}/Dev"

found=0
while IFS=$'\t' read -r wt meta; do
    [[ -d "$wt" ]] || continue

    uncommitted="$(git -C "$wt" diff --name-only HEAD -- "$spec" 2>/dev/null || true)"

    committed=""
    base_ref="$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [[ -n "$base_ref" ]]; then
        committed="$(git -C "$wt" log --format= --name-only "${base_ref}..HEAD" -- "$spec" 2>/dev/null || true)"
    fi

    files="$(printf '%s\n%s\n' "$uncommitted" "$committed" | grep -v '^$' | sort -u || true)"
    [[ -z "$files" ]] && continue

    found=1
    printf '%s\t%s\n' "$wt" "$meta"
    awk 'NR<=8 {print "    " $0} END {if (NR>8) print "    … (+" NR-8 " more)"}' <<<"$files"
done < <(ccw-find "$@")

if (( ! found )); then
    echo "No worktree touches '${spec}' (searched: ccw-find $*)."
fi
