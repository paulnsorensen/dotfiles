---
name: claude-local
model: sonnet
effort: medium
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(grep:*), Bash(test:*), Bash(touch:*), Bash(mkdir:*), Bash(printf:*), Glob
description: >
  Distill the user's global ~/.claude/CLAUDE.md into a gitignored
  CLAUDE.local.md for repos they contribute to but don't own — keeping only
  repo-relevant instructions and dropping personal flair. Use when the user
  says "set up CLAUDE.local", "scaffold local claude config", "drop my
  preferences in this repo", "I'm contributing and want my preferences
  applied", "claude-local.md", or invokes /claude-local. Also use proactively
  when they open an unfamiliar repo and want to start contributing.
---

# claude-local

Tailor the user's global Claude Code preferences to *this* project and write
them to a `CLAUDE.local.md` that the global gitignore covers. The output is a
slim, project-relevant overlay — not a copy of `~/.claude/CLAUDE.md`.

## Why this exists

The global `~/.claude/CLAUDE.md` is tuned for the user's own work —
personal communication style, owned-architecture rules, early-development
stances. When the user contributes to someone else's repo they want their
*engineering* preferences applied (coding principles, skill delegation)
without dragging in the personal flair or architectural opinions that don't
apply to a codebase they don't own.

Two non-negotiables:

1. **Never modify the project's own files.** No edits to the project's
   `CLAUDE.md`, `AGENTS.md`, or `.gitignore`. The point is a clean,
   gitignored personal overlay.
2. **Re-read the global on every invocation.** Don't hard-code the
   distillation in this skill — the user's preferences evolve. Read
   `~/.claude/CLAUDE.md` fresh each time so updates flow through.

## Workflow

1. **Locate the project root** — `git rev-parse --show-toplevel`. The output
   goes at the repo root, not the cwd. Not a git repo → tell the user and
   stop; `CLAUDE.local.md` only makes sense with a git boundary to scope it.
2. **Check for an existing `CLAUDE.local.md`.** If it exists, ask: refresh
   (regenerate from current global), keep (stop), or overwrite (treat as
   new). Don't silently clobber — the user may have hand-edited it.
3. **Detect project context** — languages and build/runtime tooling. Signal
   table in `references/distillation.md`.
4. **Read the global fresh** — `Read("~/.claude/CLAUDE.md")`. Do not trust
   any cached summary in this skill; the global file is the source of truth.
   No global file → stop and tell the user; there's nothing to distill.
5. **Distill** per the keep / language-gate / drop rules in
   `references/distillation.md`. In short: engineering principles and
   operational rules travel; language-specific style is gated on detected
   languages; personal flair, owned-architecture stances, and personal
   tooling layers are dropped.
6. **Write `CLAUDE.local.md`** using the template in
   `references/output.md` — compact (60-120 lines, never over 200), bullets
   not prose.
7. **Cover with the global gitignore** — never the project's `.gitignore`.
   Wiring script and failure handling in `references/output.md`; always
   verify with `git check-ignore`.
8. **Report** — full path written, which sections kept/dropped with one-line
   reasons for non-obvious calls, and which excludes file covers it
   (verified ignored).

## What this skill never does

- **Never** edit the project's `CLAUDE.md`, `AGENTS.md`, `.gitignore`, or
  any other tracked file in the contributed repo.
- **Never** include the cheese / Dune / Mad Max communication style in
  the output.
- **Never** add `CLAUDE.local.md` to the project's `.gitignore` — that
  would be a tracked change suggesting the project should know about
  this file. Use the user's global excludes.
- **Never** hard-code a distilled snapshot in this skill. The
  `~/.claude/CLAUDE.md` re-read is the whole point — it lets the user
  edit their global preferences and have updates flow through on the
  next invocation.

## Idempotency

Running this skill twice on the same repo with no global changes should
produce a `CLAUDE.local.md` byte-identical (modulo the timestamp on the
"distilled" line) to the first run. If the user has hand-edited the
file, ask before regenerating — don't clobber their tweaks.

## Edge cases

- **Multi-language monorepo:** include style/tooling for every language
  detected; mark which is primary if it's obvious from line count or
  directory weight.
- **Project's `CLAUDE.md` already in scope:** `CLAUDE.local.md` is
  *additive* — Claude Code reads both. The local overlay should not
  contradict the project's instructions; if there's a clash, the
  project wins. Note this at the top of the output file.
- **Repo is the user's own dotfiles or a project they own:** the user
  probably wants the full global preferences, not a distillation.
  Check whether the repo path matches `~/Dev/dotfiles` or contains a
  CLAUDE.md that already imports `~/.claude/CLAUDE.md` — if so, ask
  before generating; the overlay may be redundant.
