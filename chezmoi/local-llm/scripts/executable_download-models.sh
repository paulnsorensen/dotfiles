#!/usr/bin/env bash
#
# download-models.sh — fetch the GGUF weights for the local LLM stack on demand.
#
# This is NEVER run by `dots sync` — the weights are 85G and machine-specific.
# Run it by hand (alias `llm-download`) on a box where you want the stack live.
# Idempotent: any model file already present in ~/local-llm/models is skipped.
#
# PREREQUISITES this script does NOT handle (documented in README.md):
#   - the built llama.cpp + lemonade binaries under ~/local-llm/bin/
#   - the LiteLLM install at ~/.local/bin/litellm
#
# Repo IDs: opus + vision are confirmed from the stack README. The three Qwen3
# repos below are NOT recorded anywhere on the source machine; they follow the
# same unsloth naming convention as the confirmed opus repo
# (unsloth/<Model>-GGUF + <Model>-Q4_K_M.gguf) but are UNVERIFIED — confirm on
# huggingface.co before a fresh-machine download. `hf download` fails loud if a
# repo/file is wrong, so a bad guess cannot silently produce a broken stack.

set -euo pipefail

MODELS_DIR="${LLM_MODELS_DIR:-$HOME/local-llm/models}"

# "repo  file  confidence"
MODELS=(
    "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF  Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf  unverified"  # sonnet
    "unsloth/Qwen3-8B-GGUF                      Qwen3-8B-Q4_K_M.gguf                     unverified"  # haiku
    "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF  Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf unverified"  # coder
    "unsloth/Llama-3.3-70B-Instruct-GGUF        Llama-3.3-70B-Instruct-Q4_K_M.gguf       confirmed"   # opus
    "ggml-org/Qwen2.5-VL-7B-Instruct-GGUF       Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf       confirmed"   # vision
    "ggml-org/Qwen2.5-VL-7B-Instruct-GGUF       mmproj-Qwen2.5-VL-7B-Instruct-Q8_0.gguf  confirmed"   # vision mmproj
)

main() {
    if ! command -v hf &>/dev/null; then
        echo "Error: 'hf' (huggingface CLI) not found. Install with: uv tool install huggingface_hub" >&2
        exit 1
    fi
    mkdir -p "$MODELS_DIR"

    local repo file conf skipped=0 fetched=0
    for entry in "${MODELS[@]}"; do
        read -r repo file conf <<<"$entry"
        if [[ -f "$MODELS_DIR/$file" ]]; then
            echo "✓ present, skipping: $file"
            skipped=$((skipped + 1))
            continue
        fi
        [[ "$conf" == "unverified" ]] && \
            echo "⚠ repo '$repo' is UNVERIFIED — confirm on huggingface.co if this fails"
        echo "↓ downloading: $repo  $file"
        hf download "$repo" "$file" --local-dir "$MODELS_DIR"
        fetched=$((fetched + 1))
    done

    echo
    echo "done — $fetched fetched, $skipped already present in $MODELS_DIR"
    echo "Start the stack with: llm-up   (workers gate on model presence via ConditionPathExists)"
}

main "$@"
