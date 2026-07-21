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
: "${RECTANGLE_APP:=/Applications/Rectangle Pro.app}"

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

# Hash the full desired config (shortcut table + QoL values) so rectangle_sync
# can skip re-applying when nothing changed. Text comparison of live `defaults
# read` output is fragile (NSNumber float-vs-int printing) -- a hash of our own
# desired inputs sidesteps that entirely.
rectangle_config_hash() {
    {
        rectangle_shortcuts
        echo "subsequentExecutionMode=0"
        echo "launchOnLogin=true"
        echo "hideMenubarIcon=false"
    } | shasum -a 256 | awk '{print $1}'
}

# Write every shortcut plus quality-of-life defaults to $bundle. Idempotent --
# every keyCode/modifierFlags leaf is rewritten each run.
#
# Each shortcut is a dict of NUMERIC keyCode/modifierFlags, written via
# `-dict-add ... -float N` per Rectangle's documented schema
# (TerminalCommands.md). An ASCII plist-dict string "{ keyCode = N; ... }"
# lands the leaves as NSString, which Rectangle's shortcut parser ignores.
rectangle_write_shortcuts() {
    local bundle="$1" hash="$2" cmd keycode mods
    while IFS='|' read -r cmd keycode mods; do
        [[ -z "$cmd" ]] && continue
        defaults write "$bundle" "$cmd" -dict-add keyCode -float "$keycode" modifierFlags -float "$mods"
    done < <(rectangle_shortcuts)

    defaults write "$bundle" subsequentExecutionMode -int 0  # cycle 1/2 -> 2/3 -> 1/3 on repeat
    defaults write "$bundle" launchOnLogin -bool true
    defaults write "$bundle" hideMenubarIcon -bool false
    defaults write "$bundle" dotfilesKeymapHash -string "$hash"

    # Flush the prefs cache so a running Rectangle Pro doesn't overwrite these
    # external writes with its in-memory copy when it next quits.
    killall cfprefsd 2>/dev/null || true
}

# Hard-restart Rectangle Pro so it loads the freshly-written keymap. A graceful
# `osascript quit` lets the running app flush its in-memory prefs over our
# external writes on exit, so kill it outright (pkill -9) instead, then relaunch.
# No-op when the app is not running (nothing to reload) or not installed.
rectangle_restart() {
    pkill -9 -f "Rectangle Pro" 2>/dev/null || return 0
    open "$RECTANGLE_APP" 2>/dev/null || \
        echo "rectangle/.sync: killed Rectangle Pro but relaunch failed - launch it manually to load the keymap" >&2
}

rectangle_sync() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "rectangle/.sync: skipping (not macOS)" >&2
        return 0
    fi
    if ! [[ -d "$RECTANGLE_APP" ]]; then
        echo "rectangle/.sync: Rectangle Pro not installed at $RECTANGLE_APP - skipping" >&2
        echo "                install via: brew install --cask rectangle-pro" >&2
        return 0
    fi

    local hash stamp
    hash="$(rectangle_config_hash)"
    stamp="$(defaults read "$RECTANGLE_BUNDLE" dotfilesKeymapHash 2>/dev/null || true)"
    if [[ "$stamp" == "$hash" ]]; then
        echo "rectangle/.sync: keymap already applied to $RECTANGLE_BUNDLE - skipping (no restart)"
        return 0
    fi

    rectangle_write_shortcuts "$RECTANGLE_BUNDLE" "$hash"
    rectangle_restart

    echo "rectangle/.sync: wrote SizeUp keymap to $RECTANGLE_BUNDLE and reloaded Rectangle Pro"
    # Accessibility is macOS-gated and cannot be granted from a script. If snapping
    # does nothing, the grant is missing (fresh install, app/OS update, or a
    # tccutil reset can drop the app from the list) - make that loud, not silent.
    echo "rectangle/.sync: shortcuts need Accessibility permission - if snapping does nothing, grant it:" >&2
    echo "                 System Settings > Privacy & Security > Accessibility > enable Rectangle Pro" >&2
}
