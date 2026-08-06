# cc launch-time environment — bin/cc-env-exec

`bin/cc-env-exec` gives every new Claude/tmux launch the current non-secret
machine settings while actively removing retired credential variables and the
obsolete user credential cache.

## Why a launch-time wrapper exists

A `tmux new-session` command runs with the tmux server's environment, not the
launching client's. A long-lived server can therefore retain stale settings or
credential variables after the source shell changes.

`_cc_base` (`zsh/claude.zsh`) prepends `cc-env-exec` to the Claude command on
all launch paths. The wrapper parses only the explicit non-secret allowlist from
`.env`, clears every retired secret name, removes
`$XDG_CACHE_HOME/dotfiles/secrets.env`, and then replaces itself with the target
via `exec`.

The parser treats `.env` values as data and never sources the file. Unknown
keys, including old credential assignments, are not exported.

## Why secrets are not passed through tmux

The previous design considered both inherited environment values and
`tmux new-session -e K=V`. Both leave reusable credentials reachable by the
daily user; command-line arguments also make values visible through process
inspection. Managed MCP credentials now stay behind the per-consumer broker
described in [[mcp-secret-handling]].

`cc-env-exec claude -p '...'` remains the sanctioned headless or cron launcher.
Non-interactive contexts do not need to source `zsh/core.zsh`.

## Known limit

`tmux new-session -A` attaching to an existing session keeps that session's
existing process tree. Newly started commands pass through the wrapper and are
sanitized, but already-running descendants must be restarted.

## Gotcha: sensitive-file guard vs "`.env`" in text

The Claude sensitive-file Bash guard substring-matches `.env` in command text,
so a commit message or PR title that merely names the file may be blocked.
Route such text through a file instead: `git commit -F <file>` and
`gh pr create --body-file <file>`.

Tests: `tests/cc-env.bats` and `tests/vault.bats`.
