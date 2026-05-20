#!/bin/bash
# install-prompts.sh — wire agents/preamble.md as the system prompt for
# harnesses that support replacement (Codex CLI, opencode).
#
# Claude Code reads preamble.md directly via the cc/ccc/ccr/ccfresh wrappers
# in zsh/claude.zsh (--system-prompt-file), so it is not handled here.
#
# Per-harness mechanism:
#
#   Codex     — copy preamble.md to <CODEX_HOME>/preamble.md, then yq-edit
#               <CODEX_HOME>/config.toml to set
#                 model_instructions_file = "<CODEX_HOME>/preamble.md"
#               This REPLACES the bundled per-model system prompt
#               (codex-rs/core/gpt_5_*_prompt.md). AGENTS.md cascade still
#               loads as developer-role messages (untouched).
#
#   opencode  — copy preamble.md to <OPENCODE_HOME>/agents/build.md.
#               opencode reads {agent,agents}/**/*.md and uses the file body
#               as the agent's system prompt
#               (packages/opencode/src/config/agent.ts:125). "build" is the
#               default agent, so bare `opencode` picks it up.
#
# Harness CLIs that are not installed are skipped silently.
#
# Usage:
#   install-prompts.sh <preamble_path>
#
# Honors:
#   CODEX_HOME        defaults to ~/.codex
#   OPENCODE_HOME     defaults to ~/.config/opencode
#   INSTALL_PROMPTS_HAVE_CODEX       force-on/off codex detection (for tests)
#   INSTALL_PROMPTS_HAVE_OPENCODE    force-on/off opencode detection (for tests)
#   INSTALL_PROMPTS_HAVE_YQ          force-on/off yq detection (for tests)

set -euo pipefail

install_prompts_have() {
    local cmd="$1"
    # Manual uppercase — `${var^^}` requires bash 4+; macOS ships bash 3.2.
    local cmd_upper
    cmd_upper="$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')"
    local override_var="INSTALL_PROMPTS_HAVE_${cmd_upper}"
    if [[ -n "${!override_var:-}" ]]; then
        [[ "${!override_var}" == "1" ]]
        return $?
    fi
    command -v "$cmd" &>/dev/null
}

install_prompts_wire_codex() {
    local preamble="$1"
    local codex_home="${CODEX_HOME:-$HOME/.codex}"
    local codex_prompt="$codex_home/preamble.md"
    local codex_config="$codex_home/config.toml"

    install_prompts_have codex || {
        echo "  Skipped Codex wiring (codex not installed)"
        return 0
    }

    mkdir -p "$codex_home"
    cp -f "$preamble" "$codex_prompt"
    echo "  Copied preamble.md -> $codex_prompt"

    if [[ ! -f "$codex_config" ]]; then
        echo "  Skipped $codex_config (not yet scaffolded; will pick up the prompt path on next dots sync)"
        return 0
    fi

    if ! install_prompts_have yq; then
        echo "  Skipped $codex_config update (yq not installed)"
        return 0
    fi

    local current
    current="$(yq -p=toml '.model_instructions_file // ""' "$codex_config" 2>/dev/null || true)"
    if [[ "$current" != "$codex_prompt" ]]; then
        yq -p=toml -o=toml -i ".model_instructions_file = \"$codex_prompt\"" "$codex_config"
        echo "  Set model_instructions_file in $codex_config"
    fi
}

install_prompts_wire_opencode() {
    local preamble="$1"
    local opencode_home="${OPENCODE_HOME:-$HOME/.config/opencode}"
    local opencode_prompt="$opencode_home/agents/build.md"

    install_prompts_have opencode || {
        echo "  Skipped opencode wiring (opencode not installed)"
        return 0
    }

    mkdir -p "$(dirname "$opencode_prompt")"
    cp -f "$preamble" "$opencode_prompt"
    echo "  Copied preamble.md -> $opencode_prompt"
}

install_prompts_main() {
    local preamble="${1:-}"
    if [[ -z "$preamble" ]]; then
        echo "Usage: install-prompts.sh <preamble_path>" >&2
        return 2
    fi
    if [[ ! -f "$preamble" ]]; then
        echo "install-prompts: $preamble not found, skipping" >&2
        return 0
    fi
    install_prompts_wire_codex "$preamble"
    install_prompts_wire_opencode "$preamble"
}

# Only run main when this file is executed directly (not when sourced by bats).
# shellcheck disable=SC2128
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_prompts_main "$@"
fi
