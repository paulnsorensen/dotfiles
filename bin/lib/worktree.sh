# shellcheck shell=bash
# worktree.sh — shared worktree helpers, sourced by bin/ccw-sweep, bin/ccw-find, and bin/wt.
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

# wt_list_nested <wt_path> — emit every git worktree nested inside <wt_path>,
# at any depth and under any directory name (for example
# <wt_path>/.claude/worktrees/x). Paths come from `git worktree list
# --porcelain`. A glob of <wt_path>/.worktrees/*/ adds children that belong to a
# different repo, because the target's own list does not show them. The target
# itself is excluded. One path per line.
wt_list_nested() {
    local wt_path="$1" canon line child seen=$'\n'
    canon="$(cd -P "$wt_path" 2>/dev/null && pwd)" || return 0
    while IFS= read -r line; do
        [[ "$line" == "worktree ${canon}/"* ]] || continue
        line="${line#worktree }"
        seen+="${line}"$'\n'
        printf '%s\n' "$line"
    done < <(git -C "$canon" worktree list --porcelain 2>/dev/null)
    for child in "$canon"/.worktrees/*/; do
        [[ -d "$child" ]] || continue
        [[ -e "${child}.git" ]] || continue
        child="${child%/}"
        [[ "$seen" == *$'\n'"${child}"$'\n'* ]] && continue
        printf '%s\n' "$child"
    done
}

# wt_repo_name <repo-root> — the repository name from the origin URL
# (git@github.com:o/easy-cheese.git -> easy-cheese), else the checkout dir name.
wt_repo_name() {
    local url name=""
    url="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$url" ]]; then
        name="${url%/}"
        name="${name%.git}"
        name="${name##*/}"
        name="${name##*:}"
    fi
    if [[ -z "$name" ]]; then
        name="${1%/}"
        name="${name##*/}"
    fi
    printf '%s\n' "$name"
}

# wt_regen_select <repo-name> <entry>... — print the regenerable entries that
# apply to <repo-name>, one per line. "name<TAB><glob>" matches any path
# component. "path<TAB><glob>" matches from the worktree root: the entry has a
# "/", and a leading "/" is dropped. "<repo>:<pattern>" applies to that repo only.
wt_regen_select() {
    local repo="$1" entry pat
    shift
    for entry in "$@"; do
        pat="$entry"
        if [[ "$entry" == *:* ]]; then
            [[ "${entry%%:*}" == "$repo" ]] || continue
            pat="${entry#*:}"
        fi
        if [[ "$pat" == */* ]]; then
            pat="${pat#/}"
            [[ -n "$pat" ]] && printf 'path\t%s\n' "$pat"
        elif [[ -n "$pat" ]]; then
            printf 'name\t%s\n' "$pat"
        fi
    done
    return 0
}

# wt_path_under <relative-path> <glob> — exit 0 when the path matches the glob
# or lies under a match (website/content/docs/x.md is under website/content/docs).
wt_path_under() {
    # shellcheck disable=SC2053  # $2 is a glob on purpose; [[ ]] never expands it to files
    [[ "$1" == $2 || "$1" == $2/* ]]
}

# wt_cheese_class <path> — classify one file under .cheese/ (<path> is relative
# to .cheese/). Exit 1 for throwaway: a file under cut/ or a review or scratch
# dir, or a loose top-level file other than a wheypoint record. Exit 2 for a
# cook/ or press/ report: throwaway once the branch is merged, keep-worthy
# before. Exit 0 for keep-worthy: wheypoint*/wp-intent* records and every other
# dir, known or not.
wt_cheese_class() {
    local rel="$1"
    if [[ "$rel" != */* ]]; then
        case "$rel" in
            wheypoint*|wp-intent*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    case "${rel%%/*}" in
        age|plate|affinage|cure|cut|reviews|press-history|press-decisions|scratch|tmp) return 1 ;;
        cook|press) return 2 ;;
    esac
    return 0
}

# wt_cheese_archive_dir <base> <repo> <slug> <head-sha> — echo the first free
# copy destination: <base>/<repo>/<slug>, then <slug>-<sha8>, then
# <slug>-<sha8>-<n> from n=2.
wt_cheese_archive_dir() {
    local dest="$1/$2/$3" base n=2
    if [[ -e "$dest" || -L "$dest" ]]; then
        base="${dest}-${4:0:8}"
        dest="$base"
        while [[ -e "$dest" || -L "$dest" ]]; do
            dest="${base}-${n}"
            n=$((n + 1))
        done
    fi
    printf '%s\n' "$dest"
}

# wt_cheese_tracked_changed <worktree> — exit 0 when a tracked or staged file
# under .cheese/ differs from HEAD and is still on disk. Deleted files have
# nothing to copy, so they do not count.
wt_cheese_tracked_changed() {
    [[ -n "$(git -C "$1" diff --name-only --diff-filter=d HEAD -- .cheese 2>/dev/null)" ]]
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
    # .cheese/ notes — gitignored, so ls-files --exclude-standard above never
    # sees them, but a handoff note there is still work to lose.
    if [[ -n "$(git -C "$child" ls-files --others -- .cheese 2>/dev/null)" ]]; then
        return 0
    fi
    # Unmerged commits: ahead of the remote default branch.
    # Deliberately omits the gh squash-merge check that check_worktree runs: a
    # squash-merged child still ahead of origin/default is flagged as blocking.
    # That over-blocks (never under-blocks), which is the safe bias here.
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

# wt_main_checkout <worktree> — print the main worktree of <worktree>'s repo:
# the first `git worktree list --porcelain` entry. That is the checkout for a
# normal or separate-gitdir repo and the repo dir for a bare repo; never derive
# it with `dirname` of the common dir. Exit 1 outside a git repo.
wt_main_checkout() {
    local line=""
    IFS= read -r line < <(git -C "$1" worktree list --porcelain 2>/dev/null) || true
    [[ "$line" == "worktree "* ]] || return 1
    printf '%s\n' "${line#worktree }"
}

# wt_is_locked <worktree> — exit 0 when `git worktree lock` holds it (git keeps
# a `locked` file in the worktree's own admin dir).
wt_is_locked() {
    local git_dir
    git_dir="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
    [[ -e "${git_dir}/locked" ]]
}

# wt_archive_tag <repo> <slug> <head-sha> — echo the first archive tag that is
# free or already points at <head-sha>: archive/<slug>, then
# archive/<slug>-<sha8>, then archive/wt-<sha12> (when <slug> is not a valid
# ref name). Two worktrees with one basename so get distinct tags. Exit 1 when
# none is usable.
wt_archive_tag() {
    local repo="$1" slug="$2" head="$3" tag
    for tag in "archive/${slug}" "archive/${slug}-${head:0:8}" "archive/wt-${head:0:12}"; do
        git check-ref-format "refs/tags/${tag}" || continue
        if ! git -C "$repo" show-ref --verify --quiet "refs/tags/${tag}" \
            || [[ "$(git -C "$repo" rev-parse --verify --quiet "refs/tags/${tag}^{commit}")" == "$head" ]]; then
            echo "$tag"
            return 0
        fi
    done
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

            if [[ -n "$f_slug" && "${child##*/}" != *"$f_slug"* ]]; then
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
