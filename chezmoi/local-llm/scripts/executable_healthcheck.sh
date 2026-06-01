#!/usr/bin/env bash
#
# healthcheck.sh — verify the local LLM stack is configured and running correctly.
#
#   healthcheck.sh             Full smoke test (units + ports + real completions)
#   healthcheck.sh --quiet     Lightweight subset for `dots doctor` (no completions)
#   healthcheck.sh --opencode  Also run an opencode end-to-end probe through the provider
#
# Source-safe by design: functions are defined at top level WITHOUT enabling
# errexit, so bats can `source` this file and call the decision functions
# directly with faked `curl` / `systemctl` on PATH. `set -euo pipefail` lives
# inside main(), which only runs on direct execution.

# Colors (respect an already-sourced palette; else sane defaults).
: "${GREEN:=$'\033[0;32m'}"
: "${YELLOW:=$'\033[1;33m'}"
: "${RED:=$'\033[0;31m'}"
: "${BLUE:=$'\033[0;34m'}"
: "${NC:=$'\033[0m'}"

# Tunables (overridable for tests / non-default proxy).
LLM_PROXY="${LLM_PROXY:-http://127.0.0.1:4000}"
LLM_API_KEY="${LLM_API_KEY:-sk-local}"
LLM_CURL_TIMEOUT="${LLM_CURL_TIMEOUT:-5}"

# Tier table: "unit port model class(hard|opt)". The LiteLLM proxy and the two
# always-on workers are hard checks; optional tiers are informational.
LLM_TIERS=(
    "worker-igpu   8080 local-sonnet     hard"
    "worker-cpu    8081 local-haiku      hard"
    "worker-coder  8085 local-coder      opt"
    "worker-opus   8090 local-opus       opt"
    "worker-vision 8082 local-vision     opt"
    "worker-npu    8000 local-classifier opt"
)

# ─── decision functions (unit-testable) ────────────────────────────────────

# llm_unit_active <unit> — 0 if the systemd --user unit is active.
llm_unit_active() {
    systemctl --user is-active --quiet "$1" 2>/dev/null
}

# llm_port_up <port> — 0 if the worker's /v1/models endpoint answers.
llm_port_up() {
    curl -fsS --max-time "$LLM_CURL_TIMEOUT" \
        "http://127.0.0.1:${1}/v1/models" >/dev/null 2>&1
}

# _llm_complete <model> — echo the raw chat-completion JSON; curl status propagates.
_llm_complete() {
    curl -fsS --max-time "$LLM_CURL_TIMEOUT" \
        "${LLM_PROXY}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer ${LLM_API_KEY}" \
        -d "$(jq -nc --arg m "$1" \
            '{model:$m, messages:[{role:"user", content:"reply with OK"}], max_tokens:16}')" \
        2>/dev/null
}

# llm_completion_ok <model> — 0 if the proxy returns non-empty assistant content.
llm_completion_ok() {
    local resp; resp=$(_llm_complete "$1") || return 1
    [[ -n "$(jq -r '.choices[0].message.content // empty' <<<"$resp" 2>/dev/null)" ]]
}

# llm_served_model <model> — echo the model LiteLLM actually answered with
# (differs from the request when a fallback fired, e.g. opus→sonnet).
llm_served_model() {
    local resp; resp=$(_llm_complete "$1") || return 1
    jq -r '.model // empty' <<<"$resp" 2>/dev/null
}

# ─── reports ────────────────────────────────────────────────────────────────

# Lightweight subset for `dots doctor`: hard units active + proxy reachable.
# A fully-stopped stack is the normal idle state — workers are never
# auto-started (they gate on 85G models that may be absent), so a clean stop
# is not a config problem and must not make `dots doctor` fail. Only a
# partially-up / broken stack (some unit active but a sibling or the proxy
# down) is a real issue.
llm_quick_check() {
    local rc=0 active=0
    for u in litellm worker-igpu worker-cpu; do
        llm_unit_active "$u" && active=$((active + 1))
    done
    if [[ $active -eq 0 ]]; then
        echo -e "  ${YELLOW}• local LLM stack not running (start with llm-up)${NC}"
        return 0
    fi
    for u in litellm worker-igpu worker-cpu; do
        if llm_unit_active "$u"; then
            echo -e "  ${GREEN}✓ $u active${NC}"
        else
            echo -e "  ${RED}✗ $u inactive${NC}"; rc=1
        fi
    done
    if llm_port_up 4000; then
        echo -e "  ${GREEN}✓ LiteLLM proxy :4000 responding${NC}"
    else
        echo -e "  ${RED}✗ LiteLLM proxy :4000 not responding${NC}"; rc=1
    fi
    return "$rc"
}

