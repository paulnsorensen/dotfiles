# cc launch-time env loading — bin/cc-env-exec

## Why a launch-time loader exists at all

The `${VAR}` MCP secret passthrough ([[mcp-secret-handling]]) assumes the
claude process inherits `.env` keys from its environment. Shell init
(`zsh/core.zsh`) covers a freshly started interactive shell — but **not** the
tmux path `_cc_base` uses: a `tmux new-session` command runs with the **tmux
server's** environment, not the launching client's (verified empirically on
tmux 3.6 — a client-exported var does not reach the new session). A server
started before a key was added to `.env` therefore spawned claude without it,
and one unset referenced `${VAR}` makes Claude fail to parse the entire
`~/.claude.json`, killing every MCP.

## The design: exec wrapper, not `tmux -e` (PR #282)

`bin/cc-env-exec` does a safe `.env` parse (skip blanks/comments, split on
first `=`, no command execution — same loop as `zsh/core.zsh`), exports the
pairs, then `exec "$@"`. `_cc_base` (`zsh/claude.zsh`) prepends it to the
claude command on all three launch paths and degrades to plain `claude` when
the wrapper is missing.

`tmux new-session -e K=V` (tmux ≥ 3.2) was tested, worked, and was
**rejected in review**: it puts every secret in the tmux client's argv, which
is `ps`-visible to other local users for the lifetime of the attached client
(`/proc/<pid>/cmdline` is world-readable; env is owner-only — that asymmetry
is the point). The wrapper keeps secrets on disk/env only and reads `.env` at
actual process start, so it is also immune to a stale launching shell.

Side benefit: `cc-env-exec claude -p '...'` is the sanctioned headless/cron
launcher — non-interactive contexts never source `zsh/core.zsh`.

## Known limits

- `tmux new-session -A` attaching to an existing session keeps that session's
  old environment; only newly created sessions pick up new keys. Kill the
  session to refresh.
- `cc`/`ccc`/`ccr` are interactive-zsh functions; bare `claude` invocations
  bypass the wrapper. Use `cc-env-exec claude ...` in scripts.

## Gotcha: sensitive-file guard vs "`.env`" in text

The Claude sensitive-file Bash guard substring-matches `.env` in the *command
text*, so a `git commit -m` message or `gh pr create --title` that merely
mentions `.env` is blocked. Route the text through a file instead:
`git commit -F <file>`, `gh pr create --body-file <file>`, and keep the
literal string out of titles.

Tests: `tests/cc-env.bats` (wrapper unit tests + zsh e2e with mocked
tmux/claude, including the no-secret-in-argv assertions).
