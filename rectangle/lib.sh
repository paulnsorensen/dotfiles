#!/bin/bash
# Rectangle Pro shortcut-configuration helpers, sourced by rectangle/.sync.
#
# Reference: https://github.com/rxhanson/Rectangle/blob/main/TerminalCommands.md
#   The same defaults schema works for Rectangle (com.knollsoft.Rectangle) and
#   Rectangle Pro (com.knollsoft.Hookshot). This targets Pro.
#
# Modifier integer values (sum to combine):
#   cmd = 1048576, option = 524288, ctrl = 262144, shift = 131072
#   ctrl+opt+cmd = 1835008, ctrl+opt+shift = 917504, ctrl+opt = 786432
#
# Key codes are macOS virtual key codes (NSEvent keyCode).

: "${RECTANGLE_BUNDLE:=com.knollsoft.Hookshot}"

# Emit the shortcut table, one "command|keyCode|modifierFlags" per line.
rectangle_shortcuts() {
    local ctrl_opt_cmd=1835008 ctrl_opt_shift=917504 ctrl_opt=786432
    cat <<EOF
leftHalf|123|$ctrl_opt_cmd
rightHalf|124|$ctrl_opt_cmd
topHalf|126|$ctrl_opt_cmd
bottomHalf|125|$ctrl_opt_cmd
topLeft|123|$ctrl_opt_shift
topRight|126|$ctrl_opt_shift
bottomLeft|125|$ctrl_opt_shift
bottomRight|124|$ctrl_opt_shift
maximize|46|$ctrl_opt_cmd
center|8|$ctrl_opt_cmd
restore|44|$ctrl_opt_cmd
almostMaximize|36|$ctrl_opt_cmd
firstThird|2|$ctrl_opt
centerThird|3|$ctrl_opt
lastThird|5|$ctrl_opt
firstTwoThirds|14|$ctrl_opt
lastTwoThirds|17|$ctrl_opt
nextDisplay|30|$ctrl_opt_cmd
previousDisplay|33|$ctrl_opt_cmd
EOF
}

# Write every shortcut plus quality-of-life defaults to $bundle. Idempotent --
# each `defaults write` overwrites cleanly.
#
# SCHEMA CAVEAT: each shortcut is written as the old-style ASCII plist-dict
# STRING "{ keyCode = N; modifierFlags = M; }". Whether Rectangle Pro parses
# this shape cannot be verified off-macOS. After a real sync, round-trip one
# shortcut manually to confirm:
#   defaults read com.knollsoft.Hookshot leftHalf
# then check Rectangle Pro actually honors the binding in its UI.
rectangle_write_shortcuts() {
    local bundle="$1" cmd keycode mods
    while IFS='|' read -r cmd keycode mods; do
        [[ -z "$cmd" ]] && continue
        defaults write "$bundle" "$cmd" "{ keyCode = $keycode; modifierFlags = $mods; }"
    done < <(rectangle_shortcuts)

    defaults write "$bundle" subsequentExecutionMode -int 0  # cycle 1/2 -> 2/3 -> 1/3 on repeat
    defaults write "$bundle" launchOnLogin -bool true
    defaults write "$bundle" hideMenubarIcon -bool false

    # Flush the prefs cache so a running Rectangle Pro doesn't overwrite these
    # external writes with its in-memory copy when it next quits.
    killall cfprefsd 2>/dev/null || true
}

rectangle_sync() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "rectangle/.sync: skipping (not macOS)" >&2
        return 0
    fi
    if ! [[ -d "/Applications/Rectangle Pro.app" ]]; then
        echo "rectangle/.sync: Rectangle Pro not installed at /Applications - skipping" >&2
        echo "                install via: brew install --cask rectangle-pro" >&2
        return 0
    fi

    rectangle_write_shortcuts "$RECTANGLE_BUNDLE"

    echo "rectangle/.sync: wrote SizeUp keymap to $RECTANGLE_BUNDLE - restart Rectangle Pro to load"
    echo "rectangle/.sync: VERIFY manually - 'defaults read $RECTANGLE_BUNDLE leftHalf', then confirm" >&2
    echo "                 Rectangle Pro honors it (plist-dict string schema is unverified off-macOS)" >&2
}
