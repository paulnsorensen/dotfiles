# Cheese-flow Migration Plan

## Context

Recent commits (`74a1cf6`, `f5af359`) pointed dotfiles at the standalone
`~/Dev/cheese-flow` plugin and delegated `trace` / `chisel` / `research` to
its `cheez-search` / `cheez-write` / `cheez-read` / `research` skills. Cheese-
flow has since shipped more (mold, 8-dim age, cook flow, .cheese runtime).

The migration is partial: live duplicate skills remain, several agent files
still narrate workflows around deleted skills, and the flagship `/fromage`
and `/fromagerie` pipelines have no successor path documented even though
cheese-flow now ships the primitives (`mold`, `cook`, `age`, `cleanup`,
`research`) they would compose into.

This plan turns the cleanup into a sequenced migration that ends with
dotfiles owning only harness-coupled / personal-env code, and cheese-flow
owning the portable engineering workflow.

## PR Scope (this cycle)

One PR ships **Phase 1 + Phase 2 + this plan file**:

1. Delete the live duplicate skills/commands (Phase 1).
2. Scrub the stale `trace` / `chisel` / `mcp__tilth__*` references the prior
   migration left behind (Phase 2).
3. Commit this plan into the repo at
   `/Users/paul/Dev/dotfiles/claude/reference/cheese-flow-migration.md` so
   the later phases have a tracked source of truth (`.claude/` is
   gitignored; `claude/reference/` is the dotfiles home for in-tree
   reference docs).

Phases 3 (`/fromage` replacement), 4 (`/fromagerie` replacement), and 5
(remaining migration tiers) are described in detail below but execute in
their own PRs.

## Phase 1 — Delete live duplicates

Cheese-flow already ships these. Dotfiles copies are obsolete.

| dotfiles path | cheese-flow replacement | action |
|---|---|---|
| `claude/skills/age/SKILL.md` | `cheese-flow:age` (8-dim, sidecar JSON) | **delete dir** |
| `claude/skills/gh/SKILL.md` | `cheese-flow:gh` | **delete dir** |
| `claude/skills/merge-resolve/SKILL.md` | `cheese-flow:merge-resolve` | **delete dir** |
| `claude/commands/age.md` (16-line shim) | `cheese-flow:age` (richer command) | **delete file** |

Then update the catalog/delegation tables to point at the cheese-flow
namespace so `/cheese-flow:age` is the documented entry point:

- `claude/CLAUDE.md` — Skill Delegation table rows for code/content search,
  read code, file editing, GitHub ops, merge-resolve; Workflow table Review
  row.
- `claude/README.md` — top-level catalog.

Note: leaving `/age`, `/gh`, `/merge-resolve` callers without a local entry
means they only resolve to the prefixed `cheese-flow:*` skills. That's fine
— the prefix is short and matches the existing `cheese-flow:cheez-*`
convention.

## Phase 2 — Scrub stale references

Live broken references to deleted `trace` / `chisel` skills:

- `claude/agents/fromage-age-arch.md:27` — lists `trace` as primary tool
- `claude/agents/fromage-age-arch.md:47` — example "Verified via trace"
- `claude/agents/fromage-age-encap.md:36` — `trace` for import patterns
- `claude/agents/fromage-age-encap.md:59` — example "trace shows import path"
- `claude/agents/fromage-age-encap.md:66` — "trace the full import chain"
- `claude/agents/fromage-fort.md:120` — "Implement the fix using **chisel**"
- `claude/skills/settings-clean/SKILL.md:163,167,178,182` — hook-redirect
  table recommends `Skill(chisel)` and `Skill(trace)`

Replace `trace` → `cheese-flow:cheez-search` (or LSP `findReferences` for
import-graph work). Replace `chisel` → `cheese-flow:cheez-write`.

Skill cross-references that should now name `cheese-flow:age`:

- `claude/skills/de-slop/SKILL.md:175`
- `claude/skills/ghostbuster/SKILL.md:121`
- `claude/skills/spec-verify/SKILL.md:14,291`
- `claude/skills/xray/SKILL.md:469`

(`claude/skills/gh/SKILL.md:14,132` resolves with the deletion in Phase 1.)

Stale MCP permissions now that cheese-flow owns tilth via plugin scope:

- `claude/settings.json:78` — `mcp__tilth__*` should become
  `mcp__plugin_cheese-flow_tilth__*` (or be removed if the plugin allowlist
  already covers it).
- `claude/profiles/*/settings-merge.json` — audit each profile and rewrite
  any unprefixed `mcp__tilth__*` entries with the plugin prefix. The
  `rtkonly` profile is the most likely candidate per `CLAUDE.md` notes.

