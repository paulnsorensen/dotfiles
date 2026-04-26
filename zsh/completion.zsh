##
# Stolen from https://github.com/natebosch/dotfiles/blob/master/zshrc.d/completion.zsh
# because he is my friend
##

setopt COMPLETE_IN_WORD     # Allow tab completion in the middle of a word
setopt CORRECT              # Spell check commands
setopt ALWAYS_TO_END        # Push cursor on completions.

# Use modern completion system
autoload -Uz compinit

compinit

# cache completions
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ${XDG_CACHE_HOME:-$HOME/.cache}/zsh/compcache

# ignore completion functions for missing commands
zstyle ':completion:*:functions' ignored-patterns '_*'

zstyle ':completion:*' verbose true
zstyle ':completion:*' auto-description 'specify: %d'
zstyle ':completion:*:descriptions' format '%B%d%b'
zstyle ':completion:*:messages' format '%d'
zstyle ':completion:*:warnings' format 'No matches for: %d'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' completer _oldlist _expand _complete _correct _approximate
# Have the newer files last so I see them first
zstyle ':completion:*' file-sort modification reverse

zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}

zstyle ':completion::complete:git-checkout:*' matcher 'm:{a-z-_}={A-Z_-}' 'r:|=*' 'l:|=* r:|=*'

zstyle ':completion:*' menu select=2
zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
zstyle ':completion:*' matcher-list \
  '' \
  'm:{a-z}={A-Z}' \
  'm:{a-zA-Z}={A-Za-z}' \
  'r:|[._-]=* r:|=* l:|=*'
zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
zstyle ':completion:*' use-compctl false

zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

# cdd completion - shows directories in DEV_DIR
_cdd() {
  local dev_dir="${DEV_DIR:-$HOME/Dev}"

  # Only complete if base directory exists
  [[ -d "$dev_dir" ]] || return 1

  # Get list of directories
  local -a dev_dirs
  if [[ -n "$ZSH_VERSION" ]]; then
    # Use zsh glob with null_glob option for safety
    setopt local_options null_glob
    dev_dirs=( ${dev_dir}/*(N-/:t) )
  else
    # Fallback for other shells (though this function is zsh-specific)
    dev_dirs=()
    for dir in "$dev_dir"/*; do
      [[ -d "$dir" ]] && dev_dirs+=("$(basename "$dir")")
    done
  fi

  # Provide completions
  _describe 'development directories' dev_dirs
}

# Register the completion function
compdef _cdd cdd

# vaudeville completion — subcommands, options, and dynamic rule names
# Rules live in ~/.vaudeville/rules/*.yaml; tune takes a rule name positionally.
_vaudeville() {
  local -a subcmds
  subcmds=(
    'watch:Live TUI of rule firings'
    'setup:Download model and verify inference'
    'stats:Show classification statistics'
    'tune:Tune a rule to meet precision/recall/f1 thresholds'
    'generate:Generate a new rule from instructions'
  )

  _arguments -C \
    '(-h --help)'{-h,--help}'[show help]' \
    '1: :->subcmd' \
    '*:: :->args' && return 0

  case $state in
    subcmd)
      _describe -t commands 'vaudeville subcommand' subcmds
      ;;
    args)
      case $words[1] in
        watch|stats)
          _arguments \
            '--log-path[path to events.jsonl]:log path:_files' \
            $([[ $words[1] == stats ]] && echo '--json[output raw JSON]')
          ;;
        tune)
          local -a rules
          local f
          for f in ~/.vaudeville/rules/*.yaml(N); do
            rules+=( ${f:t:r} )
          done
          _arguments \
            '--p-min[minimum precision threshold]:precision:' \
            '--r-min[minimum recall threshold]:recall:' \
            '--f1-min[minimum F1 threshold]:f1:' \
            '--rounds[maximum orchestration rounds]:rounds:' \
            '--tuner-iters[ralph iterations for tune phase]:iters:' \
            "1:rule name:($rules)"
          ;;
        generate)
          _arguments \
            '--p-min[minimum precision threshold]:precision:' \
            '--r-min[minimum recall threshold]:recall:' \
            '--f1-min[minimum F1 threshold]:f1:' \
            '--live[run generation in live mode instead of shadow]' \
            '--rounds[maximum orchestration rounds]:rounds:' \
            '--tuner-iters[ralph iterations for tune phase]:iters:' \
            '1:instructions:'
          ;;
        setup)
          _message 'no arguments'
          ;;
      esac
      ;;
  esac
}
compdef _vaudeville vaudeville vdv
