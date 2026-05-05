# yabai + skhd - window manager helpers
if command -v yabai &>/dev/null && command -v skhd &>/dev/null; then
    alias yr='yabai --restart-service && skhd --restart-service'
fi
