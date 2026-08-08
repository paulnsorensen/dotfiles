# shellcheck shell=bash
# vault.sh — sourced provider and operator helpers.
#
# This library never materializes secrets into a user-owned cache and never
# exports credentials. Daily shells only load the allowlisted non-secret
# settings below; privileged provisioning reads provider values directly and
# hands them to service-owned credential files.

# Captures only its own absolute physical path at source time; all behavior
# remains behind functions so sourcing is otherwise side-effect-free.
_VAULT_LIBRARY_PATH="$(
    source_path="${BASH_SOURCE[0]}"
    source_dir="${source_path%/*}"
    [[ "$source_dir" != "$source_path" ]] || source_dir=.
    cd -P "$source_dir" || exit
    printf '%s/%s\n' "$PWD" "${source_path##*/}"
)"

_vault_retired_secret_names() {
    printf '%s\n' \
        GH_TOKEN \
        GITHUB_PERSONAL_ACCESS_TOKEN \
        GITHUB_APP_PRIVATE_KEY \
        CONTEXT7_API_KEY \
        TAVILY_API_KEY \
        SERPER_API_KEY \
        TODOIST_API_KEY
}

vault_remove_retired_cache() {
    rm -f -- "${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/secrets.env"
}

vault_unset_retired_secrets() {
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] && unset "$name"
    done < <(_vault_retired_secret_names)
    vault_remove_retired_cache
}

