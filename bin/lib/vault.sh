# shellcheck shell=bash
# vault.sh — sourced library: resolve the per-machine secret vault (1Password
# or Bitwarden Secrets Manager) and materialize its secrets into a cached
# .env-format file consumed by every loader (agents/mcp/sync.sh,
# zsh/core.zsh, bin/cc-env-exec, and the cheese profile CLI). Deep module —
# the only place that knows a vault exists.
#
# Captures only its own absolute physical path at source time; all behavior
# remains behind functions so sourcing is otherwise side-effect-free.

_VAULT_LIBRARY_PATH="$(
    source_path="${BASH_SOURCE[0]}"
    source_dir="${source_path%/*}"
    [[ "$source_dir" != "$source_path" ]] || source_dir=.
    cd -P "$source_dir" || exit
    printf '%s/%s\n' "$PWD" "${source_path##*/}"
)"

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
    command -v op &>/dev/null || return 1
    rest="${item#op://}"
    vault="${rest%%/*}"
    item_name="${rest#*/}"
    op item get "$item_name" --vault "$vault" --format json >/dev/null 2>&1
}

_vault_bitwarden_ready() {
    local project_id
    command -v bws &>/dev/null || return 1
    project_id="$(_vault_project_id 2>/dev/null)" || return 1
    [[ -n "$project_id" ]] || return 1
    _vault_token >/dev/null 2>&1
}

_vault_cache_matches() {
    local cache="$1" expected_provider="$2" expected_source="$3"
    local line provider="" source=""
    [[ -n "$expected_source" && -f "$cache" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "# vault-provider="*) provider="${line#\# vault-provider=}" ;;
            "# vault-source="*) source="${line#\# vault-source=}" ;;
        esac
    done < "$cache"
    [[ "$provider" == "$expected_provider" && "$source" == "$expected_source" ]]
}

_vault_with_cache_lock() (
    local lock="$1" callback="$2"
    local timeout="${_VAULT_LOCK_TIMEOUT:-10}" status attempt acquired=false
    local shell="${BASH:-bash}"
    shift 2
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=10

    mkdir -p "${lock%/*}" || return 1
    umask 077
    if ! : >> "$lock" || ! chmod 600 "$lock"; then
        echo "vault: could not initialize the mode-0600 cache lock $lock." >&2
        return 1
    fi

    if command -v flock >/dev/null 2>&1; then
        exec 9>> "$lock" || return 1
        for ((attempt = 0; attempt <= timeout * 20; attempt += 1)); do
            if flock -n 9; then
                acquired=true
                break
            fi
            ((attempt == timeout * 20)) || sleep 0.05
        done
        if [[ "$acquired" != true ]]; then
            echo "vault: timed out waiting for cache lock $lock; another vault transaction is still active." >&2
            return 1
        fi
        "$callback" "$@"
        return
    fi

    if command -v lockf >/dev/null 2>&1; then
        # macOS lockf accepts a path and command, not an open descriptor. Start
        # a fresh library shell so the complete callback runs under that lock.
        # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
        lockf -k -s -t "$timeout" "$lock" "$shell" -c '
            source "$1" || exit 1
            callback="$2"
            shift 2
            "$callback" "$@"
        ' vault-lock "$_VAULT_LIBRARY_PATH" "$callback" "$@"
        status=$?
        if ((status == 75)); then
            echo "vault: timed out waiting for cache lock $lock; another vault transaction is still active." >&2
            return 1
        fi
        return "$status"
    fi

    echo "vault: cache transactions require flock (Linux) or lockf (macOS)." >&2
    return 1
)

