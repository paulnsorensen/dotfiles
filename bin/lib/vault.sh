# shellcheck shell=bash
# vault.sh — sourced library: detect the per-machine secret vault (1Password
# or Bitwarden Secrets Manager) and materialize its secrets into a cached
# .env-format file consumed by every loader (agents/mcp/sync.sh,
# zsh/core.zsh, bin/cc-env-exec, agent-profile's ap render). Deep module —
# the only place that knows a vault exists.
#
# Functions only — no top-level side effects, so sourcing is safe.

vault_detect() {
    if command -v op &>/dev/null; then
        echo onepassword
    elif command -v bws &>/dev/null; then
        echo bitwarden
    else
        echo "vault: neither 'op' (1Password) nor 'bws' (Bitwarden Secrets Manager) found." >&2
        echo "vault: run bin/vault-provision to set up a vault." >&2
        return 1
    fi
}

vault_secrets_file() {
    echo "${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/secrets.env"
}

vault_token_file() {
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/bws-token"
}

# Token storage is platform-specific. macOS uses the Keychain (Bitwarden's own
# documented pattern). A headless Linux box has no keyring daemon, so libsecret
# is unavailable and the token lives in a 0600 file instead; this refuses to
# read one that is group- or world-readable rather than leaking it silently.
vault_token() {
    local file mode
    if [[ "$(uname -s)" == Darwin ]]; then
        security find-generic-password -w -s BWS_ACCESS_TOKEN -a "$USER" 2>/dev/null || {
            echo "vault: no Bitwarden access token in Keychain (service BWS_ACCESS_TOKEN)." >&2
            echo "vault: run bin/vault-provision to store one." >&2
            return 1
        }
        return 0
    fi

    file="$(vault_token_file)"
    if [[ ! -f "$file" ]]; then
        echo "vault: no Bitwarden access token at $file." >&2
        echo "vault: run bin/vault-provision to store one." >&2
        return 1
    fi
    mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)"
    if [[ "$mode" != 600 ]]; then
        echo "vault: $file must be mode 600, found ${mode:-unknown}; refusing to read it." >&2
        return 1
    fi
    cat "$file"
}

# Resolve the project id from the environment, falling back to the toggles
# file. Both vault_provisioned and vault_materialize MUST agree on this: if
# provisioned() only checked the environment while materialize() read the
# file, a provisioned machine whose id lives only in the file would be judged
# unprovisioned and silently skipped, leaving a stale cache behind.
_vault_project_id() {
    local env_file id
    if [[ -n "${BWS_PROJECT_ID:-}" ]]; then
        echo "$BWS_PROJECT_ID"
        return 0
    fi
    env_file="${DOTFILES_DIR:-$HOME/Dev/dotfiles}/.env"
    [[ -f "$env_file" ]] || return 1
    id="$(sed -n 's/^BWS_PROJECT_ID=//p' "$env_file" | tail -n1)"
    [[ -n "$id" ]] || return 1
    echo "$id"
}

# True when this machine has everything a materialize attempt needs. Lets
# callers tell "vault never set up" (warn, keep going) apart from "vault set up
# but broken" (fail loud) — without that split, `dots sync` cannot bootstrap a
# machine that has no vault yet.
vault_provisioned() {
    local backend
    backend="$(vault_detect 2>/dev/null)" || return 1
    [[ "$backend" == onepassword ]] && return 0
    _vault_project_id >/dev/null 2>&1 || return 1
    vault_token >/dev/null 2>&1
}

# ISOLATED SEAM — bws's `-o env` exact quoting/escaping is UNVERIFIED against
# values containing quotes, newlines, or '#'. This is the ONLY function that
# knows the fetch format; swap its body to
# `bws secret list "$BWS_PROJECT_ID" -o json | jq -r '.[] | "\(.key)=\(.value)"'`
# without touching anything else in this file if that proves unsafe.
_vault_fetch_bitwarden() {
    bws secret list "$BWS_PROJECT_ID" -o env
}

_vault_fetch_onepassword() {
    op inject -i "$1"
}

# Writes the cache under umask 077, via temp file + validate + atomic mv, so
# a partial/empty vault response cannot clobber a good cache. The response is
# reduced to a closed set: only keys named in secrets/secrets.env.tmpl are
# kept, every one of them must be present and non-empty, and any response
# line that isn't a recognized "KEY=value" pair (an unlisted key, or a
# value that split across lines because it embedded a newline) fails the
# whole materialize. On failure the prior cache is untouched and this
# returns non-zero naming the problem.
vault_materialize() {
    local backend tmpl out tmp prev_umask token key line missing=()
    (( ${BASH_VERSINFO[0]:-0} >= 4 )) || {
        echo "vault: materialize requires bash >= 4 (found ${BASH_VERSINFO[0]:-0}); this shell is likely macOS /bin/bash 3.2 — re-run under Homebrew bash" >&2
        return 1
    }
    local -A tmpl_keys resp
    tmpl="${DOTFILES_DIR:-$HOME/Dev/dotfiles}/secrets/secrets.env.tmpl"
    out="$(vault_secrets_file)"
    [[ -f "$tmpl" ]] || { echo "vault: template not found: $tmpl" >&2; return 1; }

    backend="$(vault_detect)" || return 1
    mkdir -p "$(dirname "$out")" || return 1

    prev_umask="$(umask)"
    tmp=""
    trap 'trap - RETURN; umask "$prev_umask"; [[ -n "$tmp" && -f "$tmp" ]] && rm -f "$tmp"' RETURN
    umask 077
    tmp="$(mktemp "${out}.XXXXXX")" || return 1

    case "$backend" in
        bitwarden)
            BWS_PROJECT_ID="$(_vault_project_id)" \
                || { echo "vault: BWS_PROJECT_ID is unset (run bin/vault-provision to set it)" >&2; return 1; }
            token="$(vault_token)" || return 1
            BWS_ACCESS_TOKEN="$token" _vault_fetch_bitwarden > "$tmp" || { echo "vault: bws fetch failed" >&2; return 1; }
            ;;
        onepassword)
            _vault_fetch_onepassword "$tmpl" > "$tmp" || { echo "vault: op inject failed" >&2; return 1; }
            ;;
    esac

    while IFS='=' read -r key _; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        tmpl_keys["$key"]=1
    done < "$tmpl"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        if [[ "$line" != "$key="* || -z "${tmpl_keys[$key]:-}" ]]; then
            echo "vault: materialize failed, unexpected or malformed entry in vault response" >&2
            return 1
        fi
        resp["$key"]="${line#*=}"
    done < "$tmp"

    for key in "${!tmpl_keys[@]}"; do
        [[ -n "${resp[$key]:-}" ]] || missing+=("$key")
    done

    if (( ${#missing[@]} > 0 )); then
        echo "vault: materialize failed, missing/empty keys: ${missing[*]}" >&2
        return 1
    fi

    : > "$tmp"
    while IFS='=' read -r key _; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        printf '%s=%s\n' "$key" "${resp[$key]}" >> "$tmp"
    done < "$tmpl"

    chmod 600 "$tmp" || return 1
    mv "$tmp" "$out" || return 1
}
