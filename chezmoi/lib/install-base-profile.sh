#!/bin/bash
# install-base-profile.sh — render the registry-derived `base` profile into
# every harness via the `ap` (agent-profile) tool.
#
# This is the single deploy path that replaces the retired chezmoi scripts
# install-mcp / install-hooks / install-claude-skills (spec curd 7, D1). The
# three separate registries stay the per-type EDIT surface (mcp-edit /
# hook-edit / skill-edit); `base` unions them and `ap` materializes the union.
#
# Two render targets handle a path asymmetry: the four dot-dir harnesses
# (claude/codex/cursor/copilot) write under dot-dirs at $HOME, while opencode's
# renderer writes opencode.json at the target ROOT, so it targets
# $HOME/.config/opencode.
#
#   ap install base --target $HOME                --harness claude,codex,cursor,copilot
#   ap install base --target $HOME/.config/opencode --harness opencode
#
# Usage:
#   install-base-profile.sh <target_home>
#
# Honors:
#   INSTALL_BASE_PROFILE_AP   path to the `ap` binary (default: `ap` on PATH)
set -euo pipefail

target="${1:-}"
if [[ -z "$target" ]]; then
    echo "Usage: install-base-profile.sh <target_home>" >&2
    exit 2
fi

ap_bin="${INSTALL_BASE_PROFILE_AP:-ap}"
if ! command -v "$ap_bin" &>/dev/null && [[ ! -x "$ap_bin" ]]; then
    echo "install-base-profile: ap binary not found ('$ap_bin')" >&2
    exit 1
fi

# Dot-dir harnesses render under $HOME.
"$ap_bin" install base --target "$target" \
    --harness claude,codex,cursor,copilot

# opencode writes opencode.json at the target root → its own target dir.
"$ap_bin" install base --target "$target/.config/opencode" \
    --harness opencode
