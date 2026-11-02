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
  local error_surface warning_surface accent_surface search_match
  local fg muted strong dark sidebar lift select seed
  canvas="$(pal base00)"
  fg="$(pal base05)"
  muted="$(pal base04)"
  strong="$(pal base07)"
  dark="$(pal base11)"
  sidebar="$(pal base10)"
  lift="$(pal base01)"
  select="$(pal base02)"
  # Share the Zed panel shades: base00-base02 are too close to separate surfaces.
  surface=$(yq -r '.zed.panel_background // .palette.base01' "$SCHEME_FILE")
  overlay=$(yq -r '.zed.elevated_background // .palette.base01' "$SCHEME_FILE")
  accent=$(yq -r '.zed.ui_accent // .palette.base0D' "$SCHEME_FILE")
  error=$(yq -r '.t3.error // .palette.base08' "$SCHEME_FILE")
  # T3 skips the whole theme when a seed is not hex, so fail here instead.
  for seed in "$canvas" "$surface" "$overlay" "$accent" "$error"; do
    if [[ ! "$seed" =~ ^[0-9a-fA-F]{6}$ ]]; then
      log_err "T3 theme: '$seed' in $SCHEME_FILE is not a 6-digit hex color without '#'"
      return 1
    fi
  done
  # Compute blends before the heredoc: errexit ignores failures inside it.
  border=$(mix_hex "$fg" "$canvas" 14)
  input=$(mix_hex "$fg" "$canvas" 20)
  error_surface=$(mix_hex "$error" "$canvas" 15)
  warning_surface=$(mix_hex "$(pal base0A)" "$canvas" 12)
  accent_surface=$(mix_hex "$accent" "$canvas" 15)
  search_match=$(mix_hex "$(pal base0A)" "$canvas" 35)

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
    "toolbarForeground": "#${fg}",
    "toolbarBorder": "#${select}",
    "toolbarControl": "#${lift}",
    "toolbarControlForeground": "#${fg}",
    "toolbarControlHover": "#${select}",
    "surface": "#${surface}",
    "surfaceRaised": "#${surface}",
    "surfaceOverlay": "#${overlay}",
    "text": "#${fg}",
    "textMuted": "#${muted}",
    "border": "#${border}",
    "input": "#${input}",
    "focus": "#${accent}",
    "accent": "#${accent}",
    "accentForeground": "#${dark}",
    "secondary": "#${surface}",
    "secondaryForeground": "#${fg}",
    "muted": "#${surface}",
    "mutedForeground": "#${muted}",
    "placeholder": "#${muted}",
    "secondaryLabel": "#${muted}",
    "iconMuted": "#${muted}",
    "error": "#${error}",
    "errorForeground": "#$(pal base12)",
    "errorSurface": "#${error_surface}",
    "warning": "#$(pal base0A)",
    "warningForeground": "#$(pal base13)",
    "warningSurface": "#${warning_surface}",
    "update": "#${accent}",
    "updateForeground": "#$(pal base16)",
    "updateSurface": "#${accent_surface}",
    "accentSurface": "#${accent_surface}",
    "accentSurfaceForeground": "#${fg}",
    "messageSurface": "#${surface}",
    "messageForeground": "#${fg}",
    "messageAction": "#${accent}",
    "messageActionForeground": "#${dark}",
    "messageActionHover": "#$(pal base16)",
    "codeBackground": "#${lift}",
    "codeForeground": "#${fg}",
    "searchMatchBackground": "#${search_match}",
    "searchMatchForeground": "#${strong}",
    "searchMatchActiveBackground": "#$(pal base0A)",
    "searchMatchActiveForeground": "#${dark}",
    "sidebar": "#${sidebar}",
    "sidebarForeground": "#${fg}",
    "sidebarMutedForeground": "#${muted}",
    "sidebarControlSurface": "#${lift}",
    "sidebarRowHover": "#${lift}",
    "sidebarRowActive": "#${surface}",
    "sidebarRowSelected": "#${select}",
    "sidebarBorder": "#${lift}",
    "terminalBackground": "#${canvas}",
    "terminalForeground": "#${fg}",
    "terminalCursor": "#${fg}",
    "terminalSelection": "#${overlay}",
    "terminalScrollbar": "#${overlay}",
    "terminalScrollbarHover": "#$(pal base03)"
  }
}
T3_THEME
}
