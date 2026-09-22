#!/usr/bin/env bash
# Detect drift between source broker assets and the root-owned runtime copy.
# This library reports only; provisioning remains an explicit operator action.

agent_secret_broker_status() {
    local source_root="${1:-${DOTFILES_DIR:-$HOME/Dev/dotfiles}}"
    local install_root="${2:-${AGENT_SECRET_INSTALL_ROOT:-/usr/local/libexec/dotfiles}}"
    local mapping installed_name source_file installed_file source_hash installed_hash
    local missing=0 checked=0 stale_names=""
    local assets_lib="$source_root/bin/lib/agent-secret-assets.sh"

    command -v shasum >/dev/null 2>&1 || {
        printf '%s\n' "uncheckable: shasum is unavailable"
        return 2
    }

    [[ -r "$assets_lib" ]] || {
        printf '%s\n' "uncheckable: source asset missing: bin/lib/agent-secret-assets.sh"
        return 2
    }
    # shellcheck source=agent-secret-assets.sh
    source "$assets_lib"

    while IFS='|' read -r mapping installed_name _; do
        [[ -n "$mapping" ]] || continue
        source_file="$source_root/$mapping"
        installed_file="$install_root/$installed_name"
        [[ -f "$source_file" ]] || {
            printf '%s\n' "uncheckable: source asset missing: $mapping"
            return 2
        }
        if [[ ! -f "$installed_file" ]]; then
            missing=1
            stale_names+=" ${installed_file##*/}"
            continue
        fi
        checked=$((checked + 1))
        source_hash="$(shasum -a 256 "$source_file" | awk '{print $1}')" || return 2
        installed_hash="$(shasum -a 256 "$installed_file" | awk '{print $1}')" || return 2
        if [[ "$source_hash" != "$installed_hash" ]]; then
            stale_names+=" ${installed_file##*/}"
        fi
    done <<<"$AGENT_SECRET_RUNTIME_ASSETS"

    if [[ "$checked" -eq 0 && "$missing" -eq 1 ]]; then
        printf '%s\n' "not-installed"
        return 0
    fi
    if [[ "$missing" -eq 1 || -n "$stale_names" ]]; then
        printf 'stale:%s\n' "$stale_names"
        return 1
    fi
    printf '%s\n' "current"
}