_vault_invalidate_cache_unless_matches_unlocked() {
    local provider="$1" source="$2" alternate_provider="${3:-}" alternate_source="${4:-}" cache
    cache="$(vault_secrets_file)"
    if [[ ! -f "$cache" ]]; then
        printf 'absent\n'
        return 0
    fi
    if _vault_cache_matches "$cache" "$provider" "$source"; then
        printf 'preserved\n'
        return 0
    fi
    if [[ -n "$alternate_provider" ]] \
        && _vault_cache_matches "$cache" "$alternate_provider" "$alternate_source"; then
        printf 'preserved\n'
        return 0
    fi
    rm -f "$cache" || return 1
    printf 'removed\n'
}
_vault_reconcile_current_cache_unlocked() {
    local policy item project_id
    policy="$(_vault_provider)" || {
        _vault_invalidate_cache_unless_matches_unlocked invalid ""
        return
    }
    case "$policy" in
        onepassword)
            item="$(_vault_onepassword_item)"
            if _vault_validate_onepassword_item "$item" >/dev/null 2>&1; then
                _vault_invalidate_cache_unless_matches_unlocked onepassword "$item"
            else
                _vault_invalidate_cache_unless_matches_unlocked invalid ""
            fi
            ;;
        bitwarden)
            project_id="$(_vault_project_id 2>/dev/null || true)"
            _vault_invalidate_cache_unless_matches_unlocked bitwarden "$project_id"
            ;;
        auto)
            item="$(_vault_onepassword_item)"
            project_id="$(_vault_project_id 2>/dev/null || true)"
            if _vault_validate_onepassword_item "$item" >/dev/null 2>&1; then
                _vault_invalidate_cache_unless_matches_unlocked \
                    onepassword "$item" bitwarden "$project_id"
            else
                _vault_invalidate_cache_unless_matches_unlocked invalid ""
            fi
            ;;
    esac
}

_vault_invalidate_cache_unless_matches() {
    local provider="$1" source="$2" alternate_provider="${3:-}" alternate_source="${4:-}"
    local expected_policy="${5:-}" disposition status
    local current_policy="" current_source=""

    if [[ -n "$expected_policy" ]]; then
        current_policy="$(_vault_provider 2>/dev/null || true)"
        case "$provider" in
            onepassword) current_source="$(_vault_onepassword_item)" ;;
            bitwarden) current_source="$(_vault_project_id 2>/dev/null || true)" ;;
        esac
        if [[ "$current_policy" != "$expected_policy" || "$current_source" != "$source" ]]; then
            disposition="$(_vault_reconcile_current_cache_unlocked)"
            status=$?
            ((status == 0)) || return "$status"
            _vault_report_cache_disposition "$disposition"
            echo "vault: provider policy or exact source changed during resolution; retry." >&2
            return 1
        fi
    fi

    disposition="$(_vault_invalidate_cache_unless_matches_unlocked \
        "$provider" "$source" "$alternate_provider" "$alternate_source")"
    status=$?
    ((status == 0)) || return "$status"
    printf '%s\n' "$disposition"
}

_vault_report_cache_disposition() {
    case "$1" in
        preserved) echo "vault: same-source cache preserved." >&2 ;;
        removed) echo "vault: cache removed because its provider/source provenance no longer matches." >&2 ;;
    esac
}

vault_resolve() {
    local cache
    cache="$(vault_secrets_file)"
    _vault_with_cache_lock "${cache}.lock" _vault_resolve_unlocked
}

