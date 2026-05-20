#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${TMUX:-}" ]]; then
    tmux set-option -q @jmux-attention 1
fi
