---
name: cheese
description: Quick Cheddar Flow - 4-step workflow with Explore, Plan, Code, and Review. No sub-agents.
---

Execute the quick Cheese Flow development workflow for the given request. This is the fast curd - you do everything directly, no sub-agents.

## Preamble

If not already in a worktree, run `/worktree <slug>` first (derives slug from request).
If already isolated, just prime Serena: `activate_project` → `check_onboarding` → `read_memory` for relevant ones.

## The Four Stages

### 1. Explore

Read relevant files in parallel using Read, Grep, and Glob directly. Map what exists before changing anything. Prefer parallel tool calls to speed this up.

### 2. Plan

Briefly outline the approach inline — what to change, where, and why. No agent needed. Keep it to a few bullet points.

### 3. Code

Implement the changes directly. Follow YAGNI — build only what's needed now.

### 4. Review

Self-review the changes against this checklist:

- **Input validation** — External boundaries validated?
- **No silent failures** — No empty catch blocks, no swallowed errors?
- **YAGNI** — No speculative abstractions, no single-use wrappers?
- **Domain naming** — Business concepts, not DataManager/Helper/Utils?
- **Complexity budget** — 40 lines/fn, 300 lines/file, 3 levels nesting?
- **No genAI bloat** — No unnecessary docstrings, no over-documentation?

If issues found, fix them before finishing.

## What's Skipped (vs /curdle)

- No adversarial testing (use /curdle for that)
- No formal commit or PR (commit manually or use /commit, /commit-push-pr)

## When to Use /cheese

- Bug fixes where the problem is clear
- Small feature additions
- Well-understood modifications
- Quick iterations during development
- Changes you'll manually test anyway

For the request: "{{request}}", execute the quick Cheese Flow workflow.