# Load only the documented non-secret .env settings. This parser never sources
# the file, so values cannot execute shell syntax. Retired secret names are
# cleared before the caller execs a child process.
vault_load_settings() {
    local env_file="${1:-${DOTFILES_DIR:-$HOME/Dev/dotfiles}/.env}" line key value
    vault_unset_retired_secrets
    [[ -f "$env_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            CLAUDE_SETUP_DIR|DOTFILES_VAULT_PROVIDER|DOTFILES_OP_ITEM|BWS_PROJECT_ID|\
            GITHUB_APP_ID|GITHUB_APP_INSTALLATION_ID|\
            DOTFILES_DEV|CHEESE_FLOW|VAUDEVILLE|TODOIST|SKILL_HARNESSES)
                if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                    value="${value:1:${#value}-2}"
                elif [[ "$value" == \"* && "$value" != *\" ]]; then
                    continue
                fi
                export "$key=$value"
                ;;
        esac
    done < "$env_file"
}

_vault_setting() {
    local name="$1" default="$2" env_file line value=""
    value="${!name:-}"
    if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    env_file="${DOTFILES_DIR:-$HOME/Dev/dotfiles}/.env"
    if [[ -f "$env_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "$name="* ]] && value="${line#*=}"
        done < "$env_file"
    fi
    printf '%s\n' "${value:-$default}"
}

_vault_provider() {
    local provider
    provider="$(_vault_setting DOTFILES_VAULT_PROVIDER auto)" || {
        echo "vault: could not read DOTFILES_VAULT_PROVIDER." >&2
        return 2
    }
    case "$provider" in
        auto|onepassword|bitwarden) printf '%s\n' "$provider" ;;
        *)
            echo "vault: DOTFILES_VAULT_PROVIDER must be auto, onepassword, or bitwarden; found '$provider'." >&2
            return 2
            ;;
    esac
}

_vault_onepassword_item() {
    _vault_setting DOTFILES_OP_ITEM op://Private/dotfiles
}

_vault_validate_onepassword_item() {
    local item="$1" rest vault item_name
    [[ "$item" == op://* ]] || {
        echo "vault: DOTFILES_OP_ITEM must be op://<vault>/<item>; found '$item'." >&2
        return 1
    }
    rest="${item#op://}"
    [[ "$rest" == */* ]] || {
        echo "vault: DOTFILES_OP_ITEM must be op://<vault>/<item>; found '$item'." >&2
        return 1
    }
    vault="${rest%%/*}"
    item_name="${rest#*/}"
    [[ -n "$vault" && -n "$item_name" && "$item_name" != */* ]] || {
        echo "vault: DOTFILES_OP_ITEM must be op://<vault>/<item>; found '$item'." >&2
        return 1
    }
}

_vault_onepassword_ready() {
    local item="$1" rest vault item_name
    command -v op >/dev/null 2>&1 || return 1
    rest="${item#op://}"
    vault="${rest%%/*}"
    item_name="${rest#*/}"
    op item get "$item_name" --vault "$vault" --format json >/dev/null 2>&1
}

_vault_token() (
    set +x
    trap - DEBUG RETURN ERR
    local token
    if [[ "$(uname -s)" == Darwin ]]; then
        token="$(security find-generic-password -w -s bws_access_token -a "${USER:-}" 2>/dev/null)" || {
            echo "vault: no Bitwarden access token in Keychain (service bws_access_token)." >&2
            echo "vault: run bin/vault-provision to store one." >&2
            return 1
        }
    else
        # Linux deliberately has no same-user token file. The privileged
        # operator supplies BWS_ACCESS_TOKEN for this transaction only.
        token="${BWS_ACCESS_TOKEN:-}"
    fi
    [[ -n "$token" ]] || {
        echo "vault: Bitwarden access token is empty or unavailable." >&2
        echo "vault: run bin/vault-provision to provide one." >&2
        return 1
    }
    printf '%s\n' "$token"
)

_vault_project_id() {
    local project_id
    project_id="$(_vault_setting BWS_PROJECT_ID "")"
    [[ -n "$project_id" ]] || return 1
    printf '%s\n' "$project_id"
}

_vault_bitwarden_ready() {
    local project_id
    command -v bws >/dev/null 2>&1 || return 1
    project_id="$(_vault_project_id 2>/dev/null)" || return 1
    [[ -n "$project_id" ]] || return 1
    _vault_token >/dev/null 2>&1
}

vault_source() {
    case "${1:-}" in
        onepassword) _vault_onepassword_item ;;
        bitwarden) _vault_project_id ;;
        *) return 2 ;;
    esac
}

# Resolve exactly one provider from explicit intent or readiness. No cache is
# consulted or changed; provider/source provenance remains available to the
# operator through vault_source.
_vault_resolve_unlocked() {
    local provider item project_id op_ready=false bws_ready=false
    provider="$(_vault_provider)" || return $?

    case "$provider" in
        onepassword)
            item="$(_vault_onepassword_item)"
            _vault_validate_onepassword_item "$item" || return 1
            _vault_onepassword_ready "$item" || {
                echo "vault: configured onepassword item '$item' is not accessible." >&2
                return 1
            }
            printf 'onepassword\n'
            ;;
        bitwarden)
            project_id="$(_vault_project_id 2>/dev/null || true)"
            command -v bws >/dev/null 2>&1 || {
                echo "vault: configured bitwarden provider is not ready: bws is missing; install it with 'cargo install bws --locked'." >&2
                return 1
            }
            [[ -n "$project_id" ]] || {
                echo "vault: configured bitwarden provider is not ready: BWS_PROJECT_ID is unset; run bin/vault-provision or set it in .env." >&2
                return 1
            }
            _vault_token >/dev/null || return 1
            printf 'bitwarden\n'
            ;;
        auto)
            item="$(_vault_onepassword_item)"
            _vault_validate_onepassword_item "$item" >/dev/null 2>&1 &&
                _vault_onepassword_ready "$item" && op_ready=true
            _vault_bitwarden_ready && {
                bws_ready=true
                project_id="$(_vault_project_id)"
            }
            if [[ "$op_ready" == true && "$bws_ready" == true ]]; then
                echo "vault: both onepassword and bitwarden are ready; set DOTFILES_VAULT_PROVIDER explicitly." >&2
                return 1
            elif [[ "$op_ready" == true ]]; then
                printf 'onepassword\n'
            elif [[ "$bws_ready" == true ]]; then
                printf 'bitwarden\n'
            else
                printf 'unconfigured\n'
            fi
            ;;
    esac
}

vault_disables_bitwarden_install() {
    local provider
    provider="$(_vault_provider)" || return 2
    case "$provider" in
        onepassword) return 0 ;;
        bitwarden) return 1 ;;
        auto) command -v op >/dev/null 2>&1 ;;
    esac
}

