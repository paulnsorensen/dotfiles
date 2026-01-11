# Selenized Deutan Warm - Shell Color Palette
# Deuteranopia-safe, circadian-friendly colors
#
# Based on Selenized by Jan Warchoł, transformed for CVD accessibility
# Design principles:
#   - Warm backgrounds (a*=+3, b*=+5) reduce blue light for circadian health
#   - Accent colors spread along b* (blue-yellow) axis for deuteranopia safety
#   - Green → Teal shift moves success colors OFF the red-green confusion axis

# =============================================================================
# PALETTE DEFINITION (CIELAB-derived)
# =============================================================================

# -----------------------------------------------------------------------------
# Background / Foreground
# -----------------------------------------------------------------------------
__SDW_BG="#3E3530"           # L*=23, a*=3, b*=5 - Main background
__SDW_BG_256=237

__SDW_BG_ALT="#4A403B"       # L*=28, a*=3, b*=5 - Highlight bg
__SDW_BG_ALT_256=238

__SDW_BG_HIGHLIGHT="#5D534D" # L*=36, a*=3, b*=5 - Selection/visual
__SDW_BG_HIGHLIGHT_256=240

__SDW_DIM="#908579"          # L*=56, a*=2, b*=8 - Comments
__SDW_DIM_256=102

__SDW_FG="#C4B7A3"           # L*=75, a*=1, b*=12 - Main foreground
__SDW_FG_256=144

__SDW_FG_BRIGHT="#E0D3BE"    # L*=85, a*=1, b*=12 - Emphasized text
__SDW_FG_BRIGHT_256=187

# -----------------------------------------------------------------------------
# Accent Colors (Deuteranopia-safe)
# -----------------------------------------------------------------------------

# Red → Vermillion (errors)
__SDW_RED="#F05A19"          # L*=58, a*=55, b*=62
__SDW_RED_256=202

# Green → Teal (success) - shifted OFF red-green confusion axis
__SDW_GREEN="#3EB8A5"        # L*=68, a*=-38, b*=0
__SDW_GREEN_256=79

# Yellow (types, highlights)
__SDW_YELLOW="#F0B822"       # L*=78, a*=8, b*=75
__SDW_YELLOW_256=214

# Blue (functions)
__SDW_BLUE="#0091EF"         # L*=58, a*=0, b*=-57
__SDW_BLUE_256=33

# Magenta (constants)
__SDW_MAGENTA="#FC94D8"      # L*=74, a*=48, b*=-18
__SDW_MAGENTA_256=212

# Cyan (strings)
__SDW_CYAN="#3ACBF2"         # L*=76, a*=-25, b*=-30
__SDW_CYAN_256=81

# Orange (warnings)
__SDW_ORANGE="#FF8752"       # L*=70, a*=45, b*=50
__SDW_ORANGE_256=209

# Violet (keywords)
__SDW_VIOLET="#B587E3"       # L*=64, a*=35, b*=-40
__SDW_VIOLET_256=141

# -----------------------------------------------------------------------------
# Bright Variants (L* + 5.2)
# -----------------------------------------------------------------------------
__SDW_BR_RED="#FF6928"
__SDW_BR_RED_256=208

__SDW_BR_GREEN="#4FC6B3"
__SDW_BR_GREEN_256=80

__SDW_BR_YELLOW="#FFC734"
__SDW_BR_YELLOW_256=220

__SDW_BR_BLUE="#009FFE"
__SDW_BR_BLUE_256=39

__SDW_BR_MAGENTA="#FFA2E7"
__SDW_BR_MAGENTA_256=218

__SDW_BR_CYAN="#4FD9FF"
__SDW_BR_CYAN_256=87

__SDW_BR_ORANGE="#FF955F"
__SDW_BR_ORANGE_256=215

__SDW_BR_VIOLET="#C495F2"
__SDW_BR_VIOLET_256=177

# =============================================================================
# ANSI 16-COLOR MAPPING
# =============================================================================
# Standard terminal color slots

__SDW_BLACK="$__SDW_BG"
__SDW_BLACK_256=$__SDW_BG_256

__SDW_WHITE="$__SDW_FG"
__SDW_WHITE_256=$__SDW_FG_256

__SDW_BR_BLACK="$__SDW_DIM"
__SDW_BR_BLACK_256=$__SDW_DIM_256

