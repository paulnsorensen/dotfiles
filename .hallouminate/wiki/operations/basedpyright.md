# basedpyright

The global Python type checker is basedpyright, mise-pinned as `"npm:basedpyright"` in `chezmoi/dot_config/mise/config.toml`, replacing stock pyright (swapped 2026-08, commit `2496fd5`). The npm package ships `pyright`/`pyright-langserver` compatibility binaries, so the existing mise shims still resolve for anything invoking the old names — editors configured for `pyright-langserver` keep working untouched. The stray Homebrew `pyright` formula (never in `packages/packages.yaml`) was uninstalled at the same time.

## Why basedpyright over pyright

- Same core engine (fork of Microsoft's pyright) but ships the LSP features Pylance paywalls: semantic highlighting (including the 3.12 `type` keyword), improved inlay hints, and docify-scraped stdlib docstrings. Zed, Neovim, and Helix default to it.
- ~14 based-only diagnostic rules beyond stock pyright: `reportUnusedCallResult`, `reportAny`, `reportExplicitAny`, `reportImplicitStringConcatenation`, `reportIgnoreCommentWithoutRule`, `reportPrivateLocalImportUsage`, and friends. Stock pyright passes code these rules flag.
- pip-installable native CLI (`uvx basedpyright` works zero-install as a fallback).

## Effective use

- Default `typeCheckingMode` is `recommended`, not pyright's `standard`: every rule enabled with an error/warning split and `failOnWarnings = true`, so a full run fails on warnings too. Drop to `standard` only to match stock-pyright strictness.
- Pin repo config in `[tool.basedpyright]` in `pyproject.toml` (include paths, `pythonVersion`, per-path `executionEnvironments`) so editor LSP, CLI, and CI agree. Leaving `typeCheckingMode` unset keeps the `recommended` default.
- Adopting in a repo with a diagnostic backlog: `basedpyright --writebaseline` grandfathers existing diagnostics into `.basedpyright/baseline.json` — review it before committing (warnings baseline alongside errors). Entries for fixed diagnostics auto-remove on the next run (`baselineMode = "discard"` disables that). Never hand-edit the baseline.
- CI: the CLI auto-detects GitHub Actions and emits inline PR annotations with zero flags. `--outputjson` gives machine-readable diagnostics; `--gitlabcodequality` exists for GitLab.
- Upstream explicitly recommends exact-version pinning for reproducibility — hence the exact mise pin. `basedpyright --version` reports both its own version and its pyright base.
- Suppressions must be rule-scoped (`# pyright: ignore[ruleName]`); `reportIgnoreCommentWithoutRule` flags bare ignores.

## Where this landed

- mise pin: `chezmoi/dot_config/mise/config.toml` (`npm:basedpyright` = 1.39.10), tests in `tests/mise-config.bats` and `tests/packages.bats`.
- easy-cheese: `[tool.basedpyright]` pinned in `pyproject.toml` (3.12, schemas package execution-env at 3.11 for its `requires-python >=3.11` wheel); usage doctrine in `.agents/skills/python-authoring/SKILL.md` § "Type-check with basedpyright".
- Full cited research: `.cheese/research/basedpyright-capabilities/basedpyright-capabilities.md` (dotfiles-cheese corpus; original with raw fetches lives in easy-cheese's `.cheese/research/`).
