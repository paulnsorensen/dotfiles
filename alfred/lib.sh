#!/bin/bash
# Alfred sync-folder confirmation helpers, sourced by alfred/.sync.
#
# Pointing Alfred's Sync Folder (Advanced tab) at $DOTFILES_DIR/alfred/ makes
# the Alfred.alfredpreferences package file-backed so it can be committed.
# See: https://www.alfredapp.com/help/advanced/sync/

: "${ALFRED_DIR:=$(cd "${BASH_SOURCE[0]%/*}" && pwd)}"
: "${ALFRED_PREFS_JSON:=$HOME/Library/Application Support/Alfred/prefs.json}"

# Echo the configured sync-folder path from Alfred's prefs.json.
#
# The key name is unverified off-macOS: some notes reference `.current`, but
# Alfred may store it under `.syncfolder`. Read both and prefer whichever is
# non-null so the caller's equality check works regardless of which key Alfred
# actually uses. Returns empty when jq is missing or neither key is present.
alfred_current_sync_folder() {
    local prefs="$1"
    command -v jq >/dev/null 2>&1 || return 0
    jq -r '.current // .syncfolder // empty' "$prefs" 2>/dev/null || true
}

alfred_sync() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "alfred/.sync: skipping (not macOS)" >&2
        return 0
    fi
    if ! [[ -d "/Applications/Alfred.app" || -d "/Applications/Alfred 5.app" ]]; then
        echo "alfred/.sync: Alfred not installed - install via: brew install --cask alfred" >&2
        return 0
    fi
    if [[ ! -f "$ALFRED_PREFS_JSON" ]]; then
        echo "alfred/.sync: Alfred has never run on this machine - launch it once, then re-run dots sync" >&2
        return 0
    fi

    local current_folder
    current_folder="$(alfred_current_sync_folder "$ALFRED_PREFS_JSON")"

    if [[ "$current_folder" == "$ALFRED_DIR" ]]; then
        echo "alfred/.sync: sync folder already points at $ALFRED_DIR"
        if [[ ! -d "$ALFRED_DIR/Alfred.alfredpreferences" ]]; then
            echo "              note: no Alfred.alfredpreferences package in this dir yet -" >&2
            echo "                    it will be created when Alfred next saves preferences" >&2
        fi
        return 0
    fi

    echo "alfred/.sync: Alfred sync folder is not pointing at this dotfiles dir."
    echo "              current: ${current_folder:-<unset>}"
    echo "              target:  $ALFRED_DIR"
    echo
    echo "              One-time setup:"
    echo "                Alfred -> Preferences -> Advanced -> Set sync folder..."
    echo "                pick: $ALFRED_DIR"
    echo "                then restart Alfred."
}
