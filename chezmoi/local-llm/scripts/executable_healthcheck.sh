#!/usr/bin/env bash
#
# healthcheck.sh — verify the local LLM stack is configured and running correctly.
#
#   healthcheck.sh             Full smoke test (units + ports + completions + swap registry)
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
LLM_SWAP="${LLM_SWAP:-http://127.0.0.1:9000}"
LLM_API_KEY="${LLM_API_KEY:-sk-local}"
LLM_CURL_TIMEOUT="${LLM_CURL_TIMEOUT:-5}"

# Tier table: "unit port model class(hard|opt) probe(completion|registered)".
# llama-swap-served models share :9000. Probing a swap-pool model with a real
# completion would force a cold swap, so those rows only check that llama-swap
# lists the model. The hot local-haiku is always resident — its completion is
# cheap and is the one end-to-end "the stack answers" check. local-embed is hot
# too but serves /v1/embeddings, so it gets the registered probe.
LLM_TIERS=(
    "llama-swap  9000 local-haiku      hard completion"
    "llama-swap  9000 local-embed      hard registered"
    "llama-swap  9000 local-sonnet     opt  registered"
    "llama-swap  9000 local-coder      opt  registered"
    "llama-swap  9000 local-vision     opt  registered"
    "worker-npu  8000 local-classifier opt  completion"
)

# ─── decision functions (unit-testable) ────────────────────────────────────────

# llm_unit_active <unit> — 0 if the systemd --user unit is active.
llm_unit_active() {
    systemctl --user is-active --quiet "$1" 2>/dev/null
}

# llm_port_up <port> — 0 if the worker's /v1/models endpoint answers.
llm_port_up() {
    curl -fsS --max-time "$LLM_CURL_TIMEOUT" \
        "http://127.0.0.1:${1}/v1/models" >/dev/null 2>&1
}

# llm_proxy_up — 0 if the LiteLLM proxy answers /v1/models. Honors the
# documented LLM_PROXY override (host:port), unlike the per-worker llm_port_up
# probes, which are correctly pinned to 127.0.0.1 (workers aren't overridable).
llm_proxy_up() {
    curl -fsS --max-time "$LLM_CURL_TIMEOUT" \
        "${LLM_PROXY}/v1/models" >/dev/null 2>&1
}

# llm_model_registered <model> — 0 if llama-swap lists the model on /v1/models.
# Registration proves the config entry parses and routes; it does NOT load the
# model (that's the point — swap-pool members stay cold until requested).
llm_model_registered() {
    curl -fsS --max-time "$LLM_CURL_TIMEOUT" "${LLM_SWAP}/v1/models" 2>/dev/null \
        | jq -e --arg m "$1" '.data[]? | select(.id == $m)' >/dev/null 2>&1
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
# (differs from the request when a fallback fired, e.g. classifier→haiku).
llm_served_model() {
    local resp; resp=$(_llm_complete "$1") || return 1
    jq -r '.model // empty' <<<"$resp" 2>/dev/null
}

# ─── reports ──────────────────────────────────────────────────────────────────

# Lightweight subset for `dots doctor`: hard units active + proxy reachable.
# A fully-stopped stack is the normal idle state — the stack is never
# auto-started (it gates on models/binaries that may be absent), so a clean
# stop is not a config problem and must not make `dots doctor` fail. Only a
# partially-up / broken stack (some unit active but a sibling or the proxy
# down) is a real issue.
llm_quick_check() {
    local rc=0 active=0
    for u in litellm llama-swap; do
        llm_unit_active "$u" && active=$((active + 1))
    done
    if [[ $active -eq 0 ]]; then
        echo -e "  ${YELLOW}• local LLM stack not running (start with llm-up)${NC}"
        return 0
    fi
    for u in litellm llama-swap; do
        if llm_unit_active "$u"; then
            echo -e "  ${GREEN}✓ $u active${NC}"
        else
            echo -e "  ${RED}✗ $u inactive${NC}"; rc=1
        fi
    done
    if llm_proxy_up; then
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
    if llm_proxy_up; then
        echo -e "  ${GREEN}✓ :4000 responding${NC}"
    else
        echo -e "  ${RED}✗ :4000 not responding${NC}"; hard_fail=1
    fi
    echo -e "${BLUE}llama-swap router${NC}"
    if llm_port_up 9000; then
        echo -e "  ${GREEN}✓ :9000 responding${NC}"
    else
        echo -e "  ${RED}✗ :9000 not responding${NC}"; hard_fail=1
    fi
    echo

    printf '%-17s %-12s %-5s %-11s %-8s %s\n' MODEL UNIT PORT CHECK LATENCY SERVED-AS
    local row unit port model class probe
    for row in "${LLM_TIERS[@]}"; do
        read -r unit port model class probe <<<"$row"
        local comp served lat note resp rc t0 t1
        if [[ "$probe" == "registered" ]]; then
            lat="-"; served="-"; note=""
            if ! llm_port_up "$port"; then
                comp="skip"
                [[ "$class" == "hard" ]] && hard_fail=1
            elif llm_model_registered "$model"; then
                comp="listed"
            else
                comp="FAIL"
                [[ "$class" == "hard" ]] && hard_fail=1
            fi
            printf '%-17s %-12s %-5s %-11s %-8s %s\n' "$model" "$unit" "$port" "$comp" "$lat" "$served"
            continue
        fi
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
        # Flag fallback masking (e.g. local-classifier actually served by local-haiku).
        note=""
        [[ "$comp" == "ok" && "$served" != "$model" && "$served" != "?" ]] && note="  ${YELLOW}(fallback)${NC}"
        printf '%-17s %-12s %-5s %-11s %-8s %s' "$model" "$unit" "$port" "$comp" "$lat" "$served"
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
        echo -e "${RED}═══ Local LLM stack: hard tier unhealthy ═══${NC}"
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
