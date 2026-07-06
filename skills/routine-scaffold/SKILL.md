---
name: routine-scaffold
model: sonnet
effort: medium
allowed-tools: Task, Skill, Bash(gh:*), Bash(git:*), mcp__tilth__*
description: >
  Author, review, land, and register a Claude Code cloud routine end-to-end —
  a scheduled or event-triggered cloud agent that opens PRs/issues a human
  disposes. Use when the user says "make a routine", "schedule a cloud agent",
  "scaffold a watcher", "set up a recurring automation", "/routine-scaffold", or
  points at a recipe (drift-watcher, stale-docs, changelog-draft, repo-brief,
  flaky-test-triage, pr-review-nag). Drives the `coder` and `reviewer` phase
  agents and hands registration to the cloud-routine registrar (`RemoteTrigger`).
  Do NOT use for local scheduled tasks (the `create_scheduled_task` /
  plugin-`schedule` kind) or for one-off code changes (that is `/cook`).
---

# /routine-scaffold — scaffold a Claude Code cloud routine

Turns "I want a recurring cloud automation" into a landed PR plus a registered
routine. A **cloud routine** is a scheduled or event-triggered Claude Code agent
that runs in a hosted environment, reads a version-controlled prompt, and opens
PRs/issues for a human to dispose — it never merges its own work.

The live `agents/doc-drift/` watcher is the reference pattern this skill
generalizes. Read [`references/routine-authoring.md`](references/routine-authoring.md),
[`references/safety.md`](references/safety.md),
[`references/triggers.md`](references/triggers.md), and
[`references/schedule-mechanics.md`](references/schedule-mechanics.md) as the
taught payload; the same rules are baked into the flow's invariants below.

## Args

```text
/routine-scaffold [<repo>] [--recipe <name>] [--trigger cron <expr> | api | github-event <event>]
```

- `<repo>` — target repo (path or `owner/name`). Default: the git repo of the
  current directory. Must be a repo the user owns; artifacts land in its tree.
- `--recipe <name>` — start from a vetted recipe under
  [`recipes/`](recipes/): `drift-watcher`, `stale-docs`, `flaky-test-triage`,
  `changelog-draft`, `repo-brief`, `pr-review-nag`. Omit to author from a blank
  interview.
- `--trigger` — trigger type. `cron <expr>` (min interval 1 hour, UTC),
  `api` (on-demand `RemoteTrigger.run`), or `github-event <event>` (reactive,
  e.g. `pull_request`). If omitted, the recipe's suggested trigger is offered
  and the user confirms. See `references/triggers.md`.

## When to use

Use for any recurring or event-driven **cloud** automation that should produce
reviewable artifacts: dependency/doc drift, stale-doc sweeps, changelog drafts,
PR-review nags, flaky-test triage, repo briefs.

Do NOT use for:

- **Local scheduled tasks** (`create_scheduled_task`) — that is the plugin
  `schedule` skill's local-cron kind; this skill is cloud routines only.
- **A one-off code change** — that is `/cook`.
- **Registering a hand-written routine with no repo artifacts** — drive the
  `RemoteTrigger` cloud registrar directly.

## Ambient assumptions

The hosted environment provides (confirm per target, do not hardcode):

- **`gh` GitHub OAuth** — the environment's native auth; no PAT. Cross-repo
  reach is unconfirmed — verify write access to the target before promising a
  PR (see Frame, step 3).
- **Account connectors auto-attach** to any routine created in the environment
  — Tavily and Context7 are the defaults this skill assumes. Their exact
  `mcp__<Server>__<tool>` casing is confirmed off the first live run, never
  guessed (see Register + Verify).
- **Setup scripts and env vars are supported; custom base images are not.**

## Flow

Six phases. Code writing goes to the `coder` agent, review to `reviewer`,
registration to the `RemoteTrigger` cloud registrar, landing to `/pr-stack` or
`gh`.

### 1. Frame

1. **Resolve the target repo.** Default to the cwd git repo
   (`git rev-parse --show-toplevel`). Confirm it with the user before writing
   anything. If `<repo>` names another repo, resolve it and confirm.
2. **Confirm ownership.** The repo must be one the user owns
   (`gh repo view <owner/name> --json viewerCanAdminister,nameWithOwner`).
3. **Verify write reach.** Confirm the environment's `gh` OAuth can push a
   branch and open a PR against the target. If reach is unconfirmed, say so and
   stop before promising a PR — cross-repo OAuth is a known risk.
4. **Pick the trigger type** (`cron` / `api` / `github-event`) — see
   `references/triggers.md`.
5. **Pick or skip a recipe.** With `--recipe`, load its skeleton from
   `recipes/<name>.md` and adopt its objective + prompt shape + suggested
   trigger. Without, interview from scratch.
