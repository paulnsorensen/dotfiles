---
name: work-recovery
model: sonnet
effort: medium
description: >
  Reconstruct what a past coding-agent session was doing so you can resume it —
  goal, files touched, last verified state, and the next step — by querying the
  session logs. Use when the user says "what was I working on", "recover that
  session", "reconstruct where I left off", "resume my last session", "what did
  that session change", "rebuild context from logs", or invokes /work-recovery.
  Report-only — it never scores or judges. Do NOT use for usage scoring (that is
  /skill-improver, /tool-efficiency, /prompt-analytics) or one-off interactive log queries
  (that is /session-analytics).
allowed-tools: Read, Agent, Bash, Write(.cheese/notes/**)
---

# work-recovery

Reconstruct a past session's working state from the logs so a fresh agent (or
the user) can resume without re-reading the transcript. **Report-only**: it
reconstructs and presents; it does NOT score, rank, or recommend.

## Input

A target session: a `sessionId`, a project/branch, or "my last session". If
ambiguous, list recent candidate sessions (via the `session-shape` pack) and ask
which one. Optional harness filter (`all` default).

Optional flag `--wheypoint`: opt into write mode. Without it, `/work-recovery`
is byte-identical to today — it prints briefs and writes nothing. With it, each
assembled brief is also persisted as a resumable wheypoint note (see
[`## Write mode`](#write-mode)).

## Owned domains

Two analytics packs under `references/`:

| Domain | Pack | What it surfaces |
|--------|------|------------------|
| session-shape | `session-shape.md` | Recent sessions, timeline, size — for picking the target |
| work-recovery | `work-recovery.md` | Goal, files touched, last verified state, next step — for the chosen session |

## Protocol

1. **Ingest** — `python3 ~/Dev/dotfiles/skills/session-analytics/scripts/ingest.py`
   (1-hour TTL). Best-effort.
2. **Fan out** — spawn **one parallel `duckdb-expert` per owned domain**
   (one-domain-per-spawn). Use `session-shape` first if the target is unknown,
   then `work-recovery` once a `sessionId` is chosen:

   ```
   spawn duckdb-expert "Run analytics pack work-recovery/references/<domain>.md for target {SESSION}. harness={HARNESS}"
   ```

3. **Collect** the digests.
4. **Reconstruct** — assemble the recovery brief below. No scoring, no
   calibration tags, no recommendations — just the reconstructed state.
5. **Persist (only with `--wheypoint`)** — write each brief to
   `.cheese/notes/<slug>.md` per [`## Write mode`](#write-mode). Without the flag,
   skip this step entirely and write nothing.

## Output (recovery brief)

```
## Session Recovery: {SESSION}

- **Project / branch:** <cwd> @ <branch>  ·  Harness: <harness>
- **Span:** <first_seen> → <last_seen>  (<n> entries)

### Goal
<inferred from the opening prompt(s) — quote them>

### Files touched
| File | Reads | Edits/Writes |
|------|-------|--------------|

### Last verified state
<last test/build/git command and its outcome, if any>

### Next step
<the last incomplete action or the explicit "next" the session was heading toward>
```

## Write mode

`--wheypoint` is the **only** path on which this skill touches disk. Default
(no flag) writes nothing — the printed brief is the whole output.

With `--wheypoint`, after each recovery brief is assembled (step 4), persist it
as a resumable handoff note at `.cheese/notes/<slug>.md` so a fresh agent (or
`/cheese --continue`) can pick it up. One note per brief.

- **Slug:** derive from the recovered session — `recover-<project>-<short-sessionId>`
  (project = last path segment of the recovered session's project/branch; short id
  = first 8 chars of the sessionId). Keeps one-note-per-brief collision-resistant.
- **Schema:** the canonical wheypoint handoff header (identical to easy-cheese
  `/wheypoint`), then the brief itself as the document. Provenance is auto-filled
  **from the recovered session, never the live one**:

  ```markdown
  status: ok
  next: hold
  artifact: none
  session: <harness>:<recovered-sessionId>   # optional; the reconstruction target
  git: <recovered-branch>                     # optional; branch from the session's log (historical short-sha is not in the logs — omit the @<sha>)
  created: <recovered-session last_seen, UTC ISO-8601>   # optional; the session's last-active time
  <one-line orientation: what the recovered session was doing and where it stopped>

  ## Document

  <the recovery brief verbatim: Session Recovery / Goal / Files touched / Last verified state / Next step>
  ```

  All four provenance fields are optional and additive (session / git / created /
  parents, in that order, between `artifact:` and the orientation line); omit any
  the session cannot supply. Sweep-written notes carry no `parents:` — they are
  reconstructed from logs, not forked or joined.
- **`next: hold` is mandatory** for swept notes: reconstruction infers a *possible*
  next step but a human picks the resume direction, so `/cheese --continue` must
  restore orientation and dispatch nothing. Never emit a bare actionable `next:`
  on a swept note.

After writing, print the note's path so the user can resume with
`/cheese --continue <slug>`.

## What this skill never does

- Score, rank, or calibrate — it is report-only.
- Recommend improvements — that is the judgment skills' job.
- Run more than one domain per `duckdb-expert` spawn.
- Modify any files **except** under `--wheypoint`, whose sole write is the
  `.cheese/notes/<slug>.md` handoff note described in [`## Write mode`](#write-mode).
  The default (no-flag) run writes nothing.

## Gotchas

- "Goal" is inferred from the first user prompt(s); quote them rather than
  paraphrase so the user can correct a wrong inference.
- "Last verified state" depends on the session actually having run a test/build
  command — if none, say so plainly rather than guess.
- codex/opencode sessions lack Claude's Skill/Agent entries; reconstruct from
  tool_uses (file paths, bash commands) instead.
