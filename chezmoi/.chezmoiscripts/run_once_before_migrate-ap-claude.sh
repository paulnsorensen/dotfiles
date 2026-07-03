#!/bin/bash
# run_once_before — one-time migration off the ap/agent-profile live install
# to the chezmoi-authoritative ~/.claude regime
# (spec: chezmoi-authoritative-claude).
#
# Runs BEFORE the first authoritative apply:
#   1. Timestamped backups of ~/.claude/settings.json and ~/.claude.json —
#      the first apply wipes formerly-ap settings keys and the MCP reconcile
#      starts mutating ~/.claude.json.
#   2. Remove ~/.claude/plugins/local/* — the ap-rendered plugin trees
#      (live/global). Their hooks/commands now deploy via dot_claude/exact_*
#      and the settings.json `hooks` key. Claude's own plugin cache /
#      marketplace state elsewhere under ~/.claude/plugins is left alone.
#   3. Remove the legacy install-claude-assets manifest (asset dirs are now
#      exact_-managed; the manifest mechanism is retired).
#   4. Unlink legacy write-through symlinks at ~/.claude/{hooks,reference,
#      agents,mcp} (they point into the dotfiles checkout; hooks/reference/
#      agents gain exact_ dirs that must be real directories — a followed
#      symlink would let chezmoi delete files INSIDE the repo — and a stale
#      mcp symlink would otherwise linger dangling).

set -euo pipefail

ts=$(date +%Y%m%d-%H%M%S)

for f in "$HOME/.claude/settings.json" "$HOME/.claude.json"; do
    if [[ -f "$f" ]]; then
        cp "$f" "$f.pre-chezmoi-authoritative.$ts.bak"
        echo "  Backed up $f -> $f.pre-chezmoi-authoritative.$ts.bak"
    fi
done

if [[ -d "$HOME/.claude/plugins/local" ]]; then
    rm -rf "$HOME/.claude/plugins/local"
    echo "  Removed ap plugin trees: ~/.claude/plugins/local"
fi

# Legacy per-dir asset-installer manifests (retired install-claude-assets.sh).
for d in commands hooks reference workflows; do
    m="$HOME/.claude/$d/.dotfiles-managed-claude-assets"
    if [[ -e "$m" ]]; then
        rm -f "$m"
        echo "  Removed legacy claude-assets manifest: ~/.claude/$d"
    fi
done

for item in hooks reference agents mcp; do
    if [[ -L "$HOME/.claude/$item" ]]; then
        rm "$HOME/.claude/$item"
        echo "  Unlinked legacy write-through symlink: ~/.claude/$item"
    fi
done
