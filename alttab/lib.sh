#!/bin/bash
# AltTab preference import/export helpers, sourced by alttab/.sync and
# alttab/.export. Deriving the bundle id and plist path here (once) keeps both
# entry points from duplicating that setup.
#
# AltTab's defaults schema isn't fully documented and changes between versions,
# so the honest approach is: configure once via the UI, capture the plist here,
# commit it, and import on sync.

: "${ALTTAB_DIR:=$(cd "${BASH_SOURCE[0]%/*}" && pwd)}"
: "${ALTTAB_BUNDLE:=com.lwouis.alt-tab-macos}"
: "${ALTTAB_PLIST:=$ALTTAB_DIR/${ALTTAB_BUNDLE}.plist}"
: "${ALTTAB_APP:=/Applications/AltTab.app}"

alttab_sync() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "alttab/.sync: skipping (not macOS)" >&2
        return 0
    fi
    if ! [[ -d "$ALTTAB_APP" ]]; then
        echo "alttab/.sync: AltTab not installed - install via: brew install --cask alt-tab" >&2
        return 0
    fi
    if [[ ! -f "$ALTTAB_PLIST" ]]; then
        echo "alttab/.sync: no captured plist at $ALTTAB_PLIST yet" >&2
        echo "              configure AltTab once via the UI, then run:" >&2
        echo "                bash $ALTTAB_DIR/.export" >&2
        echo "              recommended one-time settings:" >&2
        echo "                - Hold shortcut 1: Option (so Opt+Tab triggers it)" >&2
        echo "                - Show windows: from all spaces" >&2
        echo "                - Show minimized windows: yes" >&2
        echo "                - Hidden apps: visible (so you can restore minimized)" >&2
        return 0
    fi

    defaults import "$ALTTAB_BUNDLE" "$ALTTAB_PLIST"
    echo "alttab/.sync: imported preferences from $(basename "$ALTTAB_PLIST") - restart AltTab to load"
    echo "                note: sync overwrites UI changes - run alttab/.export first to keep them"
}

alttab_export() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "alttab/.export: skipping (not macOS)" >&2
        return 0
    fi
    if ! defaults read "$ALTTAB_BUNDLE" >/dev/null 2>&1; then
        echo "alttab/.export: no preferences found for $ALTTAB_BUNDLE - is AltTab installed and configured?" >&2
        return 1
    fi

    defaults export "$ALTTAB_BUNDLE" "$ALTTAB_PLIST"
    echo "alttab/.export: wrote $ALTTAB_PLIST"
    echo "                review with: plutil -p '$ALTTAB_PLIST'"
    echo "                commit with: git add '$ALTTAB_PLIST' && git commit"
}
