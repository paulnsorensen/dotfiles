#!/bin/bash
# Alfred sync-folder confirmation helpers, sourced by alfred/.sync.
#
# Pointing Alfred's Sync Folder (Advanced tab) at $DOTFILES_DIR/alfred/ makes
# the Alfred.alfredpreferences package file-backed so it can be committed.
# See: https://www.alfredapp.com/help/advanced/sync/

: "${ALFRED_DIR:=$(cd "${BASH_SOURCE[0]%/*}" && pwd)}"
: "${ALFRED_PREFS_JSON:=$HOME/Library/Application Support/Alfred/prefs.json}"
: "${ALFRED_APP:=/Applications/Alfred.app}"
: "${ALFRED_APP_5:=/Applications/Alfred 5.app}"

# Echo the configured sync-folder path from Alfred's prefs.json.
#
# The key name is unverified off-macOS: some notes reference `.current`, but
# Alfred may store it under `.syncfolder`. Read both and prefer whichever is
# non-null so the caller's equality check works regardless of which key Alfred
# actually uses. Returns empty when neither key is present. When jq is missing,
# emits a one-time stderr warning and returns 2 so the caller skips the check
# explicitly rather than mistaking it for "points elsewhere".
alfred_current_sync_folder() {
    local prefs="$1"
    if ! command -v jq >/dev/null 2>&1; then
        if [[ -z "${_ALFRED_JQ_WARNED:-}" ]]; then
            echo "alfred/.sync: jq not found - required to read Alfred's sync-folder setting; skipping check" >&2
            _ALFRED_JQ_WARNED=1
        fi
        return 2
    fi
    jq -r '.current // .syncfolder // empty' "$prefs" 2>/dev/null || true
}

alfred_sync() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "alfred/.sync: skipping (not macOS)" >&2
        return 0
    fi
    if ! [[ -d "$ALFRED_APP" || -d "$ALFRED_APP_5" ]]; then
        echo "alfred/.sync: Alfred not installed - install via: brew install --cask alfred" >&2
        return 0
    fi
    if [[ ! -f "$ALFRED_PREFS_JSON" ]]; then
        echo "alfred/.sync: Alfred has never run on this machine - launch it once, then re-run dots sync" >&2
        return 0
    fi

    local current_folder rc=0
    current_folder="$(alfred_current_sync_folder "$ALFRED_PREFS_JSON")" || rc=$?
    if [[ $rc -eq 2 ]]; then
        echo "alfred/.sync: skipping sync-folder check - jq required but not installed" >&2
        return 0
    fi

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
