# ast-grep: pins, the sg alias, and the eval sandbox binary

ast-grep has one version in two places, and the `bash-shortening` rewriter needs it on a minimal PATH. This page records the decisions and the one manual step.

## Decisions

**One version, two pins.** Local machines get ast-grep from mise: `"aqua:ast-grep/ast-grep"` in `chezmoi/dot_config/mise/config.toml`. CI gets it from PyPI: `uv tool install ast-grep-cli==X` in `.github/workflows/test.yml`. Renovate tracks the CI pin with a regex manager and puts both pins in the group `ast-grep` (`renovate.json5`). A group joins only the updates that are due at the same time, so it does not guarantee parity. `dots sync` (upgrade mode is on by default) can bump the mise pin alone (`publish_mise_pin_bump` in `packages/lib-mise-pins.sh`). Renovate then opens a CI-only PR that restores parity. Do not add `minimumGroupSize: 2`, because it blocks that CI-only PR. Before this, CI stayed at 0.42.1 while local machines ran 0.51.0.

**Call `ast-grep`, not `sg`.** Upstream deprecates the `sg` alias (`sg --version` prints a deprecation banner). On Linux, util-linux also ships `sg`. Agent permissions (`Bash(ast-grep:*)`) and agent prompts in this repo call `ast-grep`. The rewriter `skills/bash-shortening/scripts/engine.py` (`_sg_binary`) tries `ast-grep` first, then `sg`, and checks `--version` for the string `ast-grep`. The zsh alias `sg='ast-grep'` (`zsh/aliases.zsh`) stays for interactive use only; a non-interactive shell does not see it.

## Gotcha: the autoimprove sandbox needs a real binary in /usr/bin

`skillz autoimprove` runs task calls with `PATH=<claude dir>:/usr/bin:/bin` (the claude transport in `skillz-experiment.pyz`). mise puts ast-grep under `~/.local/share/mise/installs/`, so a task cannot find it, and the skill falls back to hand edits. Runs 1–6 of the bash-shortening onboarding never ran the rewriter for this reason.

A symlink does not fix it. Run 7 had `/usr/bin/ast-grep` as a link into the mise install and `--sandbox-read` on the install directory. Tasks still reported "ast-grep is not installed": Claude Code's own Bash sandbox does not get the `--sandbox-read` mount, so the link dangles. An offline `bwrap` probe shows the same result: the link fails without the home mount and works with it.

Install a real copy instead:

```sh
sudo install -m 0755 "$(readlink -f ~/.local/share/mise/installs/aqua-ast-grep-ast-grep/latest/ast-grep)" /usr/bin/ast-grep
```

The copy does not follow mise. Run the same command again after each ast-grep bump. Check it with `env -i PATH=/usr/bin:/bin ast-grep --version`, and compare the version with the mise pin.

_Source: bash-shortening autoimprove onboarding (PR #1467), runs 6–7 · Updated: 2026-10-29_
