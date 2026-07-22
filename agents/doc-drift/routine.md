# Doc-Drift Watcher — scheduled routine prompt

You are the **orchestrator** for the dotfiles repo's weekly doc-drift routine,
running in a Claude cloud environment. You detect drift between watched
upstreams and our config, then **triage each drift and act on it** — from a
trivial version-bump PR up to a design issue. You fan the per-item work out to
subagents so each item's release-note reading and reasoning stays in its own
context window.

## Environment

`gh` auth is the environment's native GitHub OAuth. The environment provides
two MCP connectors the routine uses to research each drift: **Tavily** (web
search / page extract, for release notes and changelogs) and **Context7**
(library / API / config docs).

`bin/doc-drift-scan` requires Mike Farah's Go yq; its preflight detects the
wrong flavor (Ubuntu's kislyuk python-yq) and fails loudly rather than
misparsing the registry. Fix via `dots sync` (bootstraps the toolchain) or,
where GitHub release downloads are proxy-blocked, directly:
`GOBIN=~/.local/bin go install github.com/mikefarah/yq/v4@latest`.

In environments without a `gh` binary, `gh_release` sources in the scan
output report as unresolved. Resolve them via the GitHub MCP connector
(repo-scoped) or Tavily against `github.com/<owner>/<repo>/releases/latest`.

## Orchestrator steps

1. Ensure the tracking label exists (idempotent):

       gh label create doc-drift --color BFD4F2 \
         --description "Upstream doc/release drift to reconcile" 2>/dev/null || true

2. Run the scanner from the repo root and parse its JSON with `jq`:

       bin/doc-drift-scan

   Take the elements where `.drifted == true`. If none, exit quietly — no
   output, no artifacts.

3. Dispatch **one subagent per drifted item, in parallel**, each with the
   per-item brief below and its scanner object (`id`, `reconciled`, `current`,
   `type`, `ref`) plus the manifest's `docs` + `governs` for that `id`. If
   subagent dispatch isn't available in this environment, process the items
   **sequentially in this same context** instead — the per-item logic is
   identical.

4. Collect each subagent's one-line result and print a short summary table
   (`<id>: <class> → PR #<n> | issue #<n> | dup`). You never edit config or
   open artifacts yourself — the subagents do.

## Per-item subagent brief

You own exactly ONE drifted source. Inputs: `<id>`, `<reconciled>` →
`<current>`, signal `<type>:<ref>`, `docs`, `governs`.

1. **Dedup.** If an open PR or issue already covers `<id> <current>` (search
   titles, and the branch `doc-drift/<id>-<current>`), stop and report `dup`.

2. **Read the change.** Use **Tavily** to fetch the upstream's release notes /
   changelog for `reconciled → current`, and **Context7** to pull the
   upstream's current config / API docs when you need them to judge impact.
   Then read the `governs` files directly (several are wiki pages under
   `.hallouminate/wiki/` that carry our design rationale) to see the config
   surface. Decide: does anything the release changed touch what those
   `governs` files depend on?

3. **Classify** the drift:
   - **no-op** — nothing we mirror changed (no flag / key / schema / behavior
     in our `governs` surface is touched).
   - **small** — a bounded, well-understood change to a specific config key,
     flag, schema, or doc that maps cleanly to edits in the `governs` files.
   - **large / idea** — a breaking change, a new subsystem, several
     interacting changes, or something that needs a design decision or an idea
     worth proposing. Brainstorm briefly before writing it up.

4. **Act by class** — exactly one artifact, on branch `doc-drift/<id>-<current>`:
   - **no-op** → open a PR that ONLY bumps `reconciled: "<current>"` for `<id>`
     in `agents/doc-drift/sources.yaml`, then **merge it** — nothing but the
     marker changed, so there is nothing to review:

         gh pr ready <pr>   # in case gh opened it as a draft
         # Prefer CI-gated auto-merge where the repo has required checks:
         gh pr merge <pr> --squash --delete-branch --auto \
           || gh pr merge <pr> --squash --delete-branch

     The `--auto` attempt gates on required checks (merge queue) where branch
     protection exists; where it doesn't (GitHub rejects `--auto` with "clean
     status" / "no protected branch rules"), the fallback merges the marker
     bump directly. Only ever a no-op bump merges this way.
     Title: `chore(doc-drift): bump <id> to <current> (no-op)`.
   - **small** → open a PR with the config / renderer / wiki edits AND the
     `reconciled` bump. Run `just check`; if the env can't, say so in the body
     and rely on CI.
     Title: `fix(doc-drift): <id> <current> — <one-line what changed>`.
     Body: the changelog delta, the edits, and why.
   - **large / idea** → open a GH issue (label `doc-drift`) with the change,
     the options you weighed, and a recommendation. Do NOT bump `reconciled`
     or open a PR.
     Title: `doc-drift: <id> <reconciled> → <current> — <topic>`.

5. Report one line: `<id>: <class> → PR #<n> | issue #<n> | dup`.

## Invariants

- **Auto-merge only no-op bumps.** A no-op `reconciled`-bump PR (marker advance
  only, no config/renderer/wiki edits) is merged automatically — there is
  nothing to review. It is CI-gated where the repo has required-check branch
  protection (via `--auto`); where it doesn't, the marker bump merges directly.
  Every **small** and **large/idea** artifact stays human-reviewed; merging a
  reviewed PR and the follow-on `dots sync` stay with the human.
- **`reconciled` advances only inside a PR** — never a direct push to `main`.
- **One artifact per drifted item.** Honor the dedup.
- **Subagents are file-disjoint** — each touches only its own `governs` files
  and its own `reconciled` line in `sources.yaml` (git merges the per-line
  bumps); never another item's files or branch.
