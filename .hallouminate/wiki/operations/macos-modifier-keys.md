# macOS modifier-key remapping

Keep the `hidutil` LaunchAgent for Caps Lock → Left Control. Apple documents the mapping as a supported Modifier Keys setting, but the checked Apple sources expose no supported CLI for writing the native per-keyboard preference. The LaunchAgent reapplies `hidutil`'s transient mapping at login.[^1][^2]

## Managed mapping

`macos/com.local.KeyRemapping.plist` runs `hidutil property --set` with Caps Lock (`30064771129`) as the source and Left Control (`30064771296`) as the destination. `macos/.sync` installs and bootstraps that LaunchAgent.[^3]

Do not infer absence from `hidutil property --get UserKeyMapping` alone. On macOS 26.5.1, that global read returned `(null)` while the built-in keyboard driver held the exact requested per-device map. Inspect the driver state instead:

```sh
ioreg -a -r -c AppleHIDKeyboardEventDriverV2 \
  | plutil -extract 0.HIDEventServiceProperties.UserKeyMapping json -o - -
```

The verified result was:

```json
[{"HIDKeyboardModifierMappingDst":30064771296,"HIDKeyboardModifierMappingSrc":30064771129}]
```

`tests/macos.bats` protects the static contract: the real sync entry point installs and bootstraps the plist, whose mapping must remain exact. Runtime verification remains an IORegistry check because the test suite does not mutate the operator's keyboard.[^4]

[^1]: <https://support.apple.com/en-us/guide/mac-help/mchlp1011/mac>
[^2]: <https://developer.apple.com/library/archive/technotes/tn2450/_index.html>
[^3]: macos/com.local.KeyRemapping.plist:1-18; macos/.sync:57-73
[^4]: tests/macos.bats:78-110
