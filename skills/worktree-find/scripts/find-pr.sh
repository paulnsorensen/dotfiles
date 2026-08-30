#!/usr/bin/env bash
# find-pr.sh [ccw-find flags...] — join open GitHub PRs to local worktrees by
# head branch. Extra flags narrow the candidate set via ccw-find; with none,
# all worktrees under ~/Dev are candidates. One `gh pr list` per unique origin.
# Output per match: path<TAB>branch<TAB>PR #<n><TAB><title><TAB><url>
set -euo pipefail

[[ $# -eq 0 ]] && set -- --root "${HOME}/Dev"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/findpr.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

found=0
while IFS=$'\t' read -r wt meta; do
    [[ -d "$wt" ]] || continue
    branch="${meta%% (*}"
    [[ "$branch" == "(detached)" ]] && continue

    origin_url="$(git -C "$wt" remote get-url origin 2>/dev/null || true)"
    [[ -z "$origin_url" ]] && continue
    slug="$(sed -E 's#^(git@[^:]+:|ssh://git@[^/]+/|https?://[^/]+/)##; s#\.git$##' <<<"$origin_url")"

    cache="$tmp/${slug//\//__}.json"
    if [[ ! -f "$cache" ]]; then
        gh pr list -R "$slug" --state open \
            --json number,headRefName,title,url >"$cache" 2>/dev/null \
            || echo '[]' >"$cache"
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        found=1
        printf '%s\t%s\t%s\n' "$wt" "$branch" "$line"
    done < <(jq -r --arg b "$branch" \
        '.[] | select(.headRefName == $b) | "PR #\(.number)\t\(.title)\t\(.url)"' \
        "$cache")
done < <(ccw-find "$@")

if (( ! found )); then
    echo "No open PR matches a local worktree (searched: ccw-find $*)."
fi
