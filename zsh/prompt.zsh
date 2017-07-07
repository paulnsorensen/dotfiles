# Based off of https://web.archive.org/web/20160817112745/http://dougblack.io:80/words/zsh-vi-mode.html
# and https://github.com/davidjrice/prezto_powerline

# COLORS
# From https://github.com/altercation/solarized
__SOLARIZED_BASE03=234
__SOLARIZED_BASE02=235
__SOLARIZED_BASE01=240
__SOLARIZED_BASE00=241
__SOLARIZED_BASE0=244
__SOLARIZED_BASE1=245
__SOLARIZED_BASE2=254
__SOLARIZED_BASE3=230
__SOLARIZED_YELLOW=136
__SOLARIZED_ORANGE=166
__SOLARIZED_RED=160
__SOLARIZED_MAGENTA=125
__SOLARIZED_VIOLET=61
__SOLARIZED_BLUE=33
__SOLARIZED_CYAN=37
__SOLARIZED_GREEN=64

POWERLINE_LEFT_A_BG=$__SOLARIZED_BASE01
POWERLINE_LEFT_A_FG=$__SOLARIZED_BASE2
POWERLINE_LEFT_B_BG=$__SOLARIZED_BLUE
POWERLINE_LEFT_B_FG=$__SOLARIZED_BASE2
POWERLINE_LEFT_C_BG=$__SOLARIZED_BASE02
POWERLINE_LEFT_C_FG=$__SOLARIZED_BASE1

POWERLINE_RIGHT_BG=$__SOLARIZED_BASE03
POWERLINE_RIGHT_FG=$__SOLARIZED_BASE0

# powerline theme
POWERLINE_SEPARATOR=$'\uE0B0'
POWERLINE_R_SEPARATOR=$'\uE0B2'


# prompt setup
autoload -Uz vcs_info
autoload -Uz add-zsh-hook

add-zsh-hook precmd prompt_precmd


# Enable VCS systems you use.
zstyle ':vcs_info:*' enable git

# check-for-changes can be really slow.
# You should disable it if you work with large repositories.
zstyle ':vcs_info:*:prompt:*' check-for-changes true

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
local fmt_unstaged="%F{$__SOLARIZED_MAGENTA}●%f"
local fmt_staged="%F{$__SOLARIZED_YELLOW}●%f"

zstyle ':vcs_info:*:prompt:*' unstagedstr   "${fmt_unstaged}"
zstyle ':vcs_info:*:prompt:*' stagedstr     "${fmt_staged}"
zstyle ':vcs_info:*:prompt:*' actionformats "${fmt_branch}${fmt_action}"
zstyle ':vcs_info:*:prompt:*' formats       "${fmt_branch}"
zstyle ':vcs_info:*:prompt:*' nvcsformats   ""


# Ensure that the prompt is redrawn when the terminal size changes.
TRAPWINCH() {
  zle &&  zle -R
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
  render_prompt

  zle reset-prompt
  zle -R
}

function prompt_precmd() {
  # Check for untracked files or updated submodules since vcs_info doesn't.
  if [[ ! -z $(git ls-files --other --exclude-standard 2> /dev/null) ]]; then
    fmt_branch="%b%u%c%F{$__SOLARIZED_ORANGE}●%f"
  else
    fmt_branch="%b%u%c"
  fi
  zstyle ':vcs_info:*:prompt:*' formats "${fmt_branch}"

  vcs_info 'prompt'

  render_prompt
}

render_prompt() {
  POWERLINE_LEFT_A="%K{$POWERLINE_LEFT_A_BG}%F{$POWERLINE_LEFT_A_FG} %~ %k%f%F{$POWERLINE_LEFT_A_BG}%K{$POWERLINE_LEFT_B_BG}"$POWERLINE_SEPARATOR
  POWERLINE_LEFT_B="%k%f%F{$POWERLINE_LEFT_B_FG}%K{$POWERLINE_LEFT_B_BG} "${vcs_info_msg_0_}" %k%f%F{$POWERLINE_LEFT_B_BG}%K{$POWERLINE_LEFT_C_BG}"$POWERLINE_SEPARATOR
  POWERLINE_LEFT_C=" %k%f%F{$POWERLINE_LEFT_C_FG}%K{$POWERLINE_LEFT_C_BG}"$(git_time_details)" %k%f%F{$POWERLINE_LEFT_C_BG}"$POWERLINE_SEPARATOR"%f "

  PROMPT=$POWERLINE_LEFT_A$POWERLINE_LEFT_B$POWERLINE_LEFT_C
  RPROMPT="%F{$POWERLINE_RIGHT_BG}$POWERLINE_R_SEPARATOR%f%K{$POWERLINE_RIGHT_BG}%F{$POWERLINE_RIGHT_FG} $(vi_mode_prompt_info) %f%k"
}

vi_mode_prompt_info() {
  if [[ $KEYMAP == vicmd ]]; then
    echo "NORMAL"
  else
    echo "INSERT"
  fi
}

git_time_details() {
  # only proceed if there is actually a git repository
  if $(git rev-parse --git-dir > /dev/null 2>&1); then
    # only proceed if there is actually a commit
    if [[ $(git log 2>&1 > /dev/null | grep -c "^fatal: bad default revision") == 0 ]]; then
      # get the last commit hash
      # lc_hash=$(git log --pretty=format:'%h' -1 2> /dev/null)
      # get the last commit time
      lc_time=$(git log --pretty=format:'%at' -1 2> /dev/null)

      now=$(date +%s)
      seconds_since_last_commit=$((now-lc_time))
      lc_time_since=$(time_since_commit $seconds_since_last_commit)

      echo "$lc_time_since"
    else
      echo ""
    fi
  else
    echo ""
  fi
}

# returns the time by given seconds
time_since_commit() {
  seconds_since_last_commit=$(($1 + 0))

  # totals
  MINUTES=$((seconds_since_last_commit / 60))
  HOURS=$((seconds_since_last_commit/3600))

  # sub-hours and sub-minutes
  DAYS=$((seconds_since_last_commit / 86400))
  SUB_HOURS=$((HOURS % 24))
  SUB_MINUTES=$((MINUTES % 60))

  if [ "$HOURS" -gt 24 ]; then
    echo "${DAYS}d${SUB_HOURS}h${SUB_MINUTES}m"
  elif [ "$MINUTES" -gt 60 ]; then
    echo "${HOURS}h${SUB_MINUTES}m"
  else
    echo "${MINUTES}m"
  fi
}

zle -N zle-line-init
zle -N zle-keymap-select