_vault_resolve_unlocked() {
    local provider provider_status item="" project_id="" op_ready=false bws_ready=false
    local current_provider="" current_item="" current_project_id=""
    local cache disposition decision
    provider="$(_vault_provider)"
    provider_status=$?
    if ((provider_status != 0)); then
        disposition="$(_vault_invalidate_cache_unless_matches invalid "")" || return 1
        _vault_report_cache_disposition "$disposition"
        return "$provider_status"
    fi
    cache="$(vault_secrets_file)"

    case "$provider" in
        onepassword)
            item="$(_vault_onepassword_item)"
            if ! _vault_validate_onepassword_item "$item"; then
                disposition="$(_vault_invalidate_cache_unless_matches invalid "")" || return 1
                _vault_report_cache_disposition "$disposition"
                return 1
            fi
            if ! command -v op &>/dev/null; then
                disposition="$(_vault_invalidate_cache_unless_matches onepassword "$item" "" "" onepassword)" || return 1
                echo "vault: configured onepassword provider is not ready; install the op 1Password CLI." >&2
                echo "vault: then unlock 1Password, enable CLI integration, and verify DOTFILES_OP_ITEM with 'op item get <item> --vault <vault>'." >&2
                _vault_report_cache_disposition "$disposition"
                return 1
            fi
            if ! _vault_onepassword_ready "$item"; then
                disposition="$(_vault_invalidate_cache_unless_matches onepassword "$item" "" "" onepassword)" || return 1
                echo "vault: configured onepassword item '$item' is not accessible." >&2
                echo "vault: unlock 1Password, enable CLI integration, and verify DOTFILES_OP_ITEM with 'op item get <item> --vault <vault>'." >&2
                _vault_report_cache_disposition "$disposition"
                return 1
            fi
            disposition="$(_vault_invalidate_cache_unless_matches onepassword "$item" "" "" onepassword)" || return 1
            echo onepassword
            return 0
            ;;
        bitwarden)
            project_id="$(_vault_project_id 2>/dev/null || true)"
            if ! command -v bws &>/dev/null; then
                disposition="$(_vault_invalidate_cache_unless_matches bitwarden "$project_id" "" "" bitwarden)" || return 1
                echo "vault: configured bitwarden provider is not ready: bws is missing; install it with 'cargo install bws --locked'." >&2
                _vault_report_cache_disposition "$disposition"
                return 1
            fi
            if [[ -z "$project_id" ]]; then
                disposition="$(_vault_invalidate_cache_unless_matches bitwarden "" "" "" bitwarden)" || return 1
                echo "vault: configured bitwarden provider is not ready: BWS_PROJECT_ID is unset; run bin/vault-provision or set it in .env." >&2
                _vault_report_cache_disposition "$disposition"
                return 1
            fi
            if ! _vault_token >/dev/null; then
                disposition="$(_vault_invalidate_cache_unless_matches bitwarden "$project_id" "" "" bitwarden)" || return 1
                echo "vault: configured bitwarden provider is not ready: its access-token prerequisite failed." >&2
                _vault_report_cache_disposition "$disposition"
                return 1
            fi
            disposition="$(_vault_invalidate_cache_unless_matches bitwarden "$project_id" "" "" bitwarden)" || return 1
            echo bitwarden
            return 0
            ;;
        auto)
            item="$(_vault_onepassword_item)"
            if ! _vault_validate_onepassword_item "$item"; then
                disposition="$(_vault_invalidate_cache_unless_matches invalid "")" || return 1
                _vault_report_cache_disposition "$disposition"
                return 1
            fi
            ;;
    esac

    _vault_onepassword_ready "$item" && op_ready=true
    if _vault_bitwarden_ready; then
        bws_ready=true
        project_id="$(_vault_project_id)"
    else
        project_id="$(_vault_project_id 2>/dev/null || true)"
    fi

    current_provider="$(_vault_provider 2>/dev/null || true)"
    current_item="$(_vault_onepassword_item)"
    current_project_id="$(_vault_project_id 2>/dev/null || true)"
    if [[ "$current_provider" != auto || "$current_item" != "$item" \
        || "$current_project_id" != "$project_id" ]]; then
        disposition="$(_vault_reconcile_current_cache_unlocked)"
        provider_status=$?
        ((provider_status == 0)) || return "$provider_status"
        _vault_report_cache_disposition "$disposition"
        echo "vault: provider policy or exact source changed during resolution; retry." >&2
        return 1
    fi
    if [[ "$op_ready" == true && "$bws_ready" == true ]]; then
        disposition="$(_vault_invalidate_cache_unless_matches_unlocked \
            onepassword "$item" bitwarden "$project_id")"
        decision=ambiguous
    elif [[ "$op_ready" == true ]]; then
        disposition="$(_vault_invalidate_cache_unless_matches_unlocked onepassword "$item")"
        decision=onepassword
    elif [[ "$bws_ready" == true ]]; then
        disposition="$(_vault_invalidate_cache_unless_matches_unlocked bitwarden "$project_id")"
        decision=bitwarden
    elif [[ -f "$cache" ]] && {
        _vault_cache_matches "$cache" onepassword "$item" \
            || _vault_cache_matches "$cache" bitwarden "$project_id"
    }; then
        disposition=preserved
        decision=no-ready-cache
    else
        disposition="$(_vault_invalidate_cache_unless_matches_unlocked invalid "")"
        decision=unconfigured
    fi

    case "$decision" in
        ambiguous)
            echo "vault: both onepassword and bitwarden are ready; set DOTFILES_VAULT_PROVIDER explicitly." >&2
            _vault_report_cache_disposition "$disposition"
            return 1
            ;;
        onepassword|bitwarden)
            printf '%s\n' "$decision"
            ;;
        no-ready-cache)
            echo "vault: no vault provider is ready; same-source cache preserved." >&2
            return 1
            ;;
        unconfigured)
            echo unconfigured
            ;;
    esac
}

