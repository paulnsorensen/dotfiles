#!/bin/bash
############################
# packages/lib-gh-resolve.sh
# Resolve a real `gh` binary for MISE_GITHUB_CREDENTIAL_COMMAND, skipping the
# mise shim.
#
# mise's shims dir puts a `gh` shim ahead of any real gh on PATH. Naming a
# bare `gh` in the credential command makes mise's `sh -c 'gh auth token'`
# re-enter the shim, which re-enters mise, forever — the fork chain that
# wedged crabbot on 2026-09-28 (1,810-deep). The credential command must name
# an absolute, non-shim gh instead.
############################

# Print the absolute path of the first non-mise-shim `gh` on PATH (`type -ap`
# order, so it agrees with what a bare `gh` invocation would resolve to,
# minus the shim), or fail with no output if only mise shims are found.
resolve_real_gh() {
    local candidate resolved
    while IFS= read -r candidate; do
        [[ -x "$candidate" ]] || continue
        resolved="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        [[ "$(basename "$resolved")" == "mise" ]] && continue
        printf '%s\n' "$candidate"
        return 0
    done < <(type -ap gh 2>/dev/null)
    return 1
}
