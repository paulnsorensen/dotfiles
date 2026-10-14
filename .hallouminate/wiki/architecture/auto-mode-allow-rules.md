# Auto Mode Allow Rules

Claude auto mode drops broad allow rules that can run arbitrary code. Narrow subcommand rules stay in effect and skip the classifier call. Codex keeps its broad prefix rules, so it does not need the narrow set.

_Source: session-analytics mining, 2026-10-14 · Docs: code.claude.com/docs/en/permission-modes ("How the classifier evaluates actions") and code.claude.com/docs/en/permissions._

## Why narrow rules exist next to broad ones

- The docs say that auto mode drops blanket `Bash(*)`, wildcard interpreters such as `Bash(python*)`, package-manager run commands, and `Agent` rules.
- Session logs show that the classifier reviewed `gh stack --help`, `gh pr merge`, `git rebase`, `node tests/...`, and `just check | grep`. The broad `gh:*`, `git:*`, `node:*`, and `just:*` rules match each of these commands. Thus auto mode does not apply those broad rules.
- Each classifier review is one inference call. `chezmoi/.chezmoidata/claude.yaml` therefore adds narrow rules for frequent routine calls: `gh pr|issue|run|repo` reads and edits, `gh stack` (not `merge`), `git add|commit|fetch|switch|worktree add`, `just <recipe>`, `node --test`, and `uv run pytest|ruff|basedpyright|mypy`.
- Merge, push, `gh api`, and inline interpreters stay with the classifier on purpose.
- Read-only builtins (`ls`, `cat`, `grep`, `head`, `git diff`, `git status`, `git log`) never reach the classifier. They need no rules.

## Why `rm -rf` is not denied

- A deny rule matches each part of a compound command. Thus `Bash(rm -rf:*)` blocked every `rm -rf /tmp/x && mkdir ... && git init ...` scratch setup. That was 207 denials in 45 days, which is almost all of the prompt denials.
- Precedence is deny, then ask, then allow. An `ask` for `rm -rf:*` would also override a narrower allow. So the coarse rule is gone, not moved to `ask`.
- Claude: `Bash(rm -rf /tmp/*)` is allowed. The `ask` rules catch `..` traversal and the `/`, `/home/*`, `/Users/*`, and `~*` targets. The classifier reviews all other targets. It runs `git status` before `rm -rf`, and the built-in critical-path protection still applies.
- Codex: the canonical floor in `profiles/_permissions/profile.yaml` no longer renders `rm -rf` as `forbidden`. The `workspace-write` sandbox confines writes, and the guardian reviewer reviews escalations.
- `Bash(sudo:*)` stays denied in every harness.

## Gotchas

- `chezmoi/.chezmoidata/claude.yaml` expands `${HOME}` at render time. A rule cannot match a literal `$HOME` in a command.
- A Codex `prefix_rule` matches the argv prefix only. A path glob such as `/tmp/*` is not possible, and `bash_argv` drops rules without `:*`.
- Codex escalations with a leading env assignment (`UV_CACHE_DIR=... uv ...`) do not match any prefix rule.
- `agent-profile/tests/test_canonical_permissions.py` pins `DOTFILES_DIR` to the checkout under test. The `global` include otherwise resolves `_permissions` from `~/Dev/dotfiles`.

See also [[architecture/harness-permissions]] · [[architecture/cross-harness-guards]]
