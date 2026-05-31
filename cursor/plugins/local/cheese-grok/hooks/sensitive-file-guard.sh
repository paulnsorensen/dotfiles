#!/usr/bin/env bash
# Cursor hook: block reads/writes of .env files, private keys, and credential
# stores. Wired for two events in hooks.json:
#   beforeReadFile        — input JSON has .file_path
#   beforeShellExecution  — input JSON has .command
# Cursor blocks on exit code 2 (parse-free deny); exit 0 allows. Fail-open on
# any internal error — a guard must never become a denial-of-service.
#
# Detection mirrors agents/lib/sensitive-file-guard.js (the Claude/Codex hook).
# Kept in sync by hand; the shared bats fixtures assert the same policy.
#
# Opt-out / allow-list (parity with the Claude/Codex hook):
#   CLAUDE_SENSITIVE_GUARD=0|false|off|no        → disable
#   CLAUDE_SENSITIVE_GUARD_ALLOW=substr,/abs,...  → allow matching paths

set -u

case "$(printf '%s' "${CLAUDE_SENSITIVE_GUARD:-}" | tr '[:upper:]' '[:lower:]')" in
    0|false|off|no) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null)" || exit 0

# True (returns 0) when a single path is secret-bearing.
is_sensitive() {
    local p="$1" base
    [[ -n "$p" ]] || return 1
    # Allow-list: substring match against the path.
    if [[ -n "${CLAUDE_SENSITIVE_GUARD_ALLOW:-}" ]]; then
        local IFS=','
        local entry
        for entry in $CLAUDE_SENSITIVE_GUARD_ALLOW; do
            [[ -n "$entry" && "$p" == *"$entry"* ]] && return 1
        done
    fi
    base="${p##*/}"

    # .env / .env.* — except checked-in templates.
    if [[ "$base" == ".env" ]]; then return 0; fi
    if [[ "$base" == .env.* && ! "$base" =~ (example|sample|template|dist|defaults) ]]; then return 0; fi

    # Credential stores by exact basename.
    case "$base" in
        .netrc|_netrc|.pgpass|.npmrc|.pypirc|.git-credentials|.htpasswd|kubeconfig) return 0 ;;
        id_rsa|id_dsa|id_ecdsa|id_ed25519) return 0 ;;
    esac

    # Private-key / keystore / secret-bundle extensions and names.
    if [[ "$base" =~ \.(pem|key|p12|pfx|keystore|jks|ppk)$ ]]; then return 0; fi
    if [[ "$base" =~ ^secrets?\.(ya?ml|json|toml|env)$ ]]; then return 0; fi
    if [[ "$base" =~ \.secret$ ]]; then return 0; fi

    # Private credential directories.
    case "$p" in
        *.aws/credentials) return 0 ;;
        *.gnupg/*) return 0 ;;
    esac
    if [[ "$p" == *.ssh/* ]]; then
        case "$base" in
            *.pub|known_hosts|config|authorized_keys) return 1 ;;
            *) return 0 ;;
        esac
    fi
    return 1
}

deny() {
    printf 'cheese-grok: blocked access to sensitive file: %s\n' "$1" >&2
    exit 2
}

case "$event" in
    beforeReadFile)
        path="$(printf '%s' "$payload" | jq -r '.file_path // ""' 2>/dev/null)"
        is_sensitive "$path" && deny "$path"
        ;;
    beforeShellExecution)
        cmd="$(printf '%s' "$payload" | jq -r '.command // ""' 2>/dev/null)"
        # Tokenize: strip redirection/quote/@-prefix noise, test each token.
        for tok in $cmd; do
            tok="${tok#@}"; tok="${tok#[<>|&]}"; tok="${tok%\"}"; tok="${tok#\"}"
            tok="${tok%\'}"; tok="${tok#\'}"
            is_sensitive "$tok" && deny "$tok"
        done
        ;;
esac

exit 0
