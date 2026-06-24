---
name: rennet
model: sonnet
allowed-tools: Task, Skill, Bash(gh:*), Bash(gh-issue-context:*), mcp__hallouminate__*, mcp__tilth__*
description: >
  Fan sub-agents over open GitHub issues and triage each into a verdict, grounding
  adversarially against code intelligence, the repo wiki, and external research. Use
  when the user says "triage the issues", "/rennet", "go through the open issues",
  "what's still open", "sweep the backlog". Do NOT use to FILE new issues (that's
  /harness-doctor) or to fix/implement them (that's /cook).
---

# /rennet — Issue Triage

Orchestrates adversarial grounding over open GitHub issues and assigns each a
verdict from the taxonomy below. Works on the current repo only.

## Args

| Form | Behaviour |
|---|---|
| `/rennet` | Sweep current-repo open issues, cap 30 |
| `/rennet <N>` | Deep-triage one issue by number |
| `--label L` | Narrow selection to issues carrying label L |
| `--search Q` | Narrow selection by search query Q |
| `--cap N` | Override the default 30-issue cap |
| `--refresh` | Re-triage issues already carrying a `triage/*` label (default skips them) |

## Verdicts

| Verdict | Label | Comment | Close | Recommends |
|---|---|---|---|---|
| RESOLVED | `triage/resolved` | PR/commit/code evidence | yes `completed` (gated) | — |
| DUPLICATE | `triage/duplicate` | link canonical #M | yes `duplicate` (gated) | — |
| CLEAR-FIX | `triage/clear-fix` | fix path | no | `/cook` |
| NEEDS-DESIGN | `triage/needs-design` | open questions | no | `/mold` |
| DEFERRED | `triage/deferred` | what blocks it | no | — |
| STALE/INVALID | `triage/stale` | why the premise broke | no (left for user) | — |
| NEEDS-INFO | `triage/needs-info` | ask for repro | no | — |

## Protocol

### 1. SELECT

Fetch open issues:

```bash
gh issue list --state open \
  --json number,title,body,labels,createdAt,updatedAt,comments \
  --limit <cap>
```

Apply `--label` / `--search` filters if given. Unless `--refresh` was passed,
drop any issue whose labels already include a `triage/*` entry.

For `/rennet <N>`, use `gh issue view <N>` (or `gh-issue-context <N>`), treat the
issue as deep mode (`needs_code: true`, `needs_research: true`), and skip to
step 3 directly.

### 2. CLASSIFY

Dispatch **one cheap sub-agent** (haiku) with the full issue list and instruct
it to return a compact digest (≤2 KB):

Per issue:

```
{ number, tentative_bucket, needs_code: bool, needs_research: bool,
  dup_cluster_id: string|null, reason: string }
```

Plus a `dup_clusters` list (cross-issue dedup lives here — the classify agent
holds every title/body, so it can cluster duplicates without an orchestrator
explosion).

### 3. GROUND

For each issue flagged `needs_code`, dispatch the `explorer` phase-agent **twice
in parallel** with opposed mandates:

- *confirm-resolved*: "Prove issue #N is RESOLVED: cite the PR/commit/current
  code, or the ADR (`repo:<repo>:wiki`) that settles it."
- *refute-resolved*: "Prove #N is still live: find the unhandled path / missing
  fix / absence of any settling ADR."

For each issue flagged `needs_research`, dispatch the `researcher` phase-agent
**twice in parallel** with opposed mandates:

- *premise-holds*: "Prove the premise of #N still holds upstream."
- *premise-broke*: "Prove it is stale — find the upstream change that voids it."

Each dispatch returns: `file:line` or PR/commit citations, directional verdict,
confidence. `researcher` also returns a research slug path.

**Agreement rule**: both directions agree → confidence `<certain>`. Directions
disagree → CONTESTED, confidence `<speculative>`, close blocked, both sides
recorded in the report.

### 4. VERDICT

For each issue, fold the opposing digests:

1. In single-issue mode (CLASSIFY skipped), derive the bucket directly from the
   grounding digests: RESOLVED if both explorer directions agree; CONTESTED if
   they disagree; STALE/INVALID if researcher proves the premise broke.
2. In sweep mode, start with the classify agent's `tentative_bucket`.
3. If `needs_code` or `needs_research`, promote or demote based on grounding
   results:
   - Both explorer directions agree on RESOLVED → RESOLVED `<certain>`
   - Explorer directions disagree → CONTESTED; keep CLEAR-FIX or NEEDS-DESIGN,
     never RESOLVED
   - Researcher proves premise broke → STALE/INVALID
   - Researcher contested → note it; prefer DEFERRED over STALE/INVALID
4. Draft a comment summarising the evidence (cite file:line, PR/commit, or
   research slug).
5. Record `{ verdict, confidence, recommended_skill, drafted_comment }`.

### 5. REPORT

#### a. Ensure triage labels exist

For each `triage/<verdict>` label that will be applied, check if it exists and
create it if not:

```bash
gh label create triage/resolved --color 0E8A16 --description "Issue resolved by existing code/PR"
gh label create triage/duplicate --color CCE5FF --description "Duplicate of another issue"
gh label create triage/clear-fix --color BFDADC --description "Fix path is clear; ready for /cook"
gh label create triage/needs-design --color FEF2C0 --description "Needs design before implementation"
gh label create triage/deferred --color E4E669 --description "Blocked or not yet actionable"
gh label create triage/stale --color EDEDED --description "Premise no longer holds"
gh label create triage/needs-info --color D93F0B --description "Needs reproduction or clarification"
```

(Skip `gh label create` for any label that already exists; `gh label list` to
check first.)

#### b. Write the report

Write `.cheese/triage/<repo>-<date>.md`:

```markdown
---
repo: <owner/repo>
date: <YYYY-MM-DD>
cap: <N>
filter: <label and/or search, or "none">
counts:
  resolved: N
  duplicate: N
  clear-fix: N
  needs-design: N
  deferred: N
  stale: N
  needs-info: N
  contested: N
---

## Summary

| # | Title | Verdict | Confidence | Recommends | Action |
|---|---|---|---|---|---|
| N | title | VERDICT | <certain>/<speculative> | /skill or — | label+comment / CONTESTED |

## Issues

### #N — <title>

**Verdict**: VERDICT (`<certain>`)
**Recommended**: /cook

**Confirm direction** (explorer):
<findings, file:line citations>

**Refute direction** (explorer):
<findings or "agrees — no live path found">

**Drafted comment**: <text that will be posted>
```

Repeat the `### #N` block for every triaged issue.

#### c. Apply labels and comments (ungated)

For each issue:

```bash
gh issue edit <N> --add-label triage/<verdict>
gh issue comment <N> --body "<drafted_comment>"
```

#### d. Propose closes (gated)

Collect all issues where verdict ∈ {RESOLVED, DUPLICATE} **and** confidence is
`<certain>` **and** a citation is attached. Present the batch in a single
confirmation prompt:

```
Ready to close the following issues (RESOLVED/DUPLICATE, <certain> confidence):
  #12 — "Title" (RESOLVED) — cited: commit abc1234
  #17 — "Title" (DUPLICATE of #5) — <certain>

Approve close? [y/N]
```

On approval, for each issue in the set:

```bash
# RESOLVED
gh issue close <N> --comment "Closing: <citation>" --reason completed

# DUPLICATE
gh issue close <N> --duplicate-of <M> --comment "<evidence linking canonical #M>"
```

CONTESTED issues are **never** in the close set. Issues where confidence is
`<speculative>` are labeled but not proposed for close.

#### e. Report to the user

Output a compact summary:

```
## rennet — <repo> <date>

Triaged: <N> issues  Skipped (already labeled): <M>

Verdicts: RESOLVED <n> | DUPLICATE <n> | CLEAR-FIX <n> | NEEDS-DESIGN <n>
          DEFERRED <n> | STALE <n> | NEEDS-INFO <n> | CONTESTED <n>

Closed: <n> (approved) | Labeled: <n> | Commented: <n>

Report: .cheese/triage/<repo>-<date>.md
```

## Idempotency

Default: skip issues already carrying **any** `triage/*` label — no duplicate
comment, no re-label. `--refresh` overrides: re-triages from scratch, replaces
the existing `triage/*` label, adds a new comment (does not edit the old one).

## Agent dispatch contracts

| Phase | Agent type | In | Out |
|---|---|---|---|
| CLASSIFY | cheap (haiku) sub-agent via `Task` | full issue list JSON | per-issue digest + dup clusters |
| GROUND: needs_code | `explorer` ×2 | issue #, direction mandate | `file:line` citations, directional verdict, confidence |
| GROUND: needs_research | `researcher` ×2 | issue #, direction mandate | claim table, confidence, research slug |

Do not define new agent types. Reuse `explorer` and `researcher` as dispatched
phase-agents.

## gh command reference

```bash
# Select
gh issue list --state open --json number,title,body,labels,createdAt,updatedAt,comments --limit N
gh issue view <N>                  # single-issue mode (or gh-issue-context <N>)

# Label
gh label list --json name
gh label create triage/<v> --color <hex> --description "<desc>"
gh issue edit <N> --add-label triage/<verdict>

# Comment
gh issue comment <N> --body "<text>"

# Close
gh issue close <N> --comment "<text>" --reason completed
gh issue close <N> --duplicate-of <M>  # sets reason=duplicate automatically
```

## What you don't do

- No cross-repo (`--repo`) — current repo only.
- No `--auto` flag — close always requires the one batch confirmation.
- No `--dry-run` — labels and comments are applied ungated; only closes are gated.
- No auto-handoff to `/mold` or `/cook` — the report recommends; the user dispatches.
- No code changes — triage only.
