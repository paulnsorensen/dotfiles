---
name: notebook
description: >
  Guided codebase review with persistent note-taking. Walk through code interactively,
  accumulate observations, and save structured notes to a file. Use when manually
  exploring an unfamiliar codebase, auditing code quality, or building understanding
  before a refactor.
argument-hint: <area, module, or topic to review>
---

Guided codebase review session for: $ARGUMENTS

You are a review partner — I drive, you navigate and take notes.

## Session Setup

1. **Check for prior notes**: Look for an existing notebook file at `.context/notebooks/<slug>.md`. If found, read it and present a brief summary: "Last time we covered X, Y, Z. Picking up where we left off."

2. **Initialize the notebook**: Create (or resume) the notebook file at `.context/notebooks/<slug>.md`. Derive the slug from the topic:
   - `/notebook orders module` → `.context/notebooks/orders-module.md`
   - `/notebook auth flow` → `.context/notebooks/auth-flow.md`

   Initial format:

```markdown
# Review: <topic>
Started: <date>
Last updated: <date>

## Areas Covered
- (populated as we go)

## Notes
(accumulated observations)

## Questions
(things to investigate later)

## Action Items
(things to fix or change)
```

3. **Orient**: Use Serena (`get_symbols_overview`, `list_dir`) or Glob/Read to give me a map of the area we're reviewing. Keep it concise — top-level structure, not deep dives.

## Review Loop

This is a **conversation**, not a checklist. Follow my lead:

- When I say **"show me X"** → use Serena to find and display relevant symbols/code
- When I say **"what does X do?"** → explain using symbol analysis, not speculation
- When I say **"note:"** or **"n:"** → add the observation to the notebook verbatim
- When I ask **"thoughts?"** → share your observations about the code we're looking at (quality, patterns, smells, coupling). Add these to the notebook too, marked as `[claude]`
- When I say **"notes"** or **"show notes"** → display the full accumulated notebook so far
- When I say **"questions"** → display just the Questions section
- When I say **"actions"** → display just the Action Items section

**Write to the notebook file incrementally** — don't wait until the end. Each time a note is added, append it to the file so nothing is lost if the session ends unexpectedly.

### Proactive note-taking

As we review, **suggest** notes when you spot:
- Code smells or violations of the complexity budget (functions > 40 lines, files > 300 lines, nesting > 3 levels)
- Coupling between modules that shouldn't know about each other
- Missing error handling at system boundaries
- Naming that doesn't match business concepts
- Dead code or unused exports

#### Sliced Bread architecture checks

When reviewing a project that follows Sliced Bread (see `.claude/reference/sliced-bread.md`), also flag:
- **Cross-slice imports**: code reaching into another slice's internals instead of importing from the index/barrel
- **Impure models**: domain models importing ORM, framework, or adapter code
- **Reverse dependencies**: slices depending on each other without events
- **Common pollution**: `common/` importing from sibling slices (it must be a leaf)
- **Premature structure**: folders/facades created before a file is actually crowded
- **Missing crust**: slice has no index/barrel file exposing its public API

Frame suggestions as: "Worth noting: ..." — I'll confirm or dismiss.

### Navigation shortcuts

| I say | You do |
|-------|--------|
| "up" | Go to the caller / parent module |
| "down" | Go deeper into the current symbol |
| "next" | Move to the next sibling symbol/file |
| "refs" | Show who references the current symbol |
| "back" | Return to the previous thing we were looking at |

## Saving Notes

Notes are saved incrementally to `.context/notebooks/<slug>.md` throughout the session.

When I say **"done"** or **"wrap up"**:

1. **Update the `Last updated` date** in the notebook header
2. **Display a summary**: areas covered count, notes count, open questions, action items
3. **Offer next steps**: "Want to turn any action items into GitHub issues?"

### File location

- `.context/` is gitignored — notebooks stay local to the workspace
- To share a notebook, copy it somewhere trackable: "Move to `.claude/reviews/<slug>.md`"
- To load into Claude's auto-memory for future sessions: "Copy key findings to memory"

## What This Is NOT

- Not `/code-review` — that's automated. This is human-driven.
- Not `/onboard` — that's a quick orientation. This is deep, sustained exploration.
- Not `/explain` — that's teaching. This is collaborative investigation with notes.

Begin the review session for: $ARGUMENTS
