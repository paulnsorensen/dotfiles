---
name: python-scaffold
description: >
  Scaffold a new uv Python repository, or retrofit an existing one, with ruff,
  basedpyright, vulture, pytest, prek hooks, a GitHub Actions CI workflow,
  AGENTS.md, and a repo-local python-authoring skill. The user
  invokes it as /python-scaffold [<dir>].
  Do NOT use for Python code changes (the repo-local python-authoring skill)
  or for CI speed work (/ci-optimize).
disable-model-invocation: true
argument-hint: "[<dir>] [--python <version>] [--lib] [--no-ci] [--no-prek]"
license: MIT
metadata:
  author: paulnsorensen
---

# /python-scaffold

Set up one Python repository with a single local gate, `just check`, and a matching CI gate, `just ci`.
The assets hold tested defaults. [`references/decisions.md`](references/decisions.md) records the reason and source for each default.

## Inputs

Read the flags from the text after the skill name.

```text
/python-scaffold [<dir>] [--python <version>] [--lib] [--no-ci] [--no-prek]
```

- `<dir>`: the target directory. Default: the current directory.
- `--python`: the minimum Python version. Default: the newest stable minor that `uv python list` shows.
- `--lib`: make a library (`uv init --lib`). Default: an application with a console script (`uv init --package`).
- `--no-ci`: do not write `.github/workflows/ci.yml`.
- `--no-prek`: do not write `.pre-commit-config.yaml`.

## Placeholders

Replace each placeholder in every copied asset.

| Placeholder | Value |
|---|---|
| `__PROJECT__` | The `[project].name` value, for example `demo-app` |
| `__PACKAGE__` | The import name, for example `demo_app` |
| `__PYTHON__` | The minimum Python version, for example `3.12` |

After the copy, search the target for `__PROJECT__`, `__PACKAGE__`, and `__PYTHON__`. No match must remain.

## Flow

1. **Inspect.** Read the target `pyproject.toml`, `justfile`, `.pre-commit-config.yaml`, `.github/workflows/`, `AGENTS.md`, `CLAUDE.md`, and `.gitignore`. Set the mode: `new` when `pyproject.toml` is absent, else `retrofit`.
2. **Init (new mode).** Run `uv init --package --python <version> <dir>`, or `uv init --lib` for `--lib`. Keep the `uv_build` backend, the `src/` layout, and `.python-version`.
3. **Respect the repo (retrofit mode).** Keep the project metadata, build backend, and package layout. Set `include` and the vulture `paths` to the real source and test directories. When the repo uses mypy, ask once whether basedpyright replaces it. Do not run two type checkers.
4. **Add tools.** Run `uv add --dev basedpyright pytest ruff vulture`. Skip a tool that the dev group already has. `uv.lock` pins the exact versions.
5. **Merge configuration.** Merge the tables of [`assets/pyproject-tools.toml`](assets/pyproject-tools.toml) into `pyproject.toml`. In retrofit mode, keep each existing value, add only missing keys, and list each conflict for the user.
   When `[tool.pytest.ini_options]` exists, move its keys into `[tool.pytest]` and delete it. pytest 9 stops with an error when both tables exist.
6. **Copy assets.** Copy each asset to its target. In retrofit mode, merge recipes and hooks into existing files. Never replace an existing file without showing the diff and getting approval.

   | Asset | Target | Skip with |
   |---|---|---|
   | [`assets/justfile`](assets/justfile) | `justfile` | |
   | [`assets/vulture_whitelist.py`](assets/vulture_whitelist.py) | `vulture_whitelist.py` | |
   | [`assets/pre-commit-config.yaml`](assets/pre-commit-config.yaml) | `.pre-commit-config.yaml` | `--no-prek` |
   | [`assets/ci.yml`](assets/ci.yml) | `.github/workflows/ci.yml` | `--no-ci` |
   | [`assets/AGENTS.template.md`](assets/AGENTS.template.md) | `AGENTS.md` | |
   | [`assets/python-authoring.template.md`](assets/python-authoring.template.md) | `.agents/skills/python-authoring/SKILL.md` | |

   The instruction assets use `.template.md` names. This stops a harness from loading them as live instructions in this skill directory.

7. **Wire the agent files.**
   - Replace the one-line purpose in `AGENTS.md` with a real description of the project.
   - Do not create `CLAUDE.md`. Claude Code reads `AGENTS.md` when no `CLAUDE.md` exists.
   - In retrofit mode, keep the repository rules and add only the missing sections.
   - When `CLAUDE.md` exists, make it import `@AGENTS.md`. Claude Code ignores `AGENTS.md` when `CLAUDE.md` exists. Ask before you move existing `CLAUDE.md` rules into `AGENTS.md`.
   - Link the skill for Claude Code with `ln -s ../../.agents/skills/python-authoring .claude/skills/python-authoring`.
   - When `.gitignore` ignores `.agents/` or `.claude/`, add `!` re-include lines for the two skill paths.
8. **Fit the entry points.**
   - In application mode, keep the `main` line in `vulture_whitelist.py`. The console script calls `main`, and vulture cannot see that call.
   - In library mode, replace `main` with one line for each public API name.
   - Write one behavior test for the generated entry point. pytest exits 5 when it collects no tests.
9. **Baseline (retrofit mode).**
   - Run `uv run basedpyright --writebaseline` and commit `.basedpyright/baseline.json`.
   - Run `uv run vulture --make-whitelist`. Put only confirmed false positives in `vulture_whitelist.py`, each with a reason.
   - Put the remaining findings under a `# Baseline <date>` header. Later work removes these lines.
   - Run `just fix`. Then run `uv run ruff check --add-noqa` for the findings that `--fix` cannot fix.
   - Run `just test`. For each existing warning that `filterwarnings = ["error"]` turns into a failure, add one `ignore` entry under a `# Baseline <date>` comment.
   - Report the count of baseline entries for each tool: basedpyright, vulture, ruff, and pytest.
10. **Converge.**
    - Run `uv sync` and `just check`. It must exit 0.
    - Run `just ci`. It must exit 0 with no file changes.
    - When `prek` is on `PATH`, run `prek install` and `prek run --all-files`.

## Rules

- Do not commit or push. Hand the result to the user, or to `/plate` when the user asks for it.
- Do not add coverage gates, docs builds, release workflows, Renovate, or extra tools unless the user asks.
- Keep every GitHub Action pinned to a full commit SHA with a version comment. Keep `persist-credentials: false` and `permissions: contents: read`.
- Fix a finding at its cause. Use a scoped suppression only with a written reason: `# pyright: ignore[rule]`, `# noqa: CODE`, or a whitelist line.
- Do not lower `min_confidence` or change `typeCheckingMode` to clear findings.
- The asset versions are from the `Checked:` date in `references/decisions.md`. When that date is more than 90 days old, check the latest action SHAs and tool versions before you copy.

## Report

Return these items:

- The mode, the target directory, and each file that the skill created or merged.
- Each retrofit conflict and the value that the skill kept.
- The baseline entry counts for basedpyright, vulture, ruff, and pytest.
- The exit codes of `just check`, `just ci`, and `prek run --all-files`. Name each check that did not run.
