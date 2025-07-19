# Based off of https://web.archive.org/web/20160817112745/http://dougblack.io:80/words/zsh-vi-mode.html
# and https://github.com/davidjrice/prezto_powerline

# COLORS
# Selenized Dark color scheme
# Background colors
__SELENIZED_BG0=23        # #103c48
__SELENIZED_BG1=24        # #184956
__SELENIZED_BG2=66        # #2d5b69
# Foreground colors
__SELENIZED_DIM0=102      # #72898f
__SELENIZED_FG0=146       # #adbcbc
__SELENIZED_FG1=188       # #cad8d9
# Standard colors
__SELENIZED_RED=203       # #fa5750
__SELENIZED_GREEN=107     # #75b938
__SELENIZED_YELLOW=179    # #dbb32d
__SELENIZED_BLUE=75       # #4695f7
__SELENIZED_MAGENTA=207   # #f275be
__SELENIZED_CYAN=79       # #41c7b9
__SELENIZED_ORANGE=209    # #ed8649
__SELENIZED_VIOLET=141    # #af88eb
# Bright colors
__SELENIZED_BR_RED=209    # #ff665c
__SELENIZED_BR_GREEN=113  # #84c747
__SELENIZED_BR_YELLOW=185 # #ebc13d
__SELENIZED_BR_BLUE=81    # #58a3ff
__SELENIZED_BR_MAGENTA=213 # #ff84cd
__SELENIZED_BR_CYAN=86    # #53d6c7
__SELENIZED_BR_ORANGE=215 # #fd9456
__SELENIZED_BR_VIOLET=147 # #bd96fa

POWERLINE_LEFT_A_BG=$__SELENIZED_BG1
POWERLINE_LEFT_A_FG=$__SELENIZED_FG1
POWERLINE_LEFT_B_BG=$__SELENIZED_BLUE
POWERLINE_LEFT_B_FG=$__SELENIZED_BG0
POWERLINE_LEFT_C_BG=$__SELENIZED_BG0
POWERLINE_LEFT_C_FG=$__SELENIZED_FG0
POWERLINE_LEFT_D_FG=$__SELENIZED_BLUE

# powerline theme
POWERLINE_SEPARATOR=$'\uE0B0'
POWERLINE_THIN_SEPARATOR=$'\uE0B1'


# prompt setup
autoload -Uz vcs_info
autoload -Uz add-zsh-hook

add-zsh-hook precmd prompt_precmd

# Enable VCS systems you use.
zstyle ':vcs_info:*' enable git

# check-for-changes can be really slow.
# You should disable it if you work with large repositories.
zstyle ':vcs_info:*:prompt:*' check-for-changes false

# Formats:
# %b - branchname
# %u - unstagedstr (see below)
# %c - stagedstr (see below)
# %a - action (e.g. rebase-i)
# %R - repository path
# %S - path in the repository
# %n - user
# %m - machine hostname

local fmt_branch="%b%u%c"
local fmt_action="%a"

zstyle ':vcs_info:*:prompt:*' actionformats "${fmt_branch}${fmt_action}"
zstyle ':vcs_info:*:prompt:*' formats       "${fmt_branch}"
zstyle ':vcs_info:*:prompt:*' nvcsformats   ""

# Git status caching variables
_git_cache_dir=""
_git_cache_head=""
_git_cache_status=""
_git_cache_time=""
_git_cache_last_commit=""

# Reset the prompt every 10 seconds
TMOUT=10
TRAPALRM() {
  if [[ "$WIDGET" =~ "comp" || "$WIDGET" =~ "fzf" ]]; then
    return 0
  fi
  prompt_precmd
  zle reset-prompt
}

# Ensure that the prompt is redrawn when the terminal size changes.
TRAPWINCH() {
  zle && zle -R
}

# Change cursor shape for different vi modes.
function zle-line-init zle-keymap-select {
  if [[ $KEYMAP == vicmd ]]; then
    echo -ne '\e[2 q' # Solid Block
  elif [[ $KEYMAP == main ]] \
    || [[ $KEYMAP == viins ]] \
    || [[ $KEYMAP = '' ]]; then
    echo -ne '\e[1 q' # Blink Block
  fi

  zle reset-prompt
  zle -R
}

