#!/usr/bin/env bats
# Guard against the claude/README.md hook tables drifting from the real files.
# Every JS hook documented in the tables must have a file in claude/hooks/
# (the documented-but-missing direction). hook-runner.js is the module runner,
# not a guard, so present-but-undocumented is intentionally not enforced.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# Backtick-wrapped *.js filenames from the first column of the hook tables.
# Rows look like: | `worktree-guard.js` | Edit, Write, ... | ... |
documented_hook_files() {
    # shellcheck disable=SC2016  # backticks are literal markdown, not expansions
    grep -oE '^\| `[A-Za-z0-9._-]+\.js`' "$DOTFILES_DIR/claude/README.md" | sed -E 's/^\| `//; s/`$//'
}

@test "the hook-table parser actually matches the documented hooks" {
    # Sanity guard: if the table format changes and the parser matches nothing,
    # the drift test below would pass vacuously. Pin known-present hooks.
    run documented_hook_files
    [[ $status -eq 0 ]]
    echo "$output" | grep -qx 'worktree-guard.js'
}

@test "every hook documented in claude/README.md exists in claude/hooks/" {
    local missing=()
    local hook
    while IFS= read -r hook; do
        [[ -z "$hook" ]] && continue
        [[ -f "$DOTFILES_DIR/claude/hooks/$hook" ]] || missing+=("$hook")
    done < <(documented_hook_files)

    if (( ${#missing[@]} > 0 )); then
        printf 'Documented hook has no file in claude/hooks/: %s\n' "${missing[@]}" >&2
        return 1
    fi
}