## Phase 3 — Replace `/fromage` (next PR)

Goal: dotfiles stops owning the implementation pipeline; the
`/cheese-flow:fromage` command becomes the canonical entry point and
composes cheese-flow primitives that already exist.

### Move to cheese-flow

Source files to move from `claude/` (dotfiles) into `~/Dev/cheese-flow/`:

- `commands/fromage.md` (23K) → `commands/fromage.md`
- `agents/fromage-cook.md` → `agents/fromage-cook.md.eta`
- `agents/fromage-press.md` → `agents/fromage-press.md.eta`
- `agents/fromage-curdle.md` → `agents/fromage-curdle.md.eta`
- `agents/fromage-culture.md` → `agents/fromage-culture.md.eta`
- `agents/fromage-pasteurize.md` → `agents/fromage-pasteurize.md.eta`
- `agents/fromage-wire.md` → `agents/fromage-wire.md.eta`
- `agents/fromage-fort.md` → `agents/fromage-fort.md.eta`

### Delete + reroute in cheese-flow

- The six `fromage-age-*` review agents (safety/arch/encap/yagni/history/spec)
  are made redundant by the cheese-flow eight-dim `age-*` agents
  (correctness/security/complexity/encapsulation/spec/precedent/deslop/
  assertions). **Delete the fromage-age-* family**; rewrite the moved
  `commands/fromage.md` Phase 8 (review) to delegate to `cheese-flow:age`
  and Phase 9 (cleanup) to `cheese-flow:cleanup`.
- The `culture-*` agents (`culture-context7`, `culture-lsp`, `culture-tokei`)
  move alongside `fromage-culture.md.eta` since they are exploration
  sub-agents.

### Delete from dotfiles

After the move + reroute lands in cheese-flow, remove from dotfiles:

- `claude/commands/fromage.md`
- `claude/agents/fromage-*.md` (every `fromage-` agent including the now-
  redundant `fromage-age-*` family)
- `claude/agents/culture-*.md`
- Any remaining stale references in `claude/CLAUDE.md` Workflow table.

### Verification

- `/cheese-flow:fromage <task>` runs end-to-end on a small change set.
- Cheese-flow `just build` is green after the move.
- `rg -n 'fromage-' claude/` returns zero matches in dotfiles.

## Phase 4 — Replace `/fromagerie` (next PR after Phase 3)

`/fromagerie` decomposes specs into atoms, dispatches parallel worktree
agents, and consolidates into PRs. Cheese-flow does not have an equivalent;
the closest piece is the `cook` flow (single-atom).

### Move to cheese-flow

- `commands/fromagerie.md` (18K) → `commands/fromagerie.md`
- `agents/fromagerie-decomposer.md` → `agents/fromagerie-decomposer.md.eta`
- `agents/fromagerie-merger.md` → `agents/fromagerie-merger.md.eta`
- `agents/fromagerie-slicer.md` → `agents/fromagerie-slicer.md.eta`

### Splits — keep harness-specific glue in dotfiles

`/fromagerie` invokes `/cheese-convoy`, `/move-my-cheese`, and `ccw-init`
(the worktree harness). These stay in dotfiles. Cheese-flow's
`/cheese-flow:fromagerie` produces the worktree manifest + atoms; dotfiles'
`/cheese-convoy` consumes it. Define the manifest schema in the moved
`commands/fromagerie.md` so the boundary is explicit.

### Delete from dotfiles

- `claude/commands/fromagerie.md`
- `claude/agents/fromagerie-*.md`

Keep: `commands/cheese-convoy.md`, `commands/move-my-cheese.md`,
`commands/worktree*.md`, `agents/worktree-triage.md` — these all assume
Paul's `~/Dev/.worktrees` layout and Claude Code Seatbelt sandboxing.

### Verification

- `/cheese-flow:fromagerie <spec>` produces a manifest that `/cheese-convoy`
  consumes without modification.
- A throwaway 3-atom spec runs through Phase 3 + Phase 4 end-to-end.

## Phase 5 — Remaining migration tiers (subsequent PRs)

Tier A — drop-in (no harness coupling), one PR per tier or per skill:

- `commit`, `diff`, `de-slop`, `tdd-assertions`
- `nih-audit` + `agents/nih-scanner.md`
- `ghostbuster` + `agents/ghostbuster.md`
- `spec-verify`, `version-doctor`, `lint`, `lookup`, `fetch`, `self-eval`
- `skill-improver` + `commands/skill-improver.md`
- `agents/ricotta-reducer.md` + `commands/simplifier.md`
- `agents/roquefort-wrecker.md` + `commands/wreck.md`
- `agents/whey-drainer.md` + `commands/test.md`
- `agents/cheese-factory.md` + `commands/onboard.md`

