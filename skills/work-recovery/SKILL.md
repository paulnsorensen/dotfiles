---
name: work-recovery
model: sonnet
description: >
  Reconstruct what a past coding-agent session was doing so you can resume it —
  goal, files touched, last verified state, and the next step — by querying the
  session logs. Use when the user says "what was I working on", "recover that
  session", "reconstruct where I left off", "resume my last session", "what did
  that session change", "rebuild context from logs", or invokes /work-recovery.
  Report-only — it never scores or judges. Do NOT use for usage scoring (that is
  /skill-improver, /tool-efficiency, /prompt-analytics) or one-off interactive log queries
  (that is /session-analytics).
allowed-tools: Read, Agent, Bash
---

# work-recovery

Reconstruct a past session's working state from the logs so a fresh agent (or
the user) can resume without re-reading the transcript. **Report-only**: it
reconstructs and presents; it does NOT score, rank, or recommend.

## Input

A target session: a `sessionId`, a project/branch, or "my last session". If
ambiguous, list recent candidate sessions (via the `session-shape` pack) and ask
which one. Optional harness filter (`all` default).

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

## What this skill never does

- Score, rank, or calibrate — it is report-only.
- Recommend improvements — that is the judgment skills' job.
- Run more than one domain per `duckdb-expert` spawn.
- Modify any files.

## Gotchas

- "Goal" is inferred from the first user prompt(s); quote them rather than
  paraphrase so the user can correct a wrong inference.
- "Last verified state" depends on the session actually having run a test/build
  command — if none, say so plainly rather than guess.
- codex/opencode sessions lack Claude's Skill/Agent entries; reconstruct from
  tool_uses (file paths, bash commands) instead.