6. **Interview for the contract:** the objective, the explicit
   **success condition**, and the explicit **stop condition** (what "nothing to
   do" looks like — the routine must exit quietly when it finds nothing).

### 2. Author

Dispatch the **`coder`** phase agent to draft artifacts in the target repo's
tree, applying `references/routine-authoring.md`:

- `agents/<name>/routine.md` — the committed prompt (single source of truth).
- When the task is a **scan-and-triage watcher** shape (the doc-drift triad):
  also scaffold `agents/<name>/sources.yaml` (the data manifest) and
  `bin/<name>-scan` (a deterministic scanner) **with bats tests** that join the
  target repo's test suite. The scanner holds all the version/diff math so the
  routine's judgment stays deterministic and testable.

`coder` returns the file list and confirms the scanner's tests pass locally
(where the target repo has a runnable suite).

### 3. Review

Dispatch the **`reviewer`** phase agent to check the artifacts against the
safety + authoring checklist (`references/safety.md`,
`references/routine-authoring.md`). Reviewer must confirm:

- the never-auto-merge invariant is present in the routine's prompt,
- stop/idempotency/dedup conditions are explicit,
- the prompt is self-contained (no reference to an authoring session),
- evidence-not-inference: the routine acts on scanner/tool output, not guesses.

Loop back to Author on any blocker before landing.

### 4. Land

Open the authoring PR into the target repo — **never a direct push to a default
branch**. Prefer `/pr-stack` when a stacking tool is present in the target;
otherwise `gh`. The PR carries the routine.md (+ manifest + scanner + tests when
present). Do not configure auto-merge.

### 5. Register

Hand off to the **cloud-routine registrar** — the `RemoteTrigger` tool (actions
`list`/`get`/`create`/`update`/`run`; **no delete**) — to create the routine. Do
**not** route this to the local-task skill also named `schedule` (the
`create_scheduled_task` kind): that is the spec non-goal, evaluates cron in local
time, and cannot register a cloud routine. See `references/schedule-mechanics.md`
for the disambiguation. Payload:

- **env** — the environment id.
- **trigger** — the chosen `cron` / `api` / `github-event` config
  (`references/triggers.md`).
- **`allowed_tools`** — the connector allowlist as `mcp__<Server>__<tool>`
  (server segment literal; default connectors Tavily + Context7).
- **message** — a short **bootstrap**:
  `read agents/<name>/routine.md and follow it exactly`. The real prompt lives
  in the committed file; the scheduled message only points at it.

If the `RemoteTrigger` API exposes only cron creation, register cron here and
note the api/github-event wiring as a manual follow-up (spec open question —
verify against the `RemoteTrigger` tool before asserting otherwise).

### 6. Verify

Surface to the user:

- the routine link and next-run time,
- the **connector-casing caveat**: the `mcp__<Server>__<tool>` casing is
  confirmed off the first live run's granted-tools list; if the run is blocked
  with `host_not_allowed` / a tool refusal, adjust the allowlist strings and
  update the routine (see `references/safety.md`).

## Invariants (baked in)

These hold for every routine this skill produces, regardless of recipe:

- **Never auto-merge.** Every routine opens a PR/issue a human disposes. Merge
  and any follow-on sync stay with the human.
- **No direct push to a default branch.** Reconciling state advances only inside
  a PR.
- **Exit quietly on nothing-to-do.** When the routine finds nothing to act on it
  produces no output and no artifacts.
- **One artifact per item; honor dedup.** Watchers check open PRs/issues (and the
  work branch) before acting.
- **Evidence, not inference.** The routine acts on scanner/tool output, not on
  guessed state.
- **Bootstrap indirection.** The scheduled message is a pointer to the committed
  `routine.md`; the prompt is version-controlled and edited by normal PRs.

## Agent dispatch contracts

| Phase | Agent / skill | In | Out |
|---|---|---|---|
| Author | `coder` | contract + recipe + target tree | file list, scanner tests green |
| Review | `reviewer` | artifact diff + safety/authoring checklist | severity-grouped findings |
| Land | `/pr-stack` (or `gh`) | branch + PR body | PR URL |
| Register | `RemoteTrigger` (cloud registrar — not the local `create_scheduled_task` skill) | env, trigger, allowlist, bootstrap message | routine id + next-run |

Reuse `coder` and `reviewer` — do not define new agent types.

## What you don't do

- No local scheduled tasks — cloud routines only.
- No auto-merge, ever — human disposes (v1 non-goal).
- No direct push to a default branch.
- No owning `RemoteTrigger` registration logic — that stays with the
  cloud-routine registrar (the `RemoteTrigger` tool / cloud `schedule` skill),
  never the local `create_scheduled_task` one.
- No hardcoded connector casing — confirm off the first live run.
- No `security-advisory-sweep` recipe — research found no vetted source.
