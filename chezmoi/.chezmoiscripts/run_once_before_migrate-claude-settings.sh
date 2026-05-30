#!/bin/bash
# run_once_before — one-time migration: drop the legacy
# ~/.claude/settings.json symlink so chezmoi can seed the file from
# dot_claude/create_settings.json.
#
# Before this change, claude/.sync symlinked $DOTFILES/claude/settings.json
# into ~/.claude/settings.json. The committed source has been retired and
# moved to chezmoi/dot_claude/create_settings.json (a `create_` seed —
# chezmoi creates it once and never updates after). The retired symlink
# would otherwise block chezmoi's create_ step (the target "exists" but
# points at a now-gone source).
#
# Idempotent: a no-op once the symlink is gone. run_once_ ensures this
# script never runs again on this host after a clean pass, so renaming
# this file is the only way to force a re-run on the same host.
set -euo pipefail

target="$HOME/.claude/settings.json"
if [[ -L "$target" ]]; then
    link_dest=$(readlink "$target")
    case "$link_dest" in
        */dotfiles/claude/settings.json)
            echo "  Migrating: removing legacy settings.json symlink (was $link_dest)"
            rm -f "$target"
            ;;
        *)
            echo "  Skipping migration: ~/.claude/settings.json links to $link_dest (not the legacy dotfiles source)"
            ;;
    esac
fi
