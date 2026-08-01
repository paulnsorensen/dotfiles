---
name: git-risk
model: haiku
effort: low
argument-hint: "[files or paths; blank = files changed vs origin/main]"
allowed-tools: Bash(git-file-risk:*), Bash(git diff:*), Bash(git rev-parse:*), Bash(git merge-base:*), Bash(git log:*), mcp__tilth__tilth_search
description: >
  Profile files by git-history risk — change hotspots, revert history,
  staleness, and danger comments — using the `git-file-risk` script. Use when
  the user asks "which of these files are risky", "is this a hotspot", "has
  this been reverted before", "where should review attention go", "how stable
  is this code", or invokes /git-risk. Run it before or alongside a review to
  decide where to look hardest. Do NOT use to find bugs (that is /age) or dead
  code (that is /ghostbuster) — this reports history risk only, never code
  findings.
---

# /git-risk — Git-History Risk Profile

History says where the bugs live. A change to a file five people touched this
month and reverted twice deserves more scrutiny than the same change to code one
person wrote six months ago and never came back to.

This skill reports that risk. It does not rank or produce code findings — it
tells a human (or a reviewer) where to spend attention.

**Target**: $ARGUMENTS (or the files changed vs `origin/main` if blank)

## 1. Resolve the file list

With `$ARGUMENTS`, use those paths. Without, take the changed set:

```bash
git diff --name-only "$(git merge-base HEAD origin/main)"...HEAD
```

Drop paths that no longer exist — `git-file-risk` reports untracked files as
`{"error":"not tracked"}`, which is noise, not signal.

## 2. Gather signals — one call

```bash
git-file-risk <file1> <file2> ...
```

Pass **every** file in a single invocation. If `git-file-risk` is not on PATH,
say so and stop — do not hand-roll `git log` equivalents; raw log output floods
context and the thresholds below are calibrated to this script's fields.

It returns one JSON object per file:

```json
[{"file":"src/a.ts","authors_90d":5,"changes_90d":12,"reverts":1,"last_change_days":3,"staleness":"3 days ago"}]
```

## 3. Interpret

| Signal | Threshold | Reading |
|---|---|---|
| `authors_90d` >= 4 | hotspot | Many hands — shared understanding is thin |
| `changes_90d` >= 8 | hotspot | Churn — the design may not have settled |
| `reverts` >= 1 | regression risk | This file has broken something before |
| `last_change_days` < 14 | recently rewritten | Fresh code, unproven in production |
| `last_change_days` > 180 | stable | Old and quiet — a change here is unusual |

**High** = hotspot (>= 4 authors AND >= 8 changes in 90d) or any revert history.
**Elevated** = one hotspot signal alone, or rewritten inside two weeks.
**Low** = 1–2 authors, < 3 changes in 90d, untouched for > 3 months.

## 4. Danger comments

One `tilth_search` (regex, scoped to the file set) for authors who already left a
warning: `DO NOT CHANGE|DO NOT EDIT|fragile|HACK|FIXME|XXX`. Cite `file:line`.
A danger comment raises a file one band regardless of its numbers.

## 5. Report

```
## Git-History Risk — <scope>
**Assessment**: <"Stable — no risk signals" or "N signals across M files">

| File | Risk | Authors (90d) | Changes (90d) | Last touched | Signals |
|---|---|---|---|---|---|
| src/hot.ts | high | 5 | 12 | 3 days ago | hotspot, 1 revert |
| src/calm.ts | low | 1 | 1 | 7 months ago | stable |

### Warnings
- `src/hot.ts:88` — "DO NOT CHANGE — ordering matters" (added with the revert)

### Where to look hardest
1. <file> — <one line, tied to a signal above>
```

Sort the table by risk, descending. Keep the whole report under ~1500 chars.

## What This Skill Never Does

- Emit numeric score modifiers. The old `/age` orchestrator consumed those; it
  no longer exists, and the arithmetic died with it. Report bands and evidence.
- Flag bugs, architecture, or complexity — history is the only input.
- Modify files.
- Judge the change itself. "This file is risky" is not "this diff is wrong".

## Gotchas

- **Mixed windows**: `git-file-risk` measures `authors_90d`/`changes_90d` over 90
  days but counts `reverts` across all history. A quiet file with an ancient
  revert still reads as regression risk — say when the revert was.
- **Shallow clones** truncate history and make everything look new. Check
  `git rev-parse --is-shallow-repository` before trusting low counts.
- **Renames**: `git log -- <path>` does not follow renames, so a recently moved
  file looks brand new. Confirm with `git log --follow` before calling it fresh.
- **Revert detection is grep-based** (`--grep=revert -i`), so it also matches a
  commit that merely mentions reverting. Read the subject before reporting it.
- **Bot commits** (renovate, dependabot) inflate author and change counts. Name
  them rather than letting them manufacture a hotspot.
