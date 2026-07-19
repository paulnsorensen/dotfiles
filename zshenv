# .zshenv — sourced for EVERY zsh invocation, including non-interactive ones
# (`ssh host <cmd>` and mosh's `mosh-server` bootstrap). Keep this minimal:
# interactive setup lives in .zshrc → zsh/*.zsh. Only what the non-interactive
# remote path needs belongs here.

# UTF-8 locale — mosh refuses to start without a UTF-8 native locale, and it
# forwards LANG/LC_* to mosh-server over SSH. Respect an already-set locale.
export LANG="${LANG:-en_US.UTF-8}"

# mosh-server idle-network self-exit. 2026-07-08 livelock: the iPhone moshi
# app reconnect-looped ~723 logins in 2h, each spawning a mosh-server that
# outlives its client for hours once abandoned. tmux holds the real session
# state, so an orphaned mosh-server is pure waste — safe to self-exit after
# 4h with no client contact (man mosh-server, MOSH_SERVER_NETWORK_TMOUT).
export MOSH_SERVER_NETWORK_TMOUT=14400

typeset -gU path fpath  # dedupe PATH/FPATH (first occurrence wins)

# Homebrew bin on PATH for non-interactive SSH/mosh sessions. On Apple Silicon
# /opt/homebrew/bin is NOT in macOS path_helper's default PATH, so an inbound
# `mosh thismac` can't find mosh-server without this. Interactive shells get it
# via zsh/core.zsh; this covers the non-interactive bootstrap. Idempotent
# guard so nested zsh invocations (or .zshrc re-prepending) don't grow PATH.
if [[ "$OSTYPE" == darwin* && -d /opt/homebrew/bin && ":$PATH:" != *":/opt/homebrew/bin:"* ]]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi

# rustup proxy dir + cargo bin on PATH for non-interactive shells (e.g. agent
# Bash tools). cargo/config.toml sets rustc-wrapper=sccache unconditionally;
# without rustc on PATH here, sccache fails with "cannot find binary path".
# Interactive shells get these via zsh/core.zsh; mirrored here for the
# non-interactive bootstrap.
if [[ "$OSTYPE" == darwin* && -d /opt/homebrew/opt/rustup/bin && ":$PATH:" != *":/opt/homebrew/opt/rustup/bin:"* ]]; then
  export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi
if [[ -d "$HOME/.cargo/bin" && ":$PATH:" != *":$HOME/.cargo/bin:"* ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

# .NET SDK + global tools (e.g. godotenv) for non-interactive shells. Interactive
# shells get these via zsh/core.zsh; mirrored here for the non-interactive path.
if [[ -d "$HOME/.dotnet" ]]; then
  export DOTNET_ROOT="$HOME/.dotnet"
  [[ ":$PATH:" != *":$DOTNET_ROOT:"* ]] && export PATH="$DOTNET_ROOT:$DOTNET_ROOT/tools:$PATH"
fi
