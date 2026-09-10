# `just check` used to mutate source before verifying it

Before PR #885, the `check` recipe (the pre-push gate) started with `lint-fix`
— a **mutating** step (`ruff`/`eslint`/`markdownlint --fix`). Verification and
formatting shared one recipe, so `just check` was not read-only against
tracked source: it could rewrite a file and then check the *rewritten* file,
masking a formatting drift the author never saw or approved.

**Fix (PR #885, commit `4ca3b2d`).** `check` no longer depends on `lint-fix`.
It fans out only read-only legs through GNU parallel: `lint-shell lint-python
lint-js lint-markdown test-python smoke test`. `lint-python` gained `ruff
format --check` so format drift still fails the gate — it just never
auto-fixes. Formatting is now an explicit, separate step: run `just lint-fix`
yourself when a file needs reformatting. `just check` can still create test
environments and tool caches; the read-only contract covers only source files.

**Sibling fix in the same PR: nested agent worktrees needed a markdownlint
ignore.** `.markdownlint-cli2.yaml` gained `**/.claude/worktrees/**` and
`**/.worktrees/**` (the existing `.worktrees/**` entry only matched the
top-level dir). A nested worktree is a derived checkout of this same repo, not
canonical documentation, so it must never be linted as if it were.

Related: [[just-check-claude-guard-flake]] — the other `just check` false
alarm (ambient session count, not a real regression). [[../architecture/config-drift]]
catalogs the platform-specific `just check` gotchas (macOS-only failures,
`cd -P` canonicalization); this page is the mutation-during-verification one.

## Boundary for reusable build skills

A reusable build skill must preserve this repository's verification policy.
The installed `justfile` skill defaults to an autofix `build` gate and a separate non-mutating `ci` gate.[^skill-default]
Those defaults do not replace this repository's explicit separation between `check` and `lint-fix`.[^repo-gate]
Otherwise, a command cleanup can restore the mutation defect that this page records.

Local and CI checks can share recipes without sharing one execution schedule.
The local gate runs independent checks through GNU parallel.
GitHub CI separates lint and test jobs, then runs three test recipes as separate steps.[^ci-layout]
Thus, command parity concerns the checks and their inputs, not one required job layout.

[^skill-default]: Installed skill inspected 2026-09-07: `~/.agents/skills/justfile/SKILL.md:34-51,255-258`. This is evidence of the installed default, not its source location.
[^repo-gate]: `justfile:34-47,71-81`; `AGENTS.md:51-57`.
[^ci-layout]: `.github/workflows/test.yml:12-82`; `justfile:75-81`.
