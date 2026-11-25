#!/bin/bash
# install-prompts.sh — wire agents/preamble.md into Codex and OpenCode.
#
# Claude Code reads preamble.md directly via the cc/ccc/ccr wrappers
# in zsh/claude.zsh (--system-prompt-file), so it is not handled here.
#
# Each installed copy is the tilth preamble with preamble.md appended
# (`tilth preamble --append`). tilth owns the tool-routing rules. When tilth
# is missing or too old for --append, the copy is preamble.md alone.
#
# Per-harness mechanism:
#
#   Codex     — write the copy to <CODEX_HOME>/preamble.md, then yq-edit
#               <CODEX_HOME>/config.toml to set
#                 model_instructions_file = "<CODEX_HOME>/preamble.md"
#               This REPLACES the bundled per-model system prompt
#               (codex-rs/core/gpt_5_*_prompt.md). AGENTS.md cascade still
#               loads as developer-role messages (untouched).
#
#   OpenCode  — write the copy to <OPENCODE_HOME>/preamble.md. The
#               `instructions` key in opencode.json (chezmoi/.chezmoidata/
#               opencode.yaml) appends it to OpenCode's own system prompt.
#
# Usage:
#   install-prompts.sh <preamble_path>
#
# Honors:
#   CODEX_HOME        defaults to ~/.codex
#   OPENCODE_HOME     defaults to ~/.config/opencode
#   INSTALL_PROMPTS_HAVE_CODEX       force-on/off codex detection (for tests)
#   INSTALL_PROMPTS_HAVE_YQ          force-on/off yq detection (for tests)
#   TILTH_BIN         the tilth binary; defaults to tilth on PATH

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

# install_prompts_write <preamble> <dest>
# Writes the tilth preamble plus <preamble> to <dest>. Falls back to a plain
# copy of <preamble> when tilth cannot join them.
install_prompts_write() {
    local preamble="$1" dest="$2" tmp
    tmp="$(mktemp "$dest.XXXXXX")"
    if "${TILTH_BIN:-tilth}" preamble --append "$preamble" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$dest"
        echo "  Wrote tilth preamble + $(basename "$preamble") -> $dest"
    else
        rm -f "$tmp"
        cp -f "$preamble" "$dest"
        echo "  Copied $(basename "$preamble") -> $dest (tilth preamble --append unavailable)"
    fi
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
    install_prompts_write "$preamble" "$codex_prompt"

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
        # yq -i appends a new root key at the END of the document, so it lands
        # inside whatever [table] sits at the bottom of config.toml (codex
        # auto-adds [tui.*] there). A root key after a table header belongs to
        # that table, so Codex can't read it as model_instructions_file, the
        # guard above re-reads "" every run, and duplicates accumulate (#262).
        # Instead: drop any existing model_instructions_file line(s) — including
        # a misplaced or duplicated one — and prepend the key at the very top,
        # before any [section] header, where Codex reads it as a root key.
        local escaped tmp
        escaped="${codex_prompt//\\/\\\\}"   # backslash -> \\  for the TOML string
        escaped="${escaped//\"/\\\"}"         # "        -> \"
        tmp="$(mktemp)"
        {
            printf 'model_instructions_file = "%s"\n' "$escaped"
            grep -v '^[[:space:]]*model_instructions_file[[:space:]]*=' "$codex_config" || true
        } >"$tmp"
        mv "$tmp" "$codex_config"
        echo "  Set model_instructions_file in $codex_config"
    fi
}

install_prompts_wire_opencode() {
    local preamble="$1"
    local opencode_home="${OPENCODE_HOME:-$HOME/.config/opencode}"

    mkdir -p "$opencode_home"
    install_prompts_write "$preamble" "$opencode_home/preamble.md"
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
