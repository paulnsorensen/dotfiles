#!/bin/bash
# run_once_before — one-time migration: drop the legacy ~/.claude/agents
# symlink BEFORE the base-profile installer renders agents into $HOME.
#
# Before this change, claude/.sync symlinked $DOTFILES/claude/agents into
# ~/.claude/agents. The cheese sub-agents have moved to agents/registry.yaml
# and now render through `ap` (the `base`/`global` profile) as real files at
# ~/.claude/agents/<name>.md plus the plugin tree. If the symlink were still
# present when `ap install global` runs (run_onchange_after_install-base-profile),
# ap would write THROUGH the symlink straight back into the repo's
# claude/agents/ — clobbering the now-instruction-only source bodies.
#
# chezmoi runs run_before_* scripts ahead of run_after_* scripts in a single
# apply, so removing the symlink here guarantees the installer writes into a
# real directory. claude/.sync also removes it (belt) for the legacy symlink
# sync path; this is the chezmoi-ordering guarantee.
#
# Idempotent: a no-op once the symlink is gone. run_once_ ensures this never
# runs again on this host after a clean pass.
set -euo pipefail

target="$HOME/.claude/agents"
if [[ -L "$target" ]]; then
    link_dest=$(readlink "$target")
    case "$link_dest" in
        */dotfiles/claude/agents)
            echo "  Migrating: removing legacy ~/.claude/agents symlink (was $link_dest)"
            rm -f "$target"
            ;;
        *)
            echo "  Skipping migration: ~/.claude/agents links to $link_dest (not the legacy dotfiles source)"
            ;;
    esac
fi