vault_disables_bitwarden_install() {
    local provider status disposition="" cache
    provider="$(_vault_provider)"
    status=$?
    if ((status != 0)); then
        cache="$(vault_secrets_file)"
        disposition="$(_vault_with_cache_lock "${cache}.lock" \
            _vault_invalidate_cache_unless_matches invalid "")" || true
        [[ -z "$disposition" ]] || _vault_report_cache_disposition "$disposition"
        return 2
    fi
    case "$provider" in
        onepassword) return 0 ;;
        bitwarden) return 1 ;;
        auto) command -v op &>/dev/null ;;
    esac
}

vault_secrets_file() {
    echo "${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/secrets.env"
}

_vault_token_file() {
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/bws-token"
}

# Token storage is platform-specific. macOS uses the Keychain (Bitwarden's own
# documented pattern). A headless Linux box has no keyring daemon, so libsecret
# is unavailable and the token lives in a 0600 file instead; this refuses to
# read one that is group- or world-readable rather than leaking it silently.
_vault_token() (
    set +x
    trap - DEBUG RETURN ERR
    local file mode token
    if [[ "$(uname -s)" == Darwin ]]; then
        if ! token="$(security find-generic-password -w -s BWS_ACCESS_TOKEN -a "$USER" 2>/dev/null)"; then
            echo "vault: no Bitwarden access token in Keychain (service BWS_ACCESS_TOKEN)." >&2
            echo "vault: run bin/vault-provision to store one." >&2
            return 1
        fi
        if [[ -z "$token" ]]; then
            echo "vault: Bitwarden access token in Keychain is empty." >&2
            echo "vault: run bin/vault-provision to replace it." >&2
            return 1
        fi
        printf '%s\n' "$token"
        return 0
    fi

    file="$(_vault_token_file)"
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
    token="$(<"$file")" || return 1
    if [[ -z "$token" ]]; then
        echo "vault: Bitwarden access token file $file is empty." >&2
        return 1
    fi
    printf '%s\n' "$token"
)

# Resolve the project id from the environment, falling back to the machine-local
# settings file. Provider readiness and materialization share this lookup.
_vault_project_id() {
    local project_id
    project_id="$(_vault_setting BWS_PROJECT_ID "")"
    [[ -n "$project_id" ]] || return 1
    printf '%s\n' "$project_id"
}

# Keep provider-specific response formats behind isolated adapters.
_vault_fetch_bitwarden() {
    bws secret list "$1" -o env
}

_vault_emit_onepassword_refs() {
    local item="$1" tmpl="$2" key value
    while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        printf '%s=%s/%s\n' "$key" "$item" "$key"
    done < "$tmpl"
}

_vault_fetch_onepassword() {
    op inject < <(_vault_emit_onepassword_refs "$1" "$2")
}

# Serialize each cache transaction with the platform's kernel-backed advisory
# lock. Ownership covers the complete transaction; the lock file stays in place
# so waiters never split across different inodes.
vault_materialize() (
    set +x
    trap - DEBUG RETURN ERR
    local provider="${1:-}" out lock

    case "$provider" in
        onepassword|bitwarden) ;;
        *)
            echo "vault: materialize provider must be onepassword or bitwarden." >&2
            return 1
            ;;
    esac

    out="$(vault_secrets_file)"
    lock="${out}.lock"
    _vault_with_cache_lock "$lock" _vault_materialize_unlocked "$provider"
)

