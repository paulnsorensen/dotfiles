# ssh.zsh — reset terminal input modes after an ssh session
#
# A remote TUI (tmux, vim, an agent CLI) turns on mouse tracking and focus
# reporting. When the connection drops, the TUI cannot turn them off. The
# local shell then prints every mouse move as `^[[<35;x;yM` text.
# This wrapper turns off X10/normal (1000), button-event (1002), any-event
# (1003), and SGR (1006) mouse tracking, plus focus reporting (1004).
# It writes only to a terminal stdout, so captured output stays clean.

ssh() {
  command ssh "$@"
  local rc=$?
  [[ -t 1 ]] && printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1004l'
  return $rc
}