# opencode end-to-end: prove the wired provider actually reaches a model.
llm_opencode_e2e() {
    if ! command -v opencode &>/dev/null; then
        echo -e "  ${YELLOW}⚠ opencode not installed — skipping e2e${NC}"
        return 0
    fi
    local out
    if out=$(opencode run --pure -m local-llm/local-haiku "reply with OK" 2>/dev/null) \
        && [[ -n "$out" ]]; then
        echo -e "  ${GREEN}✓ opencode reached local-llm/local-haiku${NC}"
        return 0
    fi
    echo -e "  ${RED}✗ opencode could not reach local-llm/local-haiku${NC}"
    return 1
}

# Full smoke test. Returns non-zero if any hard tier is unhealthy.
llm_health_report() {
    local with_opencode="${1:-false}" hard_fail=0

    echo -e "${BLUE}LiteLLM proxy${NC}"
    if llm_port_up 4000; then
        echo -e "  ${GREEN}✓ :4000 responding${NC}"
    else
        echo -e "  ${RED}✗ :4000 not responding${NC}"; hard_fail=1
    fi
    echo

    printf '%-17s %-14s %-5s %-11s %-8s %s\n' MODEL UNIT PORT COMPLETION LATENCY SERVED-AS
    local row unit port model class
    for row in "${LLM_TIERS[@]}"; do
        read -r unit port model class <<<"$row"
        local comp served lat note resp rc t0 t1
        if ! llm_port_up "$port"; then
            comp="skip"; served="-"; lat="-"
            [[ "$class" == "hard" ]] && hard_fail=1
        else
            t0=$(date +%s.%N 2>/dev/null || echo 0)
            resp=$(_llm_complete "$model") && rc=0 || rc=1
            t1=$(date +%s.%N 2>/dev/null || echo 0)
            lat=$(awk "BEGIN{d=$t1-$t0; if(d>0) printf \"%.1fs\", d; else print \"-\"}" 2>/dev/null || echo "-")
            if [[ $rc -eq 0 && -n "$(jq -r '.choices[0].message.content // empty' <<<"$resp" 2>/dev/null)" ]]; then
                comp="ok"
                served=$(jq -r '.model // empty' <<<"$resp" 2>/dev/null)
                [[ -z "$served" ]] && served="?"
            else
                comp="FAIL"; served="-"
                [[ "$class" == "hard" ]] && hard_fail=1
            fi
        fi
        # Flag fallback masking (e.g. local-opus actually served by local-sonnet).
        note=""
        [[ "$comp" == "ok" && "$served" != "$model" && "$served" != "?" ]] && note="  ${YELLOW}(fallback)${NC}"
        printf '%-17s %-14s %-5s %-11s %-8s %s' "$model" "$unit" "$port" "$comp" "$lat" "$served"
        echo -e "$note"
    done

    if [[ "$with_opencode" == "true" ]]; then
        echo
        echo -e "${BLUE}opencode end-to-end${NC}"
        llm_opencode_e2e || true
    fi

    echo
    if [[ $hard_fail -eq 0 ]]; then
        echo -e "${GREEN}═══ Local LLM stack healthy ═══${NC}"
    else
        echo -e "${RED}═══ Local LLM stack: always-on tier unhealthy ═══${NC}"
    fi
    return "$hard_fail"
}

main() {
    set -euo pipefail
    local quiet=false opencode=false a
    for a in "$@"; do
        case "$a" in
            --quiet)    quiet=true ;;
            --opencode) opencode=true ;;
            -h|--help)
                echo "usage: healthcheck.sh [--quiet] [--opencode]"
                return 0 ;;
            *) echo "unknown arg: $a" >&2; return 2 ;;
        esac
    done
    for dep in curl jq; do
        command -v "$dep" &>/dev/null || { echo "Error: $dep not found." >&2; return 1; }
    done
    if [[ "$quiet" == "true" ]]; then
        llm_quick_check
    else
        llm_health_report "$opencode"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
