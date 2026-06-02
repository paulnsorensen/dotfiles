#!/usr/bin/env bash
# Local LLM stack aliases — source from ~/.zshrc:  source ~/local-llm/scripts/aliases.sh

# Always-on stack toggles
alias llm-up='systemctl --user start  local-llm.target'
alias llm-down='systemctl --user stop  worker-igpu worker-cpu litellm worker-npu worker-coder worker-opus worker-vision 2>/dev/null'
alias llm-status='systemctl --user list-units "worker-*" "litellm*" "local-llm*" --all --no-pager'
alias llm-logs='journalctl --user -u "worker-*" -u litellm -f'

# Optional tier toggles
alias llm-opus-on='systemctl --user start worker-opus'      # auto-stops Sonnet (Conflicts=)
alias llm-opus-off='systemctl --user stop  worker-opus && systemctl --user start worker-igpu'
alias llm-coder-on='systemctl --user start worker-coder'    # auto-stops Sonnet (Conflicts=)
alias llm-coder-off='systemctl --user stop  worker-coder && systemctl --user start worker-igpu'
alias llm-vision-on='systemctl --user start worker-vision'
alias llm-vision-off='systemctl --user stop  worker-vision'
alias llm-npu-on='systemctl --user start worker-npu'
alias llm-npu-off='systemctl --user stop  worker-npu'

# Endpoints
alias llm-models='curl -s http://127.0.0.1:4000/v1/models | jq'
# shellcheck disable=SC2154  # p is the for-loop variable inside the alias body
alias llm-ping='for p in 4000 8080 8081 8000 8085 8090 8082; do printf "port %s: " $p; curl -s --max-time 1 http://127.0.0.1:$p/v1/models >/dev/null && echo UP || echo down; done'

# Health / verify — smoke-test the stack (units + ports + real completions).
# `llm-test --opencode` also probes the wired opencode provider end-to-end.
alias llm-test='~/local-llm/scripts/healthcheck.sh'
alias llm-health='~/local-llm/scripts/healthcheck.sh'

# On-demand model download (never run by dots sync; idempotent).
alias llm-download='~/local-llm/scripts/download-models.sh'

# Launch opencode with the lean MCP overlay so the 32k local-coder window fits.
# OPENCODE_CONFIG mergeDeeps onto the global config — the overlay only disables
# the heavy non-coding servers (code-review-graph, hallouminate, tavily), leaving
# tilth + serena + context7 for the coder. Usage: opencode-lean --model local-coder
opencode-lean() {
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
