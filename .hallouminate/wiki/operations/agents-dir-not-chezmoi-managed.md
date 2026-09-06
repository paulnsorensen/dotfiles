# Gotcha: `~/.agents/` is harness-managed, never chezmoi-managed

`~/.agents/skills` is a **harness-managed skill cache**, not chezmoi source.
`chezmoi/lib/install-external.sh` (forced after apply by `bin/dots:do_sync`)
populates it via the `skills` CLI for non-Claude harnesses, and OMP discovers
it — gated by `omp.config.skills.enableAgentsUser: true` in
`chezmoi/.chezmoidata/omp.yaml`. The tree is gitignored as `.agents/` (root
`.gitignore`, "Harness-managed agent skill cache").

## The accidental-capture trap (recurring)

A stray `chezmoi add ~/.agents` (or an editor/agent that runs it) captures the
whole live cache into a `chezmoi/private_dot_agents/exact_skills/` source tree —
~245 files with `.pyz` scripts. Nothing in the repo assembles or references that
path, so it surfaces only as a large untracked dir in `git status`, and once
present `chezmoi managed` starts listing `~/.agents/**` under `exact_`
(deletions-propagate) semantics it was never meant to own.

**Fix + guard (PR that added this page):**

- Delete the stray `chezmoi/private_dot_agents/` source tree.
- `chezmoi/.chezmoiignore` carries a target-relative `.agents/**` entry.
  `chezmoi add` honors `.chezmoiignore`, so the capture cannot recur.

**Do not** add an assembly step for this dir. It is a live cache the harness
owns end-to-end; chezmoi's only correct relationship to it is to ignore it.

## Sibling gotcha: the OMP assembled tree needs a markdownlint ignore

`chezmoi/dot_omp/private_agent/exact_skills/` (assembled by
`sync_omp_chezmoi_sources`) is gitignored but stays on disk, and `just check`
globs `**/*.md`, so its vendored skill docs red `lint-markdown` on upstream
formatting. It needs an `ignores:` entry in `.markdownlint-cli2.yaml` exactly
like the `dot_claude/exact_*` and `private_dot_codex/exact_*` trees. This entry
was missing until the same PR and surfaced once the OMP skills tree was
populated. Every assembled `exact_` tree needs its markdownlint ignore.