__SDW_BR_WHITE="$__SDW_FG_BRIGHT"
__SDW_BR_WHITE_256=$__SDW_FG_BRIGHT_256

# =============================================================================
# SEMANTIC ALIASES
# =============================================================================
__SDW_ERROR="$__SDW_RED"
__SDW_SUCCESS="$__SDW_GREEN"
__SDW_WARNING="$__SDW_ORANGE"
__SDW_INFO="$__SDW_CYAN"

__SDW_COMMENT="$__SDW_DIM"
__SDW_STRING="$__SDW_CYAN"
__SDW_KEYWORD="$__SDW_VIOLET"
__SDW_FUNCTION="$__SDW_BLUE"
__SDW_TYPE="$__SDW_YELLOW"
__SDW_CONSTANT="$__SDW_MAGENTA"

# =============================================================================
# FZF COLOR STRING
# =============================================================================
__SDW_FZF_COLORS="--color=bg:${__SDW_BG},bg+:${__SDW_BG_ALT}"
__SDW_FZF_COLORS+=" --color=fg:${__SDW_FG},fg+:${__SDW_FG_BRIGHT}"
__SDW_FZF_COLORS+=" --color=hl:${__SDW_CYAN},hl+:${__SDW_BR_CYAN}"
__SDW_FZF_COLORS+=" --color=info:${__SDW_DIM},marker:${__SDW_GREEN}"
__SDW_FZF_COLORS+=" --color=pointer:${__SDW_RED},prompt:${__SDW_BLUE}"
__SDW_FZF_COLORS+=" --color=spinner:${__SDW_MAGENTA},header:${__SDW_VIOLET}"

# =============================================================================
# LS_COLORS
# =============================================================================
export LS_COLORS='di=34:ln=36:so=35:pi=33:ex=32:bd=33;40:cd=33;40:su=31;40:sg=31;40:tw=34;40:ow=34;40:*.tar=31:*.tgz=31:*.zip=31:*.gz=31:*.bz2=31:*.7z=31:*.rar=31:*.jpg=35:*.jpeg=35:*.png=35:*.gif=35:*.svg=35:*.mp3=35:*.mp4=35:*.avi=35:*.mov=35:*.pdf=33:*.doc=33:*.docx=33:*.xls=33:*.xlsx=33:*.ppt=33:*.pptx=33:*.md=36:*.txt=37:*.json=33:*.xml=33:*.yaml=33:*.yml=33:*.toml=33:*.ini=33:*.conf=33:*.sh=32:*.bash=32:*.zsh=32:*.py=32:*.rb=32:*.js=32:*.ts=32:*.go=32:*.rs=32:*.c=32:*.cpp=32:*.h=32:*.hpp=32:*.java=32:*.vim=32:*.lua=32'

# BSD/macOS ls colors
export LSCOLORS='ExGxFxdxCxDxDxhbadacec'

# =============================================================================
# EXPORTS
# =============================================================================
export __SDW_BG __SDW_BG_ALT __SDW_FG __SDW_FG_BRIGHT __SDW_DIM
export __SDW_RED __SDW_GREEN __SDW_YELLOW __SDW_BLUE __SDW_MAGENTA __SDW_CYAN __SDW_ORANGE __SDW_VIOLET
export __SDW_BR_RED __SDW_BR_GREEN __SDW_BR_YELLOW __SDW_BR_BLUE __SDW_BR_MAGENTA __SDW_BR_CYAN __SDW_BR_ORANGE __SDW_BR_VIOLET
export __SDW_FZF_COLORS

# =============================================================================
# BACKWARD COMPATIBILITY (alias old __DW_* names)
# =============================================================================
__DW_BG="$__SDW_BG"
__DW_BG_256=$__SDW_BG_256
__DW_BG_ALT="$__SDW_BG_ALT"
__DW_BG_ALT_256=$__SDW_BG_ALT_256
__DW_FG="$__SDW_FG"
__DW_FG_256=$__SDW_FG_256
__DW_DIM="$__SDW_DIM"
__DW_DIM_256=$__SDW_DIM_256
__DW_BLUE="$__SDW_BLUE"
__DW_BLUE_256=$__SDW_BLUE_256
__DW_FZF_COLORS="$__SDW_FZF_COLORS"