Tier B — already covered by Phases 3+4.

Tier C — split (logic moves, harness glue stays):

- `git-hygiene` (rule logic portable; PreToolUse hook config stays)
- `make` (runner portable; bash-guard hook stays)
- `xray` (verification logic portable; harness event-loop glue stays)

Stays in dotfiles permanently:

- `worktree`, `wt-git`, `commands/worktree*.md` — `ccw-init` + Seatbelt
- `session-analytics` + `agents/skill-analytics-*.md` — JSONL log path
- `settings-clean` — operates on `~/.claude/settings.json`
- `lsp` — diagnostic for LSP plugins in `claude/plugins/registry.yaml`
- `scout` — already a thin pointer + eza listings
- `prek` — heavy Claude Code hook integration
- `justfile` — personal build-tool preference
- `respond`, `commands/respond.md`, `copilot-*` commands,
  `move-my-cheese`, `cheese-convoy` — wired to Paul's gh + PR-stash habits
- `commands/agents.md`, `setup-perms.md`, `pull.md` — harness lifecycle
- `ralphify-spec` — uses `rw` shortcut + `ralphify` binary
- `test-sandbox`, `tui-design`
- `agents/worktree-triage.md` — assumes `~/Dev/*/.worktrees/*` layout

## Critical Files (this PR only)

- `/Users/paul/Dev/dotfiles/claude/reference/cheese-flow-migration.md` — **new**, this plan
- `/Users/paul/Dev/dotfiles/claude/skills/{age,gh,merge-resolve}/SKILL.md` — **delete**
- `/Users/paul/Dev/dotfiles/claude/commands/age.md` — **delete**
- `/Users/paul/Dev/dotfiles/claude/agents/fromage-age-arch.md` — scrub `trace`
- `/Users/paul/Dev/dotfiles/claude/agents/fromage-age-encap.md` — scrub `trace`
- `/Users/paul/Dev/dotfiles/claude/agents/fromage-fort.md` — scrub `chisel`
- `/Users/paul/Dev/dotfiles/claude/skills/settings-clean/SKILL.md` — scrub `Skill(trace)` / `Skill(chisel)` lines 163/167/178/182
- `/Users/paul/Dev/dotfiles/claude/skills/{de-slop,ghostbuster,spec-verify,xray}/SKILL.md` — `/age` → `/cheese-flow:age`
- `/Users/paul/Dev/dotfiles/claude/CLAUDE.md` — Skill Delegation + Workflow tables
- `/Users/paul/Dev/dotfiles/claude/README.md` — catalog
- `/Users/paul/Dev/dotfiles/claude/settings.json` — `mcp__tilth__*` → `mcp__plugin_cheese-flow_tilth__*`
- `/Users/paul/Dev/dotfiles/claude/profiles/*/settings-merge.json` — same MCP rewrite

## Reuse — existing helpers in cheese-flow

- `cheese-flow:cheez-search` (replaces `trace`)
- `cheese-flow:cheez-write` (replaces `chisel`)
- `cheese-flow:cheez-read` (replaces raw `cat`/`Read` for code)
- `cheese-flow:age` (replaces dotfiles `/age`)
- `cheese-flow:gh`, `cheese-flow:merge-resolve` (replace dotfiles namesakes)
- `cheese-flow:research` via `/briesearch` (replaces deleted `/research`)
- `cheese-flow:cleanup` (mechanical sidecar apply)
- `cheese-flow:mold`, `cheese-flow:cook` (peers of dotfiles `/spec`,
  composable into the moved `/fromage`)

## Verification (this PR)

1. `dots sync` rebuilds symlinks cleanly.
2. Fresh Claude Code session in this repo: available-skills lists
   `cheese-flow:age`, `cheese-flow:gh`, `cheese-flow:merge-resolve` and no
   unprefixed duplicates.
3. `rg -nE '\b(trace|chisel)\b' claude/agents claude/skills claude/commands`
   returns zero matches.
4. `rg -n 'mcp__tilth__' claude/settings.json claude/profiles` returns zero
   matches; only `mcp__plugin_cheese-flow_tilth__*` remains.
5. `/cheese-flow:age` runs (or fails fast on the documented Claude Code
   version check).
6. `prek run --all-files` is green; `dots test` is green.
7. The committed plan file at `claude/reference/cheese-flow-migration.md`
   matches the contents at `~/.claude/plans/read-the-latest-from-parallel-
   wilkes.md` (this file).
