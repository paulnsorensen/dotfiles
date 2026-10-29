# ast-grep: pins, the sg alias, and the eval sandbox link

ast-grep has one version in two places, and the `bash-shortening` rewriter needs it on a minimal PATH. This page records the decisions and the one manual step.

## Decisions

**One version, two pins.** Local machines get ast-grep from mise: `"aqua:ast-grep/ast-grep"` in `chezmoi/dot_config/mise/config.toml`. CI gets it from PyPI: `uv tool install ast-grep-cli==X` in `.github/workflows/test.yml`. Renovate tracks the CI pin with a regex manager and puts both pins in the group `ast-grep` (`renovate.json5`), so one PR bumps both. Before this, CI stayed at 0.42.1 while local machines ran 0.51.0.

**Call `ast-grep`, not `sg`.** Upstream deprecates the `sg` alias (`sg --version` prints a deprecation banner). On Linux, util-linux also ships `sg`. The rewriter `skills/bash-shortening/scripts/engine.py` (`_sg_binary`) tries `ast-grep` first, then `sg`, and checks `--version` for the string `ast-grep`. The zsh alias `sg='ast-grep'` (`zsh/aliases.zsh`) stays for interactive use only; a non-interactive shell does not see it.

## Gotcha: the autoimprove sandbox PATH

`skillz autoimprove` runs task calls with `PATH=<claude dir>:/usr/bin:/bin` (the claude transport in `skillz-experiment.pyz`). The OS sandbox reads only system paths, the workspace, and each `--sandbox-read` root. mise puts ast-grep under `~/.local/share/mise/installs/`, so a task cannot find it, and the skill falls back to hand edits. Runs 1–6 of the bash-shortening onboarding never ran the rewriter for this reason.

The fix has two parts:

1. A system link to the mise `latest` alias, so a mise bump does not break it:

   ```sh
   sudo ln -sfn ~/.local/share/mise/installs/aqua-ast-grep-ast-grep/latest/ast-grep /usr/bin/ast-grep
   ```

2. A read-only mount of the whole install directory, so the `latest` link resolves inside the sandbox:

   ```sh
   --sandbox-read ~/.local/share/mise/installs/aqua-ast-grep-ast-grep
   ```

   Pass the resolved absolute path. A root must not be a symlink.

Check the link after a mise bump or `mise prune`: `env -i PATH=/usr/bin:/bin ast-grep --version`. A link that points at a removed version directory fails this check.

_Source: bash-shortening autoimprove onboarding (PR #1467), runs 6–7 · Updated: 2026-10-29_
