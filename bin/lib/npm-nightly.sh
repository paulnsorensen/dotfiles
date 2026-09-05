# shellcheck shell=bash
# npm-nightly.sh — shared helpers for the fork-nightly installers
# (chezmoi/.chezmoiscripts/run_after_install-{tilth,hallouminate}.sh.tmpl).
#
# Both installers keep a scoped npm package (@paulnsorensen/<tool>-nightly) on
# latest, and both face the same hazard: a second npm global prefix (homebrew
# node beside mise node) holds its own copy of that package. The active npm
# never updates the other prefix's copy, and whichever prefix sits first on
# PATH wins the bin — so a stale copy can pin an MCP to an old binary while
# `dots sync` reports success. Twice now (tilth 2026-08-25, hallouminate
# 2026-08-31) that shadow silently wedged an MCP; see
# [[architecture/config-drift]] § "second npm global prefix shadows a fork
# nightly". Warning proved too weak — the warning scrolled past and the shadow
# survived 34 nightlies — so the prune below removes the copy instead.
#
# Functions only — no top-level side effects, so sourcing is safe. Written for
# bash 3.2 (macOS /bin/bash): no associative arrays, no ${var,,}.

# npm_nightly_resolve_path <path> — echo <path> with every symlink resolved.
# Used instead of GNU-only `readlink -f`, which macOS's BSD readlink lacks.
# The trailing `cd -P` fully canonicalizes the directory, so on macOS a
# $TMPDIR path comes back under /private/var. That canonicalization is
# load-bearing (it is how a bin symlink leads back to its node_modules tree),
# so callers and tests must match it rather than weaken it.
npm_nightly_resolve_path() {
    local path="$1" target
    while [[ -L "$path" ]]; do
        target="$(readlink "$path")" || return 1
        if [[ "$target" == /* ]]; then
            path="$target"
        else
            path="$(dirname "$path")/$target"
        fi
    done
    cd -P "$(dirname "$path")" && printf '%s/%s\n' "$PWD" "$(basename "$path")"
}

# npm_nightly_prune_shadows <pkg> <bin_name> — remove every copy of <pkg> that
# a npm global prefix other than the active one exposes as <bin_name> on PATH.
#
# Only copies whose resolved path lies inside a `node_modules/<pkg>/` tree are
# touched, so an upstream package or a cargo build that happens to expose the
# same bin is left alone (those get their own warnings in the callers).
#
# Returns 0 even when a removal fails: a run_after installer must not abort the
# rest of `dots sync` over a shadow it could not clear, and the next sync
# retries. Prints what it removed so the action is never silent.
npm_nightly_prune_shadows() {
    local pkg="$1" bin_name="$2"
    local npm_prefix candidate resolved shadow_root shadow_npm
    local pruned=$'\n'

    npm_prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -z "$npm_prefix" ]]; then
        return 0
    fi
    # Every other prefix looks like a shadow when the active prefix is not a
    # real directory (an npm stub, a half-provisioned node). Refuse to judge —
    # and therefore to delete — against a prefix that does not exist.
    if [[ ! -d "$npm_prefix" ]]; then
        echo "⚠ active npm prefix '$npm_prefix' is not a directory — skipping the $pkg shadow prune." >&2
        return 0
    fi
    # Canonicalize the active prefix exactly as npm_nightly_resolve_path
    # canonicalizes each candidate. Without this a symlinked prefix (macOS
    # /var -> /private/var, a symlinked homebrew root) never matches its own
    # resolved copies, and the prune deletes the ACTIVE install instead of the
    # shadow. Covered by "leaves the active prefix's own copy alone".
    npm_prefix="$(cd -P "$npm_prefix" && pwd)" || return 0

    while IFS= read -r candidate; do
        resolved="$(npm_nightly_resolve_path "$candidate" 2>/dev/null || true)"
        [[ "$resolved" == */node_modules/"$pkg"/* ]] || continue
        [[ "$resolved" != "$npm_prefix"/* ]] || continue
        shadow_root="${resolved%%/node_modules/*}"

        # One prefix can expose the bin by several PATH entries (bin dir plus
        # shim dir). Prune it once.
        case "$pruned" in
            *$'\n'"$shadow_root"$'\n'*) continue ;;
        esac
        pruned="$pruned$shadow_root"$'\n'

        shadow_npm="${shadow_root%/lib}/bin/npm"
        if [[ ! -x "$shadow_npm" ]]; then
            echo "⚠ $candidate resolves into a second npm prefix ($shadow_root) but '$shadow_npm' is not executable — remove that copy by hand so '$bin_name' resolves to the nightly fork." >&2
            continue
        fi

        echo "Removing stale $pkg from second npm prefix $shadow_root (it shadowed '$bin_name' on PATH)..."
        if "$shadow_npm" rm -g "$pkg" >/dev/null 2>&1; then
            echo "✓ removed the shadow copy at $shadow_root"
        else
            echo "⚠ '$shadow_npm rm -g $pkg' failed — remove that copy by hand so '$bin_name' resolves to the nightly fork." >&2
        fi
    done < <(type -ap "$bin_name" 2>/dev/null || true)

    return 0
}
