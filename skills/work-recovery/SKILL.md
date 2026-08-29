---
name: work-recovery
model: sonnet
effort: medium
description: >
  Reconstruct what a past coding-agent session was doing — goal, files touched,
  last verified state, next step — so it can be resumed. Use for /work-recovery
  or "what was I working on".
allowed-tools: Read, Bash, Write(.cheese/notes/**)
---

# work-recovery

Report-only: reconstruct and present; never score, rank, or recommend.

Target: a `sessionId`, a project/branch, or "my last session". If ambiguous,
run `<skill-dir>/scripts/sessions.sh [project] [harness]` to list candidates
and ask which one. Then run `<skill-dir>/scripts/recover.sh <sessionId>` and
assemble the brief:

```
## Session Recovery: {SESSION}
- **Project / branch:** <cwd> @ <branch>  ·  Harness  ·  Span (<n> entries)
### Goal            — inferred from opening prompts; QUOTE them, don't paraphrase
### Files touched   — | File | Reads | Edits/Writes |
### Last verified state — last test/build/git command + outcome, or "none recorded"
### Next step       — last incomplete action or the explicit "next"
```

Judgment notes: a wrong goal inference must be correctable — quote the
prompts. No test/build command → say so plainly, don't guess. Codex/OMP
sessions lack Skill/Agent entries — reconstruct from tool_uses (paths and
shell commands).

## Write mode (`--wheypoint` only)

Without the flag, write nothing — the printed brief is the whole output. With
it, persist each brief to `.cheese/notes/recover-<project>-<sessionId[:8]>.md`
using the canonical wheypoint handoff header, then the brief verbatim:

```markdown
status: ok
next: hold
artifact: none
session: <harness>:<recovered-sessionId>   # optional
git: <recovered-branch>                    # optional; no @<sha> (not in logs)
created: <recovered last_seen, UTC ISO-8601>   # optional
<one-line orientation: what the session was doing and where it stopped>

## Document

<the recovery brief verbatim>
```

Provenance fields come from the *recovered* session, never the live one; omit
any the session cannot supply; no `parents:` on swept notes. `next: hold` is
mandatory — a human picks the resume direction. Print the note's path
(`/cheese --continue <slug>` resumes it).
