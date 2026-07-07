# .zshenv — sourced for EVERY zsh invocation, including non-interactive ones
# (`ssh host <cmd>` and mosh's `mosh-server` bootstrap). Keep this minimal:
# interactive setup lives in .zshrc → zsh/*.zsh. Only what the non-interactive
# remote path needs belongs here.

# UTF-8 locale — mosh refuses to start without a UTF-8 native locale, and it
# forwards LANG/LC_* to mosh-server over SSH. Respect an already-set locale.
export LANG="${LANG:-en_US.UTF-8}"

typeset -gU path fpath  # dedupe PATH/FPATH (first occurrence wins)

# Homebrew bin on PATH for non-interactive SSH/mosh sessions. On Apple Silicon
# /opt/homebrew/bin is NOT in macOS path_helper's default PATH, so an inbound
# `mosh thismac` can't find mosh-server without this. Interactive shells get it
# via zsh/core.zsh; this covers the non-interactive bootstrap. Idempotent
# guard so nested zsh invocations (or .zshrc re-prepending) don't grow PATH.
if [[ "$OSTYPE" == darwin* && -d /opt/homebrew/bin && ":$PATH:" != *":/opt/homebrew/bin:"* ]]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi
