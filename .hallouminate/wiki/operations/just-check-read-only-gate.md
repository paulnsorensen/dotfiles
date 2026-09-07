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
