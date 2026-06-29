#!/usr/bin/env bash
# Local LLM stack aliases — source from ~/.zshrc:  source ~/local-llm/scripts/aliases.sh

# Stack toggles (llama-swap loads/unloads the model backends on demand)
alias llm-up='systemctl --user start  local-llm.target'
alias llm-down='systemctl --user stop  llama-swap litellm worker-npu 2>/dev/null'
alias llm-status='systemctl --user list-units "llama-swap*" "litellm*" "worker-*" "local-llm*" --all --no-pager'
alias llm-logs='journalctl --user -u llama-swap -u litellm -f'

# Swap state (llama-swap API on :9000)
alias llm-loaded='curl -s http://127.0.0.1:9000/running | jq'
alias llm-unload='curl -s -X POST http://127.0.0.1:9000/api/models/unload'

# Optional tiers — separate units outside llama-swap
alias llm-npu-on='systemctl --user start worker-npu'
alias llm-npu-off='systemctl --user stop  worker-npu'

# Endpoints
alias llm-models='curl -s http://127.0.0.1:4000/v1/models | jq'
# shellcheck disable=SC2154  # p is the for-loop variable inside the alias body
alias llm-ping='for p in 4000 9000 8000; do printf "port %s: " $p; curl -s --max-time 1 http://127.0.0.1:$p/v1/models >/dev/null && echo UP || echo down; done'

# Health / verify — smoke-test the stack (units + ports + real completions).
# `llm-test --opencode` also probes the wired opencode provider end-to-end.
alias llm-test='~/local-llm/scripts/healthcheck.sh'
alias llm-health='~/local-llm/scripts/healthcheck.sh'

# On-demand model download (never run by dots sync; idempotent).
alias llm-download='~/local-llm/scripts/download-models.sh'

# Pinned llama-swap binary install/upgrade (manual, like install-npu.sh).
alias llm-install-swap='~/local-llm/scripts/install-llama-swap.sh'

# Launch opencode with the lean MCP overlay so the 32k local-coder window fits.
# OPENCODE_CONFIG mergeDeeps onto the global config — the overlay only disables
# the heavy non-coding servers (hallouminate, tavily), leaving
# tilth + serena + context7 for the coder. Usage: opencode-lean --model local-coder
#
# Pre-flights the local-LLM stack: probes :4000, starts local-llm.target if down,
# waits up to OPENCODE_LEAN_TIMEOUT seconds (default 30), then bails with a hint.
# For a swap-pool model (local-sonnet/local-coder/local-vision) it then fires a
# backgrounded 1-token completion so the ~15-30s cold-load overlaps opencode's
# own startup and the first real turn is instant. Hot models (local-haiku/
# local-embed, resident) and unrecognized models get no warm-up.

# Resolve the effective model: --model <m> / --model=<m> wins, else lean.json's
# default; strip the local-llm/ provider prefix to the bare LiteLLM model_name.
_opencode_lean_model() {
  local model=""
  while (( $# )); do
    case "$1" in
      --model=*) model="${1#--model=}" ;;
      --model)   model="$2"; shift ;;
    esac
    shift
  done
  if [[ -z "$model" ]]; then
    model=$(jq -r '.model // empty' "$HOME/local-llm/configs/lean.json" 2>/dev/null)
  fi
  printf '%s' "${model#local-llm/}"
}

opencode-lean() {
  local timeout="${OPENCODE_LEAN_TIMEOUT:-30}"
  if ! curl -s --max-time 1 http://127.0.0.1:4000/v1/models >/dev/null 2>&1; then
    echo 'local-LLM stack is down — starting local-llm.target...' >&2
    systemctl --user start local-llm.target
    local elapsed=0
    while ! curl -s --max-time 1 http://127.0.0.1:4000/v1/models >/dev/null 2>&1; do
      if (( elapsed >= timeout )); then
        echo "opencode-lean: timed out waiting for local-LLM stack (:4000) after ${timeout}s" >&2
        echo "Hint: run 'llm-up' manually or check 'llm-status'." >&2
        return 1
      fi
      sleep 1
      (( elapsed++ ))
    done
  fi

  # Pre-warm swap-pool models so the cold-load overlaps opencode startup, not
  # the first turn. Backgrounded + detached — launch never blocks on it.
  local model
  model=$(_opencode_lean_model "$@")
  case "$model" in
    local-sonnet|local-coder|local-vision)
      ( curl -s --max-time "${OPENCODE_LEAN_WARM_TIMEOUT:-360}" \
          http://127.0.0.1:4000/v1/chat/completions \
          -H 'Authorization: Bearer sk-local' \
          -H 'Content-Type: application/json' \
          -d "$(jq -nc --arg m "$model" \
                '{model:$m, messages:[{role:"user",content:"."}], max_tokens:1}')" \
          >/dev/null 2>&1 & )
      ;;
  esac

  OPENCODE_CONFIG="$HOME/local-llm/configs/lean.json" opencode "$@"
}

# Quick chat helper — usage: llm-chat local-sonnet "your prompt"
llm-chat() {
  local model="${1:-local-sonnet}"; shift
  local prompt="$*"
  curl -s http://127.0.0.1:4000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer sk-local' \
    -d "$(jq -nc --arg m "$model" --arg p "$prompt" \
      '{model:$m, messages:[{role:"user", content:$p}], max_tokens: 512}')" \
    | jq -r '.choices[0].message.content // .error.message'
}
