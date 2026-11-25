#!/usr/bin/env bash

find_pr_main() (
    local shim="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"
    [[ -n "${DOTFILES_DIR:-}" ]] && PATH="$PATH:$DOTFILES_DIR/bin"
    [[ -d "$shim" ]] && PATH="$PATH:$shim"

    if ! command -v wt-find >/dev/null; then
        printf "Required command 'wt-find' is unavailable.\n" >&2
        return 1
    fi

    [[ $# -eq 0 ]] && set -- --root "${HOME}/Dev"

    local tmp wt meta branch origin_url slug cache line found=0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/findpr.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT

    if ! wt-find "$@" > "$tmp/worktrees"; then
        printf 'Worktree discovery failed: wt-find %s\n' "$*" >&2
        return 1
    fi

    while IFS=$'\t' read -r wt meta; do
        [[ -d "$wt" ]] || continue
        branch="${meta%% (*}"
        [[ "$branch" == "(detached)" ]] && continue

        origin_url="$(git -C "$wt" remote get-url origin 2>/dev/null || true)"
        [[ -z "$origin_url" ]] && continue
        slug="$(sed -E 's#^(git@[^:]+:|ssh://git@[^/]+/|https?://[^/]+/)##; s#\.git$##' <<<"$origin_url")"
        cache="$tmp/${slug//\//__}.json"
        if [[ ! -f "$cache" ]]; then
            for dep in gh jq; do
                if ! command -v "$dep" >/dev/null; then
                    printf "Required command '%s' is unavailable.\n" "$dep" >&2
                    return 1
                fi
            done
            if ! gh pr list -R "$slug" --state open \
                --json number,headRefName,title,url > "$cache"; then
                printf 'GitHub PR lookup failed for %s.\n' "$slug" >&2
                return 1
            fi
            if ! jq -e 'type == "array" and all(.[]?; (.number | type) == "number" and (.headRefName | type) == "string" and (.title | type) == "string" and (.url | type) == "string")' "$cache" >/dev/null; then
                printf 'Invalid GitHub PR response for %s.\n' "$slug" >&2
                return 1
            fi
        fi

        if ! jq -r --arg b "$branch" \
            '.[]? | select(.headRefName == $b) | "PR #\(.number)\t\(.title)\t\(.url)"' \
            "$cache" > "$tmp/matches"; then
            printf 'GitHub PR response decode failed for %s.\n' "$slug" >&2
            return 1
        fi
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            found=1
            printf '%s\t%s\t%s\n' "$wt" "$branch" "$line"
        done < "$tmp/matches"
    done < "$tmp/worktrees"

    if (( ! found )); then
        echo "No open PR matches a local worktree (searched: wt-find $*)."
    fi
)
