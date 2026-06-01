#!/bin/bash
#
# install-local-llm.sh — write the `local-llm` opencode provider block idempotently.
#
# opencode talks to the local LiteLLM proxy (http://127.0.0.1:4000/v1, dummy key
# sk-local) as an OpenAI-compatible provider. There is no non-interactive
# `opencode provider add`, so — exactly like the MCP sync jq-edits the `.mcp`
# block (agents/mcp/lib.sh:mcp_opencode_add) — we jq-merge the `.provider`
# block in place. Idempotent: re-running produces a byte-identical file.
#
# Usage: install-local-llm.sh <opencode_json_path>
#
# Run as a subprocess (the run_onchange template execs it; bats runs it too),
# never sourced, so top-level `set -euo pipefail` is safe here.

set -euo pipefail

# Endpoint is overridable for tests / non-default proxies; defaults to the
# stack's LiteLLM front.
LOCAL_LLM_BASE_URL="${LOCAL_LLM_BASE_URL:-http://127.0.0.1:4000/v1}"

install_local_llm_opencode_provider() {
    local cfg="${1:?usage: install-local-llm.sh <opencode_json_path>}"
    local tmp entry

    if ! command -v jq &>/dev/null; then
        echo "Error: jq not found." >&2
        return 1
    fi

    # Scaffold a minimal opencode.json if absent, mirroring chezmoi's
    # create_opencode.json scaffold (so a sync-before-chezmoi run still works).
    if [[ ! -f "$cfg" ]]; then
        mkdir -p "$(dirname "$cfg")"
        # shellcheck disable=SC2016  # literal $schema JSON key, not a shell variable
        echo '{"$schema": "https://opencode.ai/config.json", "formatter": true}' > "$cfg"
    fi

    entry=$(jq -n --arg base "$LOCAL_LLM_BASE_URL" '{
        npm: "@ai-sdk/openai-compatible",
        name: "Local (LiteLLM)",
        options: { baseURL: $base, apiKey: "sk-local" },
        models: {
            "local-sonnet":     { name: "Local Sonnet — Qwen3-30B-A3B (iGPU)" },
            "local-haiku":      { name: "Local Haiku — Qwen3-8B (CPU)" },
            "local-coder":      { name: "Local Coder — Qwen3-Coder-30B-A3B (iGPU)" },
            "local-opus":       { name: "Local Opus — Llama-3.3-70B (iGPU)" },
            "local-vision":     { name: "Local Vision — Qwen2.5-VL-7B (CPU)" },
            "local-classifier": { name: "Local Classifier — Llama-3.2-3B (NPU)" }
        }
    }')

    tmp=$(mktemp)
    jq --argjson entry "$entry" \
        '.provider = ((.provider // {}) | .["local-llm"] = $entry)' "$cfg" > "$tmp" \
        && mv "$tmp" "$cfg"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_local_llm_opencode_provider "${1:-}"
fi
