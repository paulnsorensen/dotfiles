#!/bin/bash
# install-codex.sh — scaffold ~/.codex/ from the dotfiles codex/ source.
#
# config.toml is copied only when ~/.codex/config.toml does not exist yet.
# Existing files stay user-owned, but this installer backfills missing safety
# defaults so older configs keep the repo's Codex baseline without clobbering
# user edits or MCP entries.
#
# Usage:
#   install-codex.sh <source_dir>

set -euo pipefail

codex_config_has() {
    local expr="$1" file="$2"

    command -v yq >/dev/null 2>&1 || return 1
    [[ "$(yq -p=toml "$expr // \"\"" "$file" 2>/dev/null)" != "" ]]
}

codex_prepend_root_defaults() {
    local file="$1"
    local defaults=()

    codex_config_has '.model' "$file" || defaults+=('model = "gpt-5.6-terra"')
    codex_config_has '.model_reasoning_effort' "$file" || defaults+=('model_reasoning_effort = "medium"')
    codex_config_has '.approval_policy' "$file" || defaults+=('approval_policy = "on-request"')
    codex_config_has '.sandbox_mode' "$file" || defaults+=('sandbox_mode = "workspace-write"')
    ((${#defaults[@]})) || return 0

    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "${defaults[@]}" >"$tmp"
    printf '\n' >>"$tmp"
    cat "$file" >>"$tmp"
    mv "$tmp" "$file"
}

codex_set_table_default() {
    local file="$1" section="$2" key="$3" value="$4" expr="$5"

    codex_config_has "$expr" "$file" && return 0

    local tmp
    tmp="$(mktemp)"
    if grep -q "^[[:space:]]*\\[$section\\][[:space:]]*$" "$file"; then
        awk -v section="$section" -v line="$key = $value" '
            $0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$" && !done {
                print
                print line
                done = 1
                next
            }
            { print }
        ' "$file" >"$tmp"
    else
        cat "$file" >"$tmp"
        printf '\n[%s]\n%s = %s\n' "$section" "$key" "$value" >>"$tmp"
    fi
    mv "$tmp" "$file"
}

codex_backfill_config_defaults() {
    local file="$1"

    command -v yq >/dev/null 2>&1 || {
        echo "  Skipped Codex defaults backfill (yq not installed)"
        return 0
    }

    yq -p=toml -o=toml '.' "$file" >/dev/null || {
        echo "install-codex.sh: existing config.toml is not parseable TOML" >&2
        return 1
    }

    codex_prepend_root_defaults "$file"
    codex_set_table_default "$file" sandbox_workspace_write network_access true '.sandbox_workspace_write.network_access'
    codex_set_table_default "$file" tui input_mode '"vim"' '.tui.input_mode'
}

if (( $# != 1 )); then
    echo "Usage: $0 <source_dir>" >&2
    exit 2
fi

source_dir="$1"
codex_home="${CODEX_HOME:-$HOME/.codex}"

if [[ ! -d "$source_dir" ]]; then
    echo "install-codex.sh: source directory not found: $source_dir" >&2
    exit 1
fi

mkdir -p "$codex_home"

src_config="$source_dir/config.toml"
dst_config="$codex_home/config.toml"

if [[ -f "$src_config" ]]; then
    if [[ ! -e "$dst_config" ]]; then
        cp "$src_config" "$dst_config"
        echo "  Scaffolded ~/.codex/config.toml"
    else
        echo "  Skipped ~/.codex/config.toml scaffold (already exists; backfilled missing defaults)"
    fi
    codex_backfill_config_defaults "$dst_config"
fi
