#!/usr/bin/env bash
# discover.sh — Profile lookup across per-repo and global sources.
#
# Search order (first match wins):
#   1. $PWD/.agent-profiles/<name>/         (per-repo, takes precedence)
#   2. $DOTFILES_DIR/profiles/<name>/       (global library)
#
# AP_EXTRA_SEARCH_PATHS (colon-separated) is consulted before either of
# the above — lets tests inject a fixture root and lets `ap install
# --profile-src DIR` plug in an ad-hoc location without copying files.

set -euo pipefail

ap_search_roots() {
    local roots=()
    if [[ -n "${AP_EXTRA_SEARCH_PATHS:-}" ]]; then
        local IFS=:
        for r in $AP_EXTRA_SEARCH_PATHS; do
            [[ -n "$r" ]] && roots+=("$r")
        done
    fi
    roots+=("$PWD/.agent-profiles")
    roots+=("${DOTFILES_DIR:-$HOME/Dev/dotfiles}/profiles")
    printf '%s\n' "${roots[@]}"
}

ap_find_profile_dir() {
    local name="$1"
    [[ -n "$name" ]] || { echo "ap_find_profile_dir: empty name" >&2; return 1; }

    local root candidate
    while IFS= read -r root; do
        candidate="$root/$name"
        if [[ -d "$candidate" && -f "$candidate/profile.yaml" ]]; then
            (cd "$candidate" && pwd)
            return 0
        fi
    done < <(ap_search_roots)
    return 1
}

# Print "<name>\t<source-root>" for every profile discoverable from the
# search roots. A per-repo profile shadows a global one with the same
# name; only the winning entry is emitted.
ap_list_profiles() {
    local root entry name seen=""
    while IFS= read -r root; do
        [[ -d "$root" ]] || continue
        for entry in "$root"/*/; do
            [[ -d "$entry" ]] || continue
            [[ -f "$entry/profile.yaml" ]] || continue
            name=$(basename "${entry%/}")
            case $'\n'"$seen"$'\n' in
                *$'\n'"$name"$'\n'*) continue ;;
            esac
            seen="${seen:+$seen$'\n'}$name"
            printf '%s\t%s\n' "$name" "$root"
        done
    done < <(ap_search_roots)
}
