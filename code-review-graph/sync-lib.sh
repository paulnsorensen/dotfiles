#!/bin/bash
# code-review-graph/sync-lib.sh
# Testable functions for the code-review-graph daemon sync.
# Sourced by .sync and by tests/code-review-graph.bats.

# Emit tab-separated <path>\t<alias> lines for each git repo found
# directly under <root>. Skips: non-dirs, symlinks, dotfiles (.foo),
# and any directory without a .git entry.
#
# Usage: discover_dev_repos <root_dir>
discover_dev_repos() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    local entry name
    for entry in "$root"/*; do
        [[ -d "$entry" ]] || continue
        [[ -L "$entry" ]] && continue
        name="${entry##*/}"
        [[ "$name" == .* ]] && continue
        [[ -e "$entry/.git" ]] || continue
        printf '%s\t%s\n' "$entry" "$name"
    done
}

# Given the desired repos (tab-separated path\talias on stdin) and the
# currently-watched repos (same format on FD 3), emit two streams:
#   ADD\t<path>\t<alias>      for repos in desired but not current
#   REMOVE\t<alias>           for repos in current but not desired
#
# Usage: diff_repo_sets <(desired) <(current)
diff_repo_sets() {
    local desired_file="$1" current_file="$2"
    local d_path d_alias _c_path c_alias
    while IFS=$'\t' read -r d_path d_alias; do
        [[ -z "$d_alias" ]] && continue
        if ! grep -qE "^[^	]+	${d_alias}$" "$current_file" 2>/dev/null; then
            printf 'ADD\t%s\t%s\n' "$d_path" "$d_alias"
        fi
    done < "$desired_file"
    while IFS=$'\t' read -r _c_path c_alias; do
        [[ -z "$c_alias" ]] && continue
        if ! grep -qE "^[^	]+	${c_alias}$" "$desired_file" 2>/dev/null; then
            printf 'REMOVE\t%s\n' "$c_alias"
        fi
    done < "$current_file"
}

# Render the launchd plist template, substituting __HOME__ and __CRG_BIN__.
# Reads template path on $1, writes resolved plist to $2.
render_plist() {
    local template="$1" target="$2" home_dir="${3:-$HOME}" crg_bin="${4:-}"
    [[ -f "$template" ]] || return 1
    [[ -n "$crg_bin" ]] || crg_bin="$(command -v code-review-graph || true)"
    [[ -n "$crg_bin" ]] || return 2
    sed -e "s|__HOME__|${home_dir}|g" -e "s|__CRG_BIN__|${crg_bin}|g" "$template" > "$target"
}
