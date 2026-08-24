#!/bin/bash
# Typed preference updates used by macos/.sync.

macos_write_symbolic_hotkeys() {
    local domain="${1:-com.apple.symbolichotkeys}"
    local plist rc=0
    local launchpad='{"enabled":true,"value":{"parameters":[32,49,1179648],"type":"standard"}}'

    plist="$(mktemp "${TMPDIR:-/tmp}/dotfiles-symbolichotkeys.XXXXXX")"
    defaults export "$domain" "$plist" >/dev/null || rc=$?

    if (( rc == 0 )); then
        plutil -replace AppleSymbolicHotKeys.60.enabled -bool false "$plist" || rc=$?
    fi
    if (( rc == 0 )); then
        plutil -replace AppleSymbolicHotKeys.61.enabled -bool false "$plist" || rc=$?
    fi
    if (( rc == 0 )) &&
        ! plutil -replace AppleSymbolicHotKeys.160 -json "$launchpad" "$plist" 2>/dev/null; then
        plutil -insert AppleSymbolicHotKeys.160 -json "$launchpad" "$plist" || rc=$?
    fi
    if (( rc == 0 )); then
        defaults import "$domain" "$plist" >/dev/null || rc=$?
    fi

    rm -f "$plist"
    return "$rc"
}