function prompt_precmd() {
  fmt_branch="%b%u%c"
  zstyle ':vcs_info:*:prompt:*' formats "${fmt_branch}"

  vcs_info 'prompt'

  render_prompt
}

render_prompt() {
  POWERLINE_LEFT_A="%K{$POWERLINE_LEFT_A_BG}%F{$POWERLINE_LEFT_A_FG} %~ %k%f%F{$POWERLINE_LEFT_A_BG}%K{$POWERLINE_LEFT_B_BG}"$POWERLINE_SEPARATOR
  POWERLINE_LEFT_B="%k%f%F{$POWERLINE_LEFT_B_FG}%K{$POWERLINE_LEFT_B_BG} "${vcs_info_msg_0_}" %k%f%F{$POWERLINE_LEFT_B_BG}%K{$POWERLINE_LEFT_C_BG}"$POWERLINE_SEPARATOR
  POWERLINE_LEFT_C=" %k%f%F{$POWERLINE_LEFT_C_FG}%K{$POWERLINE_LEFT_C_BG}"$(git_time_details)" %k%f%F{$POWERLINE_LEFT_C_BG}"$POWERLINE_SEPARATOR
  POWERLINE_LEFT_D="%k%f%F{$POWERLINE_LEFT_D_FG} %D %T %k%f%F{$POWERLINE_LEFT_D_FG}$POWERLINE_THIN_SEPARATOR%f "

  PROMPT=$POWERLINE_LEFT_A$POWERLINE_LEFT_B$POWERLINE_LEFT_C$POWERLINE_LEFT_D
  RPROMPT=""
}

update_git_cache() {
  local current_dir="$PWD"
  local git_dir=""
  
  # Check if we're in a git repository
  if git_dir=$(git rev-parse --git-dir 2>/dev/null); then
    local git_head_file="${git_dir}/HEAD"
    local current_head=""
    
    # Get current HEAD reference
    if [[ -f "$git_head_file" ]]; then
      current_head=$(cat "$git_head_file")
    fi
    
    # Check if cache is valid (same directory and HEAD hasn't changed)
    if [[ "$current_dir" == "$_git_cache_dir" && "$current_head" == "$_git_cache_head" ]]; then
      return 0
    fi
    
    # Update cache
    _git_cache_dir="$current_dir"
    _git_cache_head="$current_head"
    
    # Get last commit time if repository has commits
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
      _git_cache_last_commit=$(git log -1 --pretty=format:'%at' 2>/dev/null)
    else
      _git_cache_last_commit=""
    fi
    
    # Calculate time since last commit
    if [[ -n "$_git_cache_last_commit" ]]; then
      local now=$(date +%s)
      local seconds_since=$((now - _git_cache_last_commit))
      _git_cache_time=$(time_since_commit $seconds_since)
    else
      _git_cache_time=""
    fi
  else
    # Not in a git repository
    _git_cache_dir=""
    _git_cache_head=""
    _git_cache_time=""
    _git_cache_last_commit=""
  fi
}

git_time_details() {
  # Update cache and return the time
  update_git_cache
  echo "$_git_cache_time"
}

time_since_commit() {
  seconds_since_last_commit=$(($1 + 0))

  # totals
  minutes=$((seconds_since_last_commit / 60))
  hours=$((seconds_since_last_commit/3600))

  # sub-hours and sub-minutes
  days=$((seconds_since_last_commit / 86400))
  sub_hours=$((hours % 24))
  sub_minutes=$((minutes % 60))

  if [ "$hours" -gt 48 ]; then
    echo "${days}d"
  elif [ "$hours" -gt 24 ]; then
    echo "${days}d${sub_hours}h"
  elif [ "$minutes" -gt 60 ]; then
    echo "${hours}h${sub_minutes}m"
  else
    echo "${minutes}m"
  fi
}

zle -N zle-line-init
zle -N zle-keymap-select
