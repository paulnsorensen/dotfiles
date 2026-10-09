# AGENTS.md

`__PROJECT__`: replace this line with one sentence about the project.

## Gate

Run `just check` before you report work as done. It must exit 0.
CI runs `just ci`, which runs the same checks without fixes.

## Commands

| Task | Command |
|---|---|
| Install | `uv sync` |
| Format and lint fixes | `just fix` |
| Type check | `just typecheck` |
| Dead code | `just deadcode` |
| Tests | `just test [pytest args]` |

## Python

Read `.agents/skills/python-authoring/SKILL.md` before you change Python.

- Run Python tools through `uv run`. Do not call `pip` or a bare `python`.
- Add a runtime dependency with `uv add` and a dev tool with `uv add --dev`. Commit `uv.lock`.
- Keep runtime code in `src/__PACKAGE__/` and tests in `tests/`.

## Suppressions

Fix a finding at its cause. Each suppression needs a written reason.

- basedpyright: `# pyright: ignore[ruleName]`. Do not use a bare `# type: ignore`.
- ruff: `# noqa: CODE`.
- vulture: one line in `vulture_whitelist.py`. Do not lower `min_confidence`.
