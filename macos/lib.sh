#!/bin/bash
# Typed preference updates used by macos/.sync.

# Echo the Spotlight (ID 64) modifier mask. Alfred owns ⌘Space when it is
# installed, so Spotlight moves to ⌃⌘Space (1310720); otherwise ⌘Space
# (1048576) opens Spotlight.
macos_spotlight_modifiers() {
    if [[ -d "${ALFRED_APP:-/Applications/Alfred.app}" ||
        -d "${ALFRED_APP_5:-/Applications/Alfred 5.app}" ]]; then
        printf '1310720\n'
    else
        printf '1048576\n'
    fi
}

# Replace or insert one typed AppleSymbolicHotKeys entry in an exported plist.
macos_set_symbolic_hotkey() {
    local id="$1" json="$2" plist="$3"
    plutil -replace "AppleSymbolicHotKeys.$id" -json "$json" "$plist" 2>/dev/null ||
        plutil -insert "AppleSymbolicHotKeys.$id" -json "$json" "$plist"
}

macos_write_symbolic_hotkeys() {
    local domain="${1:-com.apple.symbolichotkeys}"
    local plist rc=0
    local launchpad='{"enabled":true,"value":{"parameters":[32,49,1179648],"type":"standard"}}'
    local spotlight
    spotlight="{\"enabled\":true,\"value\":{\"parameters\":[32,49,$(macos_spotlight_modifiers)],\"type\":\"standard\"}}"

    plist="$(mktemp "${TMPDIR:-/tmp}/dotfiles-symbolichotkeys.XXXXXX")"
    defaults export "$domain" "$plist" >/dev/null || rc=$?

    if (( rc == 0 )); then
        plutil -replace AppleSymbolicHotKeys.60.enabled -bool false "$plist" || rc=$?
    fi
    if (( rc == 0 )); then
        plutil -replace AppleSymbolicHotKeys.61.enabled -bool false "$plist" || rc=$?
    fi
    if (( rc == 0 )); then
        macos_set_symbolic_hotkey 64 "$spotlight" "$plist" || rc=$?
    fi
    if (( rc == 0 )); then
        macos_set_symbolic_hotkey 160 "$launchpad" "$plist" || rc=$?
    fi
    if (( rc == 0 )); then
        defaults import "$domain" "$plist" >/dev/null || rc=$?
    fi

    rm -f "$plist"
    return "$rc"
}
