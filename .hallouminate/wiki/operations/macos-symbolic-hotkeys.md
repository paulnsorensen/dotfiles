# macOS symbolic-hotkey preference typing

Never pass nested symbolic-hotkey dictionaries to `defaults write ... -dict-add` as OpenStep text. The leaf values serialize as strings, so `enabled = 0` becomes `"0"`; macOS Tahoe treats that non-empty string as enabled and re-checks the Input Sources shortcut.[^1]

## Managed write path

`macos/.sync` delegates symbolic-hotkey changes to `macos_write_symbolic_hotkeys`.[^2] The helper exports the complete `com.apple.symbolichotkeys` domain, uses `plutil` for typed edits, then imports the domain. This preserves unknown hotkeys and the existing payloads for IDs 60 and 61.

The managed bindings are:

- ID 60 (Control-Space): boolean `false`, existing `value` preserved.
- ID 61 (Control-Option-Space): boolean `false`, existing `value` preserved.
- ID 160 (Launchpad): boolean `true`; parameters `[32, 49, 1179648]` are integers.

Apple documents Control-Space and Control-Option-Space as the previous/next input-source shortcuts.[^3]

## Regression seam

`tests/macos.bats` runs the real `macos/.sync` entry point against an isolated preference domain. It asserts boolean enabled flags, integer Launchpad parameters, and preservation of the input-source binding payloads.[^4]

[^1]: Reproduced on macOS 26.5.1 with `defaults write /tmp/prefs AppleSymbolicHotKeys -dict-add 60 '{enabled = 0;}'`; `plutil -type AppleSymbolicHotKeys.60.enabled` returned `string`.
[^2]: macos/.sync:35-55; macos/lib.sh:4-27
[^3]: <https://support.apple.com/en-us/102650>
[^4]: tests/macos.bats:46-76