# Writes a provider-tagged cache under umask 077 via temp files and atomic mv.
# A response is accepted only when it contains the manifest's exact, closed key
# set and every value is non-empty. A same-source failure preserves the old
# cache; a changed or untagged source is invalidated before fetching.
_vault_materialize_unlocked() (
    set +x
    trap - DEBUG RETURN ERR
    local provider="${1:-}" tmpl out raw="" tmp="" token project_id="" item="" source=""
    local policy current_policy current_source="" provider_status
    local key value line serialization_status cache_disposition="" published=false
    local template_keys=() missing=()

    # shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap below.
    _vault_materialize_cleanup() {
        local exit_status=$? cleanup_status=0
        trap - EXIT HUP INT TERM
        if [[ -n "$raw" && -f "$raw" ]] && ! rm -f "$raw"; then
            cleanup_status=1
        fi
        if [[ -n "$tmp" && -f "$tmp" ]] && ! rm -f "$tmp"; then
            cleanup_status=1
        fi
        if ((exit_status == 0 && cleanup_status != 0)); then
            exit_status=1
        fi
        if ((exit_status != 0)) && [[ "$published" != true ]]; then
            _vault_report_cache_disposition "$cache_disposition"
        fi
        exit "$exit_status"
    }

    trap _vault_materialize_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    umask 077

    case "$provider" in
        onepassword|bitwarden) ;;
        *)
            echo "vault: materialize provider must be onepassword or bitwarden." >&2
            return 1
            ;;
    esac

    out="$(vault_secrets_file)"

    policy="$(_vault_provider)"
    provider_status=$?
    if ((provider_status != 0)); then
        cache_disposition="$(_vault_invalidate_cache_unless_matches_unlocked invalid "")" || return 1
        return "$provider_status"
    fi

    case "$provider" in
        onepassword)
            item="$(_vault_onepassword_item)"
            source="$item"
            if ! _vault_validate_onepassword_item "$item"; then
                cache_disposition="$(_vault_invalidate_cache_unless_matches_unlocked invalid "")" || return 1
                return 1
            fi
            ;;
        bitwarden)
            project_id="$(_vault_project_id 2>/dev/null || true)"
            source="$project_id"
            if [[ -z "$project_id" ]]; then
                cache_disposition="$(_vault_invalidate_cache_unless_matches_unlocked bitwarden "")" || return 1
                echo "vault: BWS_PROJECT_ID is unset; run bin/vault-provision or set it in .env before materializing Bitwarden." >&2
                return 1
            fi
            ;;
    esac

    cache_disposition="$(_vault_invalidate_cache_unless_matches_unlocked "$provider" "$source")" || return 1
    if [[ "$policy" != auto && "$policy" != "$provider" ]]; then
        cache_disposition="$(_vault_invalidate_cache_unless_matches_unlocked invalid "")" || return 1
        echo "vault: requested provider '$provider' conflicts with DOTFILES_VAULT_PROVIDER=$policy; cache was not published." >&2
        return 1
    fi

    tmpl="${DOTFILES_DIR:-$HOME/Dev/dotfiles}/secrets/secrets.env.tmpl"
    [[ -f "$tmpl" ]] || {
        echo "vault: template not found: $tmpl" >&2
        return 1
    }

    (( ${BASH_VERSINFO[0]:-0} >= 4 )) || {
        echo "vault: materialize requires bash >= 4 (found ${BASH_VERSINFO[0]:-0}); this shell is likely macOS /bin/bash 3.2 — re-run under Homebrew bash" >&2
        return 1
    }

    local -A tmpl_keys resp
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" != *=* ]]; then
            echo "vault: manifest contains invalid KEY= syntax." >&2
            return 1
        fi
        key="${line%%=*}"
        value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "vault: manifest contains invalid KEY= syntax." >&2
            return 1
        fi
        if [[ -n "$value" ]]; then
            echo "vault: manifest must contain unique KEY= entries with blank values; found a non-blank value." >&2
            return 1
        fi
        if [[ -n "${tmpl_keys[$key]+x}" ]]; then
            echo "vault: manifest must contain unique KEY= entries with blank values; found a duplicate key." >&2
            return 1
        fi
        tmpl_keys["$key"]=1
        template_keys+=("$key")
    done < "$tmpl"

    raw="$(mktemp "${out}.raw.XXXXXX")" || {
        echo "vault: could not create a secure response file." >&2
        return 1
    }
    tmp="$(mktemp "${out}.tmp.XXXXXX")" || {
        echo "vault: could not create a secure cache file." >&2
        return 1
    }

    case "$provider" in
        onepassword)
            _vault_fetch_onepassword "$item" "$tmpl" > "$raw" || {
                echo "vault: op inject failed; verify the configured item contains every manifest field, then retry." >&2
                return 1
            }
            ;;
        bitwarden)
            token="$(_vault_token)" || return 1
            BWS_ACCESS_TOKEN="$token" _vault_fetch_bitwarden "$project_id" > "$raw" || {
                echo "vault: bws fetch failed after the CLI, project, and access-token prerequisites succeeded." >&2
                return 1
            }
            unset token
            ;;
    esac

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" != *=* ]]; then
            echo "vault: materialize failed, unexpected or malformed entry in vault response: invalid KEY=VALUE syntax." >&2
            return 1
        fi
        key="${line%%=*}"
        if [[ -z "$key" ]]; then
            echo "vault: materialize failed, unexpected or malformed entry in vault response: invalid KEY=VALUE syntax." >&2
            return 1
        fi
        if [[ -z "${tmpl_keys[$key]+x}" ]]; then
            echo "vault: materialize failed, unexpected or malformed entry in vault response: unlisted key." >&2
            return 1
        fi
        if [[ -n "${resp[$key]+x}" ]]; then
            echo "vault: materialize failed, unexpected or malformed entry in vault response: duplicate key." >&2
            return 1
        fi
        resp["$key"]="${line#*=}"
    done < "$raw"

    for key in "${template_keys[@]}"; do
        [[ -n "${resp[$key]:-}" ]] || missing+=("$key")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "vault: materialize failed, missing/empty keys: ${missing[*]}" >&2
        return 1
    fi

    serialization_status=0
    if {
        printf '# vault-provider=%s\n' "$provider" || serialization_status=$?
        if ((serialization_status == 0)); then
            printf '# vault-source=%s\n' "$source" || serialization_status=$?
        fi
        for key in "${template_keys[@]}"; do
            ((serialization_status == 0)) || break
            printf '%s=%s\n' "$key" "${resp[$key]}" || serialization_status=$?
        done
        ((serialization_status == 0))
    } > "$tmp"; then
        :
    else
        echo "vault: failed to serialize the validated vault response; existing cache was not replaced." >&2
        return 1
    fi

    chmod 600 "$tmp" || {
        echo "vault: failed to set mode 0600 on the new cache; existing cache was not replaced." >&2
        return 1
    }

    current_policy="$(_vault_provider)"
    provider_status=$?
    case "$provider" in
        onepassword)
            current_source="$(_vault_onepassword_item)"
            _vault_validate_onepassword_item "$current_source" >/dev/null 2>&1 || current_source=""
            ;;
        bitwarden)
            current_source="$(_vault_project_id 2>/dev/null || true)"
            ;;
    esac
    if ((provider_status != 0)) \
        || [[ "$current_policy" != "$policy" \
            || ( "$current_policy" != auto && "$current_policy" != "$provider" ) \
            || -z "$current_source" \
            || "$current_source" != "$source" ]]; then
        cache_disposition="$(_vault_invalidate_cache_unless_matches_unlocked invalid "")" || return 1
        echo "vault: provider policy or exact source changed during materialization; discarded the response without publishing it." >&2
        return 1
    fi

    if ! mv "$tmp" "$out"; then
        echo "vault: failed to publish the new cache atomically; existing cache was not replaced." >&2
        return 1
    fi
    tmp=""
    published=true
)
