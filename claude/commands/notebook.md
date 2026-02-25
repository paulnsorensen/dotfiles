---
name: notebook
description: >
  Guided codebase review with persistent note-taking. Walk through code interactively,
  accumulate observations, and save structured notes to Serena memory. Use when manually
  exploring an unfamiliar codebase, auditing code quality, or building understanding
  before a refactor.
argument-hint: <area, module, or topic to review>
---

Guided codebase review session for: $ARGUMENTS

You are a review partner — I drive, you navigate and take notes.

## Session Setup

1. **Check for prior notes**: `list_memories` → look for `review-*` memories from previous sessions on this topic. If found, `read_memory` and present a brief summary: "Last time we covered X, Y, Z."

2. **Initialize the notebook**: Start an internal running document (do NOT write to disk yet). Format:

```
# Review: <topic>
Started: <date>

## Areas Covered
- (populated as we go)

## Notes
(accumulated observations)

## Questions
(things to investigate later)

## Action Items
(things to fix or change)
```

3. **Orient**: Use Serena (`get_symbols_overview`, `list_dir`) to give me a map of the area we're reviewing. Keep it concise — top-level structure, not deep dives.

## Review Loop

This is a **conversation**, not a checklist. Follow my lead:

- When I say **"show me X"** → use Serena to find and display relevant symbols/code
- When I say **"what does X do?"** → explain using symbol analysis, not speculation
- When I say **"note:"** or **"n:"** → add the observation to the notebook verbatim
- When I ask **"thoughts?"** → share your observations about the code we're looking at (quality, patterns, smells, coupling). Add these to the notebook too, marked as `[claude]`
- When I say **"notes"** or **"show notes"** → display the full accumulated notebook so far
- When I say **"questions"** → display just the Questions section
- When I say **"actions"** → display just the Action Items section

### Proactive note-taking

As we review, **suggest** notes when you spot:
- Code smells or violations of the complexity budget (functions > 40 lines, files > 300 lines, nesting > 3 levels)
- Coupling between modules that shouldn't know about each other
- Missing error handling at system boundaries
- Naming that doesn't match business concepts
- Dead code or unused exports

#### Sliced Bread architecture checks

When reviewing a project that follows Sliced Bread (see `claude/reference/sliced-bread.md`), also flag:
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

When I say **"save"**, **"done"**, or **"park"**:

1. **Display the final notebook** for my review
2. **Ask what to keep**: "Save everything, or want to trim first?"
3. **Write to Serena memory**: `write_memory("review-<slug>.md", <notebook content>)`
   - If a `review-<slug>` memory already exists, **merge** new notes into the existing one (append new sections, don't duplicate)
4. **Write to file** (optional): If I say "file too", write to `.claude/reviews/<slug>.md`
5. **Cleanup**: Check memory count with `list_memories`. If > 5, suggest which to prune

### Memory naming

Use `review-<slug>` where slug is derived from the topic:
- `/notebook orders module` → `review-orders-module.md`
- `/notebook auth flow` → `review-auth-flow.md`

## What This Is NOT

- Not `/code-review` — that's automated. This is human-driven.
- Not `/onboard` — that's a quick orientation. This is deep, sustained exploration.
- Not `/explain` — that's teaching. This is collaborative investigation with notes.

Begin the review session for: $ARGUMENTS
