#!/bin/bash
# lsp-gate.sh — Compute which LSP plugins should be enabled in cwd.
#
# Single source of truth for the tokei → enabledPlugins mapping. Sourced by
# both the ephemeral session gate (zsh/claude.zsh:_cc_lsp_gate) and the
# persistent project-local writer (bin/cc-lsp-local).
#
# Usage (from a sourced caller):
#   lsp_gate_compute [threshold]   # prints {"name": bool, ...} JSON to stdout
#                                   # returns non-zero if tokei or jq fail

# Map tokei language buckets → LSP plugin name. Threshold is `code` lines.
# Bucket sums let one plugin cover multiple languages (e.g. vtsls = JS+TS+TSX+JSX).
lsp_gate_compute() {
    local threshold="${1:-50}"
    command -v tokei >/dev/null || return 1
    command -v jq >/dev/null || return 1

    tokei --output json | jq --argjson t "$threshold" '{
      "bash-language-server@claude-code-lsps": (([.BASH.code//0,.Shell.code//0,.Zsh.code//0]|add) >= $t),
      "vtsls@claude-code-lsps":                (([.JavaScript.code//0,.TypeScript.code//0,.TSX.code//0,.JSX.code//0]|add) >= $t),
      "yaml-language-server@claude-code-lsps": ((.YAML.code//0) >= $t),
      "rust-analyzer@claude-code-lsps":        ((.Rust.code//0) >= $t),
      "pyright@claude-code-lsps":              ((.Python.code//0) >= $t),
      "gopls@claude-code-lsps":                ((.Go.code//0) >= $t)
    }'
}
