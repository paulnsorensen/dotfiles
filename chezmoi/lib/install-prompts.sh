#!/bin/bash
# install-prompts.sh — add agents/preamble.md to each harness's native prompt.
#
# Claude Code reads preamble.md directly via the cc/ccc/ccr wrappers
# in zsh/claude.zsh (--append-system-prompt-file), so it is not handled here.
#
# Per-harness mechanism:
#
#   Codex     — copy preamble.md to <CODEX_HOME>/preamble.md for migration
#               compatibility, then add its content to the native
#               developer_instructions setting. This preserves Codex's bundled
#               model instructions and any user-authored developer instructions.
#
# Usage:
#   install-prompts.sh <preamble_path>
#
# Honors:
#   CODEX_HOME        defaults to ~/.codex
#   INSTALL_PROMPTS_HAVE_CODEX       force-on/off codex detection (for tests)
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
    local managed_start="<!-- dotfiles:managed-preamble:start -->"
    local managed_end="<!-- dotfiles:managed-preamble:end -->"

    install_prompts_have codex || {
        echo "  Skipped Codex wiring (codex not installed)"
        return 0
    }

    mkdir -p "$codex_home"
    cp -f "$preamble" "$codex_prompt"
    echo "  Copied preamble.md -> $codex_prompt"

    if [[ ! -f "$codex_config" ]]; then
        echo "  Skipped $codex_config (not yet scaffolded; will pick up the prompt on next dots sync)"
        return 0
    fi

    if ! install_prompts_have yq; then
        echo "  Skipped $codex_config update (yq not installed)"
        return 0
    fi

    local current_model current_dev preamble_text managed_block
    current_model="$(yq -p=toml -r '.model_instructions_file // ""' "$codex_config" 2>/dev/null || true)"
    current_dev="$(yq -p=toml -r '.developer_instructions // ""' "$codex_config" 2>/dev/null || true)"
    preamble_text="$(<"$preamble")"
    managed_block="${managed_start}
${preamble_text}
${managed_end}"

    # Remove the managed block and the separator this installer added before it.
    while [[ "$current_dev" == *"$managed_start"*"$managed_end"* ]]; do
        local prefix suffix
        prefix="${current_dev%%"$managed_start"*}"
        suffix="${current_dev#*"$managed_end"}"
        [[ "$prefix" == *$'\n\n' ]] && prefix="${prefix%$'\n\n'}"
        current_dev="${prefix}${suffix}"
    done
    # A first migration can encounter a plain copied preamble from an operator.
    [[ "$current_dev" == "$preamble_text" ]] && current_dev=

    local new_dev
    if [[ -n "$current_dev" ]]; then
        new_dev="${current_dev}"$'\n\n'"$managed_block"
    else
        new_dev="$managed_block"
    fi

    # model_instructions_file replaces Codex's vendor prompt. Remove it only
    # when its value matches the path written by the retired installer.
    export DOTFILES_MANAGED_DEVELOPER_INSTRUCTIONS="$new_dev"
    local expression
    if [[ "$current_model" == "$codex_prompt" ]]; then
        expression='del(.model_instructions_file) | .developer_instructions = strenv(DOTFILES_MANAGED_DEVELOPER_INSTRUCTIONS)'
        echo "  Migrated model_instructions_file in $codex_config"
    else
        expression='.developer_instructions = strenv(DOTFILES_MANAGED_DEVELOPER_INSTRUCTIONS)'
    fi

    local tmp
    tmp="$(mktemp)"
    if ! yq -p=toml -o=toml "$expression" "$codex_config" >"$tmp"; then
        rm -f "$tmp"
        echo "  Skipped $codex_config update (invalid TOML)" >&2
        return 0
    fi
    mv "$tmp" "$codex_config"
    echo "  Added shared developer instructions to $codex_config"
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
}

# Only run main when this file is executed directly (not when sourced by bats).
# shellcheck disable=SC2128
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_prompts_main "$@"
fi
