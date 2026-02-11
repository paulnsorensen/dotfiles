---
name: cheese
description: Execute abbreviated Cheddar Flow - quick 5-step workflow with Explore, Plan, Code, Simplify, and Light Review phases.
---

Execute the quick Cheese Flow development workflow for the given request. This is the fast curd - streamlined for rapid iteration when you're confident in the approach.

## Preamble — Isolate

Before starting, check if task isolation is needed:
- If already in a worktree (check `git worktree list` — current dir is under a worktree path, not the main repo root), skip this step.
- Otherwise, derive a slug from the request (lowercase, hyphens, no special chars) and run: `git worktree add .worktrees/<slug> -b claude/<slug>` then `cd` into it.
- If the worktree already exists for that slug, just `cd` into it.

## The Five Stages

1. **Explore** - Use gouda-explorer to understand current codebase context
2. **Plan** - Use brie-architect to create implementation strategy
3. **Code** - Use cheddar-craftsman to implement the plan precisely
4. **Simplify** - Use ricotta-reducer to distill the code to its essential form
5. **Review** - Use brie-architect for architectural sanity check

## What's Skipped (vs /curdle)

- No dedicated adversarial testing (roquefort-wrecker)
- No strict principle enforcement review (parmigiano-sentinel)
- No formal commit message crafting (manchego-chronicler)

## When to Use /cheese

- Bug fixes where the problem is clear
- Small feature additions
- Well-understood modifications
- Quick iterations during development
- Changes you'll manually test anyway

## Core Principles Still Apply

The workflow maintains Input Validation, Fail Fast, Loose Coupling, YAGNI, Real-World Models, and Immutable Patterns - just with less ceremony.

For the request: "{{request}}", execute the quick Cheese Flow workflow.