# Provider resolution is serialized because readiness probes may prompt or touch
# provider CLI state. The callback is re-executed only on macOS lockf; the
# absolute library path above keeps that re-exec independent of cwd changes.
_vault_with_resolution_lock() (
    local lock="$1" callback="$2"
    local timeout="${_VAULT_LOCK_TIMEOUT:-10}" status attempt acquired=false
    local shell="${BASH:-bash}" library="${_VAULT_LIBRARY_PATH:-}"
    shift 2
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=10
    [[ -n "$lock" && -n "$callback" && -n "$library" ]] || return 1

    mkdir -p "${lock%/*}" || return 1
    umask 077
    : >> "$lock" || return 1
    chmod 600 "$lock" || return 1

    if command -v flock >/dev/null 2>&1; then
        exec 9>> "$lock" || return 1
        for ((attempt = 0; attempt <= timeout * 20; attempt += 1)); do
            if flock -n 9; then
                acquired=true
                break
            fi
            ((attempt == timeout * 20)) || sleep 0.05
        done
        [[ "$acquired" == true ]] || {
            echo "vault: timed out waiting for resolution lock $lock; another provider probe is active." >&2
            return 1
        }
        "$callback" "$@"
        return
    fi

    if command -v lockf >/dev/null 2>&1; then
        # shellcheck disable=SC2016
        lockf -k -s -t "$timeout" "$lock" "$shell" -c '
            source "$1" || exit 1
            callback="$2"
            shift 2
            "$callback" "$@"
        ' vault-lock "$library" "$callback" "$@"
        status=$?
        if ((status == 75)); then
            echo "vault: timed out waiting for resolution lock $lock; another provider probe is active." >&2
            return 1
        fi
        return "$status"
    fi

    echo "vault: provider resolution requires flock (Linux) or lockf (macOS)." >&2
    return 1
)

vault_resolve() {
    _vault_with_resolution_lock \
        "${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/vault-resolution.lock" \
        _vault_resolve_unlocked
}

_vault_fetch_bitwarden() {
    bws secret list "$1" -o env
}

_vault_fetch_onepassword() {
    op read "$1/$2"
}

# Read one runtime credential without writing it to disk. Callers must capture
# the value in memory or stream it directly to a privileged file writer.
vault_secret_value() (
    set +x
    trap - DEBUG RETURN ERR
    local provider="$1" key="$2" item project_id token raw line found=false
    case "$key" in
        CONTEXT7_API_KEY|TAVILY_API_KEY|TODOIST_API_KEY|GITHUB_APP_PRIVATE_KEY) ;;
        *) echo "vault: refusing non-runtime secret key '$key'." >&2; return 2 ;;
    esac

    case "$provider" in
        onepassword)
            item="$(_vault_onepassword_item)"
            _vault_validate_onepassword_item "$item" || return 1
            _vault_fetch_onepassword "$item" "$key"
            ;;
        bitwarden)
            project_id="$(_vault_project_id)" || return 1
            token="$(_vault_token)" || return 1
            raw="$(BWS_ACCESS_TOKEN="$token" _vault_fetch_bitwarden "$project_id")" || return 1
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" == "$key="* ]] || continue
                printf '%s\n' "${line#*=}"
                found=true
                break
            done <<< "$raw"
            [[ "$found" == true ]] || {
                echo "vault: Bitwarden secret '$key' is missing." >&2
                return 1
            }
            ;;
        *) echo "vault: unknown provider '$provider'." >&2; return 2 ;;
    esac
)

vault_runtime_keys() {
    printf '%s\n' CONTEXT7_API_KEY TAVILY_API_KEY TODOIST_API_KEY GITHUB_APP_PRIVATE_KEY
}
