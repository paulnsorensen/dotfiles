# Based off of https://web.archive.org/web/20160817112745/http://dougblack.io:80/words/zsh-vi-mode.html
# and https://github.com/davidjrice/prezto_powerline
#
# Colors sourced from zsh/colors.zsh (Deuterawarm palette)

# Powerline segment colors (using ANSI 256 codes from colors.zsh)
POWERLINE_LEFT_A_BG=$__SDW_BG_ALT_256       # Slightly lighter background
POWERLINE_LEFT_A_FG=$__SDW_FG_256           # Foreground text
POWERLINE_LEFT_B_BG=$__SDW_BLUE_256         # Blue for git branch segment
POWERLINE_LEFT_B_FG=$__SDW_BG_256           # Dark text on blue
POWERLINE_LEFT_C_BG=$__SDW_BG_256           # Background for time segment
POWERLINE_LEFT_C_FG=$__SDW_DIM_256          # Dimmed text for time
POWERLINE_LEFT_D_FG=$__SDW_BLUE_256         # Blue for date/time text

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
_git_cache_time=""
_git_cache_last_commit=""

# Async prompt state. All git work runs in a background job so the prompt never
# blocks on git forks; the worker signals SIGUSR1 and we repaint from these
# vars. They hold the last computed values (stale by at most one prompt).
_prompt_git_info=""
_prompt_git_time=""
_prompt_async_pid=0
_prompt_async_tmp="${TMPDIR:-/tmp}/zsh-prompt-git.$$"

_prompt_cleanup() { rm -f "$_prompt_async_tmp" "$_prompt_async_tmp".*(N) 2>/dev/null; }
add-zsh-hook zshexit _prompt_cleanup

# Refresh prompt periodically (PERIOD avoids repurposing TMOUT idle timer)
PERIOD=30
periodic() {
  prompt_precmd
  zle && zle reset-prompt
}

# Ensure that the prompt is redrawn when the terminal size changes.
TRAPWINCH() {
  zle && zle -R
}

function prompt_precmd() {
  # Paint immediately from the last-known git state, then refresh in the
  # background. render_prompt never forks; the worker owns every git call.
  render_prompt
  _prompt_async_start
}

# Recompute git info in a disowned background job. Kill any still-running worker
# first so a slow git call can't stack up behind rapid prompts. The kill -0
# guard avoids signaling a recycled PID if the tracked worker already exited.
_prompt_async_start() {
  [[ $_prompt_async_pid -ne 0 ]] && kill -0 $_prompt_async_pid 2>/dev/null \
    && kill $_prompt_async_pid 2>/dev/null
  _prompt_async_worker &!
  _prompt_async_pid=$!
}

# Compute into a private scratch file, then atomically rename onto the shared
# state file so TRAPUSR1 never reads a half-written file, then signal.
_prompt_async_worker() {
  local scratch="$_prompt_async_tmp.$RANDOM"
  _prompt_git_compute "$scratch"
  mv -f "$scratch" "$_prompt_async_tmp" 2>/dev/null
  kill -USR1 $$ 2>/dev/null
}

# Compute branch + time-since-commit and write them (two lines) to $1 (defaults
# to the state file). Separated from the worker so the signal isn't tangled into
# the git work (and so it's testable without self-signaling).
_prompt_git_compute() {
  local out=${1:-$_prompt_async_tmp}
  vcs_info 'prompt'
  print -r -- "$vcs_info_msg_0_"   >  "$out"
  print -r -- "$(git_time_details)" >> "$out"
}

_prompt_load_git_state() {
  [[ -r $_prompt_async_tmp ]] || return
  local -a state
  state=("${(@f)$(<$_prompt_async_tmp)}")
  _prompt_git_info=${state[1]}
  _prompt_git_time=${state[2]}
}

# The worker signals here once fresh git state is on disk: load it and repaint.
TRAPUSR1() {
  _prompt_async_pid=0
  _prompt_load_git_state
  render_prompt
  zle && zle reset-prompt
}

render_prompt() {
  POWERLINE_LEFT_A="%K{$POWERLINE_LEFT_A_BG}%F{$POWERLINE_LEFT_A_FG} %~ %k%f%F{$POWERLINE_LEFT_A_BG}%K{$POWERLINE_LEFT_B_BG}"$POWERLINE_SEPARATOR
  POWERLINE_LEFT_B="%k%f%F{$POWERLINE_LEFT_B_FG}%K{$POWERLINE_LEFT_B_BG} "${_prompt_git_info}" %k%f%F{$POWERLINE_LEFT_B_BG}%K{$POWERLINE_LEFT_C_BG}"$POWERLINE_SEPARATOR
  POWERLINE_LEFT_C=" %k%f%F{$POWERLINE_LEFT_C_FG}%K{$POWERLINE_LEFT_C_BG}"${_prompt_git_time}" %k%f%F{$POWERLINE_LEFT_C_BG}"$POWERLINE_SEPARATOR
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

  if [[ "$hours" -gt 48 ]]; then
    echo "${days}d"
  elif [[ "$hours" -gt 24 ]]; then
    echo "${days}d${sub_hours}h"
  elif [[ "$minutes" -gt 60 ]]; then
    echo "${hours}h${sub_minutes}m"
  else
    echo "${minutes}m"
  fi
}
