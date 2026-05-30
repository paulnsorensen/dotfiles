#!/bin/bash
# install-base-profile.sh — render `base` (or its `global` wrapper) into
# every harness via the `ap` (agent-profile) tool.
#
# This is the single deploy path that replaces the retired chezmoi scripts
# install-mcp / install-hooks / install-claude-skills (spec curd 7, D1). The
# three separate registries stay the per-type EDIT surface (mcp-edit /
# hook-edit / skill-edit); `base` unions them, `global` wraps base with the
# operator-intent fields (target_default=$HOME, claude marketplace + plugin
# enablement), and `ap` materializes the union for each harness.
#
# Two render targets handle a path asymmetry: the four dot-dir harnesses
# (claude/codex/cursor/copilot) write under dot-dirs at $HOME, while opencode's
# renderer writes opencode.json at the target ROOT, so it targets
# $HOME/.config/opencode.
#
# For the dot-dir harnesses we install the `global` profile so its
# target_default + claude.marketplace + claude.enabled_plugins land — that
# wires the rendered plugin tree into ~/.claude/settings.json so its
# SessionStart hook (cheese-flair) and bundled MCPs/skills become live.
# `--target` is intentionally omitted; the profile resolves $HOME itself.
#
# opencode has no plugin-enablement surface — `base` is sufficient there,
# and its target stays explicit ($HOME/.config/opencode is not $HOME).
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

# Dot-dir harnesses render the global profile, which carries the operator
# overlay (target_default=$HOME plus the claude marketplace + plugin
# enablement). HOME is forwarded explicitly so the profile's $HOME
# expansion respects the caller's target argument when it differs from
# the process HOME (the chezmoi installer passes $HOME so they match;
# direct callers can pass anything).
HOME="$target" "$ap_bin" install global \
    --harness claude,codex,cursor,copilot

# opencode writes opencode.json at the target root → its own target dir.
# Uses `base` directly: opencode has no plugin/marketplace surface to
# enable, and its target is not $HOME so target_default doesn't apply.
"$ap_bin" install base --target "$target/.config/opencode" \
    --harness opencode
