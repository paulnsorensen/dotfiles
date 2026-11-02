# shellcheck shell=bash
# Render the currently loaded scheme as a T3 Code published theme file at $1.
# T3 reads ~/.t3/userdata/themes/<id>.json; the filename is the theme ID.
# The file sets every T3 color role, so T3 derives nothing from canvas/accent.

# Blend hex color $1 over hex color $2 at $3 percent. Prints rrggbb.
mix_hex() {
  local fg="$1" bg="$2" pct="$3" out="" i a b
  for i in 0 2 4; do
    a=$((16#${fg:i:2}))
    b=$((16#${bg:i:2}))
    out+=$(printf '%02x' $(((a * pct + b * (100 - pct) + 50) / 100)))
  done
  echo "$out"
}

write_t3_theme() {
  local out="$1"
  local canvas surface overlay accent error border input
  canvas="$(pal base00)"
  # Share the Zed panel shades: base00-base02 are too close to separate surfaces.
  surface=$(yq -r '.zed.panel_background // .palette.base01' "$SCHEME_FILE")
  overlay=$(yq -r '.zed.elevated_background // .palette.base01' "$SCHEME_FILE")
  accent=$(yq -r '.zed.ui_accent // .palette.base0D' "$SCHEME_FILE")
  error=$(yq -r '.t3.error // .palette.base08' "$SCHEME_FILE")
  border=$(mix_hex "$(pal base05)" "$canvas" 14)
  input=$(mix_hex "$(pal base05)" "$canvas" 20)

  cat > "$out" <<T3_THEME
{
  "version": 1,
  "name": "${SCHEME_NAME}",
  "appearance": "dark",
  "canvas": "#${canvas}",
  "accent": "#${accent}",
  "colors": {
    "canvas": "#${canvas}",
    "chrome": "#${canvas}",
    "toolbar": "#${canvas}",
    "toolbarForeground": "#$(pal base05)",
    "toolbarBorder": "#$(pal base02)",
    "toolbarControl": "#$(pal base01)",
    "toolbarControlForeground": "#$(pal base05)",
    "toolbarControlHover": "#$(pal base02)",
    "surface": "#${surface}",
    "surfaceRaised": "#${surface}",
    "surfaceOverlay": "#${overlay}",
    "text": "#$(pal base05)",
    "textMuted": "#$(pal base04)",
    "border": "#${border}",
    "input": "#${input}",
    "focus": "#${accent}",
    "accent": "#${accent}",
    "accentForeground": "#$(pal base11)",
    "secondary": "#${surface}",
    "secondaryForeground": "#$(pal base05)",
    "muted": "#${surface}",
    "mutedForeground": "#$(pal base04)",
    "placeholder": "#$(pal base04)",
    "secondaryLabel": "#$(pal base04)",
    "iconMuted": "#$(pal base04)",
    "error": "#${error}",
    "errorForeground": "#$(pal base12)",
    "errorSurface": "#$(mix_hex "$error" "$canvas" 15)",
    "warning": "#$(pal base0A)",
    "warningForeground": "#$(pal base13)",
    "warningSurface": "#$(mix_hex "$(pal base0A)" "$canvas" 12)",
    "update": "#${accent}",
    "updateForeground": "#$(pal base16)",
    "updateSurface": "#$(mix_hex "$accent" "$canvas" 15)",
    "accentSurface": "#$(mix_hex "$accent" "$canvas" 15)",
    "accentSurfaceForeground": "#$(pal base05)",
    "messageSurface": "#${surface}",
    "messageForeground": "#$(pal base05)",
    "messageAction": "#${accent}",
    "messageActionForeground": "#$(pal base11)",
    "messageActionHover": "#$(pal base16)",
    "codeBackground": "#$(pal base01)",
    "codeForeground": "#$(pal base05)",
    "searchMatchBackground": "#$(mix_hex "$(pal base0A)" "$canvas" 35)",
    "searchMatchForeground": "#$(pal base07)",
    "searchMatchActiveBackground": "#$(pal base0A)",
    "searchMatchActiveForeground": "#$(pal base11)",
    "sidebar": "#$(pal base10)",
    "sidebarForeground": "#$(pal base05)",
    "sidebarMutedForeground": "#$(pal base04)",
    "sidebarControlSurface": "#$(pal base01)",
    "sidebarRowHover": "#$(pal base01)",
    "sidebarRowActive": "#${surface}",
    "sidebarRowSelected": "#$(pal base02)",
    "sidebarBorder": "#$(pal base01)",
    "terminalBackground": "#${canvas}",
    "terminalForeground": "#$(pal base05)",
    "terminalCursor": "#$(pal base05)",
    "terminalSelection": "#${overlay}",
    "terminalScrollbar": "#${overlay}",
    "terminalScrollbarHover": "#$(pal base03)"
  }
}
T3_THEME
}
