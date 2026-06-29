# shellcheck shell=bash
# worktree.sh — shared worktree helpers, sourced by bin/ccw-sweep and bin/ccw-find.
#
# Parallels the .sync <-> .sync-lib.sh "lib beside script" precedent, scoped to
# bin/. Every consumer sources this via its own resolved dir; bats tests source
# it directly. Functions only — no top-level side effects, so sourcing is safe.

# Resolve the repo's default branch (main / master / trunk / …) from
# refs/remotes/origin/HEAD. If that's not set, probe the conventional
# alternatives explicitly before defaulting — falling back to a literal
# "main" against a repo whose actual default is "master" or "trunk" would
# silently make every worktree look NOT-merged.
# Refs are shared across a repo's worktrees, so a worktree path works as the
# -C target here just as the main checkout does.
# Echoes the branch name without the "origin/" prefix and returns 0 on
# success; echoes nothing and returns 1 when no remote default resolves,
# so the caller can skip the repo rather than guess.
resolve_default_branch() {
    local repo_root="$1"
    local head_ref candidate
    head_ref="$(git -C "$repo_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [[ -n "$head_ref" ]]; then
        echo "${head_ref#refs/remotes/origin/}"
        return 0
    fi
    for candidate in main master trunk develop; do
        if git -C "$repo_root" rev-parse --verify --quiet "refs/remotes/origin/$candidate" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
    return 1
}

# wt_list_nested <wt_path> — emit nested child worktree paths one level under
# <wt_path>/.worktrees/*. That is the only basis worktrees are created on:
# ccw-init writes <repo>/.worktrees/<slug>, and ccw()'s nested picker
# (zsh/claude.zsh) globs .worktrees/* (and .worktrees/*/.worktrees/*). Only
# paths that are real git worktrees (have a .git entry) are emitted; one path
# per line.
wt_list_nested() {
    local wt_path="$1" child
    for child in "$wt_path"/.worktrees/*/; do
        [[ -d "$child" ]] || continue
        [[ -e "${child}.git" ]] || continue
        printf '%s\n' "${child%/}"
    done
}

# wt_child_blocks_removal <child_path> — exit 0 (blocks) when the nested child
# has work that must not be lost: uncommitted changes, staged changes, untracked
# files, or commits not yet on its remote default branch. Exit 1 when the child
# is clean and fully merged (safe to drop with its parent). Predicates mirror
# ccw-sweep's check_worktree (git diff [--cached], ls-files --others, rev-list
# against origin/<default>).
wt_child_blocks_removal() {
    local child="$1"

    # Uncommitted (unstaged) changes.
    if ! git -C "$child" diff --quiet HEAD 2>/dev/null; then
        return 0
    fi
    # Staged but uncommitted changes.
    if ! git -C "$child" diff --cached --quiet 2>/dev/null; then
        return 0
    fi
    # Untracked files.
    if [[ -n "$(git -C "$child" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        return 0
    fi
    # Unmerged commits: ahead of the remote default branch.
    local default
    if default="$(resolve_default_branch "$child")" && [[ -n "$default" ]]; then
        local ahead
        ahead="$(git -C "$child" rev-list --count "origin/${default}..HEAD" 2>/dev/null || echo 0)"
        if (( ahead > 0 )); then
            return 0
        fi
    fi
    return 1
}

# wt_find [--root DIR] [--branch S] [--slug S] [--repo NAME] [--stale DAYS]
# Mechanical cross-repo worktree search under DIR (default ~/Dev), discovered via
# the <repo>/.worktrees/<slug>/ convention (same glob basis as ccw()). Emits one
# tab-separated `path<TAB>status` row per matching worktree, where status is
# "<branch> (<relative-age>)". All provided criteria are ANDed:
#   --branch/--slug : substring match on the worktree branch / dir name
#   --repo          : exact match on the repo directory name
#   --stale DAYS    : only worktrees whose last commit is older than DAYS days
wt_find() {
    local root="${HOME}/Dev"
    local f_branch="" f_slug="" f_repo="" f_stale=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)   root="$2"; shift 2 ;;
            --branch) f_branch="$2"; shift 2 ;;
            --slug)   f_slug="$2"; shift 2 ;;
            --repo)   f_repo="$2"; shift 2 ;;
            --stale)  f_stale="$2"; shift 2 ;;
            *) echo "wt_find: unknown option: $1" >&2; return 2 ;;
        esac
    done

    if [[ -n "$f_stale" && ! "$f_stale" =~ ^[0-9]+$ ]]; then
        echo "wt_find: --stale expects a number of days, got: $f_stale" >&2
        return 2
    fi

    [[ -d "$root" ]] || return 0

    local now wt_root repo_root repo_name child branch last_epoch last_rel
    now="$(date +%s)"

    while IFS= read -r wt_root; do
        repo_root="$(dirname "$wt_root")"
        repo_name="$(basename "$repo_root")"
        if [[ -n "$f_repo" && "$repo_name" != "$f_repo" ]]; then
            continue
        fi
        for child in "$wt_root"/*/; do
            [[ -d "$child" ]] || continue
            [[ -e "${child}.git" ]] || continue
            child="${child%/}"

            if [[ -n "$f_slug" && "$(basename "$child")" != *"$f_slug"* ]]; then
                continue
            fi

            branch="$(git -C "$child" symbolic-ref --short --quiet HEAD 2>/dev/null || echo '(detached)')"
            if [[ -n "$f_branch" && "$branch" != *"$f_branch"* ]]; then
                continue
            fi

            if [[ -n "$f_stale" ]]; then
                last_epoch="$(git -C "$child" log -1 --format='%ct' 2>/dev/null || echo 0)"
                if (( last_epoch == 0 || (now - last_epoch) < f_stale * 86400 )); then
                    continue
                fi
            fi

            last_rel="$(git -C "$child" log -1 --format='%cr' 2>/dev/null || echo 'unknown')"
            printf '%s\t%s (%s)\n' "$child" "$branch" "$last_rel"
        done
    done < <(find "$root" -maxdepth 3 -type d -name '.worktrees' 2>/dev/null)
}
