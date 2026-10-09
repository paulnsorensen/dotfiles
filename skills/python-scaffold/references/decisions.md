# Scaffold decisions

Checked: 2026-10-08. Each row gives the default, the reason, and the source.
The local survey covered easy-cheese, vaudeville, milknado, cheese-flow, copeca, draft-planner, ffl, football, kaupmangr, next-gen-drafts, and skillz-that-grillz under `~/Dev`.

## Versions

| Tool | Version | Source |
|---|---|---|
| basedpyright | 1.40.2 | <https://pypi.org/project/basedpyright/> |
| vulture | 2.16 | <https://pypi.org/project/vulture/> |
| ruff | 0.16.10 | <https://pypi.org/project/ruff/> |
| pytest | 9.1.1 | <https://pypi.org/project/pytest/> |
| prek | 0.5.5 | <https://github.com/j178/prek/releases> |
| `actions/checkout` | v7.0.1 `3d3c42e5aac5ba805825da76410c181273ba90b1` | `gh api repos/actions/checkout/releases/latest` |
| `astral-sh/setup-uv` | v10.2.0 `c18668ad3cf93ea998bef934396af7bb5c839dc7` | `gh api repos/astral-sh/setup-uv/git/ref/tags/v10.2.0` |
| uv | 0.12.23 | local `uv --version` |
| just | 1.58.0 | `gh api repos/casey/just/releases/latest` |

`setup-uv` publishes no floating `v10` tag. Pin the full SHA and the `version` input. <https://github.com/astral-sh/setup-uv>

## basedpyright

| Default | Reason | Source |
|---|---|---|
| `typeCheckingMode = "recommended"` | It is the default. It enables every rule as an error or warning and sets `failOnWarnings`. The value is explicit so a reader does not need to know the default. easy-cheese and milknado use it. | <https://docs.basedpyright.com/latest/configuration/config-files/> |
| No `venvPath` or `venv` | basedpyright finds `./.venv` when no interpreter setting exists. easy-cheese sets `venv` only for a separate typing venv. | <https://docs.basedpyright.com/latest/benefits-over-pyright/better-defaults/> |
| `include = ["src", "tests"]` | Tests are code; they get the same checks. With `uv sync`, the editable install resolves `src` imports, so no `extraPaths` is needed. | local survey |
| Baseline only in retrofit mode | `--writebaseline` writes `.basedpyright/baseline.json`. Local runs shrink it, and CI locks it. A new repo starts clean. | <https://docs.basedpyright.com/latest/benefits-over-pyright/baseline/> |
| No test rule relaxations | No surveyed repo relaxes rules for tests. Add an `executionEnvironments` entry only after a real finding needs it. | local survey |

## vulture

| Default | Reason | Source |
|---|---|---|
| `min_confidence = 60` | Unused arguments and unreachable code score 100, imports 90, everything else 60. A higher floor hides unused functions, classes, and attributes, which ruff does not find. Four surveyed repos use 60. | <https://github.com/jendrikseipp/vulture> |
| `paths = ["src", "vulture_whitelist.py"]` | Test references hide unused production code. vaudeville, milknado, and kaupmangr scan shipped code only. | local survey |
| A whitelist file instead of `ignore_names` | The README prefers whitelists. A whitelist line can carry its reason. | <https://github.com/jendrikseipp/vulture> |
| Exit code 3 | vulture exits 3 when it finds dead code, so `just ci` fails. | <https://github.com/jendrikseipp/vulture> |

Ruff `F401` and `F841` find unused imports and locals. Ruff `ARG` finds unused arguments. vulture adds unused functions, classes, and attributes across modules.

## ruff

The rule set is the vaudeville and milknado set: `E F I UP B SIM ANN ARG BLE PTH RUF100 PLR0913 PLR0915`, line length 99, at most 4 arguments and 40 statements. easy-cheese uses a smaller set; football and next-gen-drafts use a larger one. The middle set catches slop without many per-file waivers.

## pytest

pytest 9 adds `strict = true`. It enables `strict_config`, `strict_markers`, `strict_parametrization_ids`, and `strict_xfail`. Later pytest versions can add more strict options, so `uv.lock` pins the version. `filterwarnings = ["error"]` comes from kaupmangr. <https://docs.pytest.org/en/stable/reference/reference.html>

## CI

The uv guide pins `setup-uv`, turns on the cache, sets `python-version` from the matrix, and runs `uv sync --locked`. `UV_LOCKED=1` applies `--locked` to every uv command in the job. CI runs `just ci`, so local and CI checks cannot drift. <https://docs.astral.sh/uv/guides/integration/github/>

## prek

prek reads `.pre-commit-config.yaml`, so the same file works with pre-commit. The hooks are `local` and call `uv run`, so hook versions come from `uv.lock`. <https://github.com/j178/prek>

## AGENTS.md and CLAUDE.md

| Default | Reason | Source |
|---|---|---|
| A short `AGENTS.md` with the gate, commands, and non-standard rules | A 2026 study of Python repos found that context files often lower task success and add cost. They help most for non-standard tooling. | <https://arxiv.org/abs/2602.11988> |
| No `CLAUDE.md`; an existing one imports `@AGENTS.md` | Claude Code reads `AGENTS.md` only when no `CLAUDE.md` exists. One file gives both harnesses one source. Keep each file under 200 lines. | <https://code.claude.com/docs/en/memory> |
| A repo-local python-authoring skill | easy-cheese, milknado, skillz-that-grillz, and next-gen-drafts keep long Python rules in a skill, not in `AGENTS.md`. The skill loads only for Python work. | local survey |

Codex joins `AGENTS.md` files from the root to the working directory, and the closest file wins. The combined limit is 32 KiB. <https://agents.md>
