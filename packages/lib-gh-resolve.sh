#!/bin/bash
############################
# packages/lib-gh-resolve.sh
# Resolve a real `gh` for MISE_GITHUB_CREDENTIAL_COMMAND.
# Skip the mise shim.
#
# The mise shim can precede every real `gh` on PATH.
# A bare `gh` credential command re-enters that shim forever.
# The credential command must name an absolute, non-shim path.
############################

# Print the first non-mise-shim `gh` in `type -ap` order.
# Return an absolute path, or no output when only shims exist.
resolve_real_gh() {
    local candidate absolute directory name resolved target
    while IFS= read -r candidate; do
        [[ -x "$candidate" ]] || continue
        if [[ "$candidate" == /* ]]; then
            absolute="$candidate"
        else
            directory="${candidate%/*}"
            [[ "$directory" == "$candidate" ]] && directory=.
            name="${candidate##*/}"
            absolute="$(cd -P -- "$directory" && printf '%s/%s' "$PWD" "$name")" || continue
        fi
        resolved="$absolute"
        while [[ -L "$resolved" ]]; do
            target="$(readlink "$resolved")" || break
            if [[ "$target" == /* ]]; then
                resolved="$target"
            else
                directory="${resolved%/*}"
                [[ "$directory" == "$resolved" ]] && directory=.
                resolved="$(cd -P -- "$directory" && printf '%s/%s' "$PWD" "$target")" || break
            fi
        done
        [[ "${resolved##*/}" == "mise" ]] && continue
        printf '%s\n' "$absolute"
        return 0
    done < <(type -ap gh 2>/dev/null)
    return 1
}
