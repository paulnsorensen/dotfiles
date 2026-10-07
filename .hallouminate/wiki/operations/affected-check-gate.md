# `just check` runs only affected legs and tests

`just check` compares the work tree with the merge base of `origin/main` (then `main`).
It runs only the lint legs and test files that the changed paths can affect.
`just check-all` runs every leg in full. CI still runs every leg on each pull request.
Use `just check --plan` to see the selection without running it.

## Where the logic lives

- `tests/lib/affected.py` owns selection. It uses only the standard library and runs on the macOS system Python 3.9.
- `tests/check-affected.sh` parses options and dispatches the selected legs through GNU parallel (`--jobs 0`, slowest leg first).
- `tests/lib/test_affected.py` holds the unit tests. `tests/check-affected.bats` runs them and tests the dispatcher with a stub `just`.

## Selection rules

Lint legs use path rules:

| Changed path | Leg |
|---|---|
| `*.md` | `lint-markdown` on the changed files only |
| `.markdownlint-cli2.yaml`, `.github/lint-deps/**` | `lint-markdown` in full |
| `*.sh`, `*.bash`, `.sync`, `bin/**`, sh/bash shebang | `lint-shell` in full |
| `*.py`, `pyproject.toml`, `ruff.toml` | `lint-python` in full |
| `claude/hooks/**`, `.github/lint-deps/**` | `lint-js` in full |
| `agent-profile/`, `profiles/`, `agents/`, `chezmoi/.chezmoidata/`, some registries | `test-python` in full |
| `justfile`, `tests/check-affected.sh`, `tests/lib/affected.py` | every leg in full |

Bats and workflow smoke tests are selected per file. The map lives in the test files, so there is no separate registry to maintain.
A test file is selected for a changed path when:

1. One of its path tokens is the path, or a directory (two or more segments) that contains it. `$VAR` segments become `*`, so `"$DOTFILES_DIR"/skills/*/SKILL.md` is a glob.
2. It names the file as a word: the basename when it is unique in the repository, else `parent/basename`. This catches bare `bin/` commands, because `test_helper.bash` puts `bin/` on `PATH`.
3. It calls a `tests/*.bash` helper function whose body names the path (for example `omp_pin_version` reads `packages/sync.sh`).
4. It selects a file that sources or imports the changed file. The closure follows `source`, `.`, `import`, `from`, and `require(` lines, up to five levels. It also follows same-directory relative sources such as `. "$DIR/lib.sh"`.

`tests/test_helper.bash`, `tests/run-tests.sh`, and `tests/install-bats.sh` select the whole Bats suite.
`tests/workflows/harness.mjs` and `tests/workflows-test.sh` select the whole smoke suite.

## Decisions and why

- **No sibling rule.** An early version also selected tests that named any file in the same directory. Over the last 60 commits, this rule roughly doubled the selection. For example, a `codex.yaml` edit selected every test that reads `claude.yaml` or `omp.yaml`. The source closure finds real users of a library more precisely.
- **No mention closure.** The selector does not follow arbitrary code files that name a changed data file. A central file such as `agents/registry.yaml` would fan out to most of the suite. CI catches the remaining gaps.
- **One-segment tokens match only exactly.** Many tests export `"$DOTFILES_DIR/bin:$PATH"`. A `bin` directory rule would select most of the suite for any `bin/` change.
- **Unmatched paths are reported, not escalated.** The summary lists each existing changed path that no leg or test observes. Deleted paths are not listed.
- **BDD is not the tool for this.** Research on 2026-10-07 found that BDD (Gherkin or Cucumber tags, ShellSpec `--tag`) is a spec style. Its tags are hand-written labels with no mapping from changed files to tests. Path-to-test maps with a run-all fallback (Nx affected, Bazel `rdeps`, test impact analysis) are the standard pattern. bats-core 1.8.0+ supports `# bats file_tags=` and `--filter-tags`, but per-file selection needs no tags.[^bdd]

## Measured selection

Over the last 60 non-merge commits, the selector chose a median of 5 and a mean of 9.5 of 106 Bats files. Only 2 commits ran the full suite, both because they changed the `justfile`. Selection takes about 1 second.

`lint-shell` now runs one shellcheck process per file across all cores. `.sync` alone takes about 9 seconds under load, so `lint-shell` cannot finish faster than that file.

## Known gaps

- Data files read through paths that a script builds at run time (for example Python `Path` joins) are not tokens. The `test-python` prefix list covers the agent-profile suite by hand.
- A Bats test that runs a script indirectly, through a script that names a data file, is not selected for a change to that data file.
- CI runs every leg, so a gap costs one CI round trip, not a missed regression.

[^bdd]: bats-core docs (writing-tests, usage) and CHANGELOG 1.8.0; nx.dev/ci/features/affected; bazel.build/query/language; martinfowler.com/articles/rise-test-impact-analysis.html; cucumber.io/docs/cucumber/api/#tags; github.com/shellspec/shellspec.

Related: [[just-check-read-only-gate]], [[test-suite-performance]].
