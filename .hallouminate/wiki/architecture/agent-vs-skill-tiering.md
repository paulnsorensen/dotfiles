# Agent vs Skill: when a behaviour earns its own context

The cheese ecosystem expresses the same review/quality behaviours twice — as a **sub-agent** (in this repo's `agents/registry.yaml`) and often as a paired **skill** (e.g. `/ghostbuster`, `/nih-audit`, `/wreck`, `/de-slop`). This looks like duplication. Mostly it isn't — the two sit on orthogonal axes by design. This page records the decision criteria and the cross-repo constraint that govern any cleanup of the cheese agents, the deferred backlog from the 2026-05 registry review, and the 2026-07-31 specialist removal that resolved most of it.

See [[agents-dir]] for the registry mechanics and [[agent-profile]] for the renderer.

## The two axes

A behaviour is *not* redundant across an agent and a skill when it differs on either axis:

**Axis 1 — agent-tier vs skill-tier (isolation).** A sub-agent earns its own context window for exactly three reasons:

1. **Parallel fork** — N specialists run at once (per-dimension `reviewer` lens workers in `/age` fan-out; per-curd workers in `/cheese-factory`).
2. **Bulky-evidence isolation** — it consumes a flood of tool output (ast-grep, full test logs, git history) and hands back a small (~2 KB) digest, keeping the noise out of the orchestrator. (`nih-scanner` ~30 calls, `whey-drainer` test output, `duckdb-expert` query dumps, `explorer`.)
3. **Read-only / write-isolated fork target** — the orchestrator can't inline it safely (`ghostbuster`'s no-write boundary; `roquefort-wrecker` writes in isolation).

If none of those hold — the behaviour is a linear procedure the orchestrator runs in its own context — it belongs in a **skill**. "Migrate an agent to a skill" = "this never actually needed isolation." The clearest case found: a skill that does a single spawn, with no fan-out and no isolation beyond a `$TMPDIR` digest (the `/ghostbuster` skill → `ghostbuster` agent relationship — the skill does inline Discovery + Spec/Doc-collection in Phases 1–2 before that one spawn, so it is not a thin wrapper).

**Axis 2 — detect-only vs detect-and-fix.** Review agents and `/age` dimensions *find*; skills like `/de-slop` *fix*. `ghostbuster` (detect, no-write) vs `/cure`-routed fixes is complementary, not redundant — the no-write boundary is architectural (`disallowedTools`), not incidental.

A pair is genuine duplication only when it collapses to a *single point on both axes*: single-shot, no isolation, same detect-or-fix mode.

## Agent bodies are not skill-preload shims (2026-07-31 audit)

A dispatch-side audit of the six surviving specialists asked: "if the skill spawned a generic read-only agent with the same prompt, what would be lost?" Verdict for all six: **body-is-essential** — each body carries procedure its dispatching skill never restates (ghostbuster's DEAD/ZOMBIE/GHOST/DORMANT protocol, nih-scanner's ast-grep pattern library, whey-drainer's framework-detection + output caps, duckdb-expert's DuckDB gotchas, roquefort-wrecker's attack phases, worktree-content-digest's default-branch algorithm). Only `duckdb-expert` uses a frontmatter `skills:` preload at all; the others carry zero preloads, so none is "just dumping a skill into context". The registry additionally contributes what a prompt cannot: enforced read-only tool grants (Codex `sandbox_mode = "read-only"` derivation), model tiering (haiku for whey-drainer/duckdb-expert/worktree-content-digest), and `maxTurns` caps. Several bodies (ghostbuster, nih-scanner, whey-drainer, worktree-content-digest) *could* migrate their static rubrics into skill reference files, but the tool-restriction and tier properties would need the registry regardless.

## The cross-repo ownership constraint (critical)

This is the constraint that governs what is even *doable* in dotfiles:

- **dotfiles owns**: the agent *bodies* (`agents/agent_definitions/` + `agents/registry.yaml`), the **local** skills (`/ghostbuster`, `/nih-audit`, `/de-slop`, … the `skills/` tree), and the `claude/workflows/` scripts (`age-fanout`, `cheese-factory`, `move-my-cheese`, …).
- **The external easy-cheese plugin owns** the pipeline skills — `/age`, `/cook`, `/press`, `/cure`, `/affinage`, `/mold`, `/cheese`, etc. These install to `~/.claude/skills/` via `npx skills add` (registry `paulnsorensen/easy-cheese`).

Consequence: editing an **agent body** (scoring vocab, a bugfix, a rename) is dotfiles-local. But changing an agent's *output contract* can break a consumer **across the repo boundary** — so every "modernize" needs to confirm whether the easy-cheese consumer parses the field. And "merge agent into skill" is only doable here when the *skill* is dotfiles-local (e.g. `/ghostbuster`); merging into `/age` or `/affinage` is a cross-repo (easy-cheese) change.

## Scoring vocab: self-filter vs wire-protocol (historical)

Several agents predated the current severity-tier model and emitted 0-100 confidence scores (flagged in `skills/session-analytics/references/calibration.md`). Whether modernizing to severity tiers (blocker/high/medium/low + `<certain>`/`<speculative>`) was safe depended on whether the *consumer parses the number*: self-filter-only scores (an internal "surface ≥50" gate, consumer reads prose) were safe to modernize (done in PR #253); wire-protocol scores (`fromage-age-history`'s arithmetic ±modifiers, `fromage-secaudit`'s printed ≥50 threshold) were coupled to the old `/age` orchestrator and could not be casually changed. The wire-protocol agents were removed with the old `/age` (see below); the principle stands for any future agent whose output another skill parses. When modernizing a body, leave legitimate *code-measurement* thresholds alone (they measure code, not confidence).

## 2026-07-31 specialist removal

The reduced `/age` (easy-cheese) plus the `age-fanout` workflow dispatch **only phase agents**: an `explorer` packet assembler, per-lens `reviewer` workers, and a cheap `verifier` role resolved through `agent-resolution.md` — no named specialists. That left five registry agents with zero dispatchers (verified across `~/.claude/skills/`, `skills/`, `claude/workflows/`, `bin/`), and they were removed:

- **`fromage-age-arch`, `fromage-secaudit`** — their dimensions (complexity, security) are now `reviewer` lenses reading `references/dimensions.md`. Secaudit's one non-duplicated part, the per-ecosystem audit-tool list (`npm audit`/`uv pip audit`/`cargo audit`/`govulncheck`) plus the unused/overweight/stdlib-replaceable dep checks, was folded into `/nih-audit` as Phase 0.4 rather than kept as a skill: it needs the `depManifest` that skill already builds, and dependency findings skip its library-research phases.
- **`fromage-age-history`** — `/age` SKILL.md states the reduced workflow "intentionally omits the git-history/precedent dimension"; its arithmetic-modifier wire-protocol had no consumer left. Its engine `bin/git-file-risk` and its interpretation tables were extracted into the dotfiles-local `/git-risk` skill (haiku/low), which reports **high/elevated/low bands** instead of ±modifiers — the arithmetic only ever meant something to the old `/age` orchestrator that consumed it. `/git-risk` is deliberately standalone: `age-fanout.js` was left untouched so history risk stays a human-invoked lens, not a hidden severity multiplier.
- **`fromage-fort`** — superseded by `/affinage`, which resolves a fresh read-only `reviewer` through the shared resolver. The old `move-my-cheese`/`cheese-convoy` *commands* that spawned it are archived (`archive/claude-commands/`); the current `move-my-cheese` workflow uses `coder`/`reviewer`.
- **`ricotta-reducer`** — deslop is a `reviewer` lens (per-language `deslop-*.md` refs in the age skill) plus `/de-slop` for fixes.

This resolved the 2026-05 backlog items for `fromage-age-history` (collapse obviated) and `fromage-fort` (caller audit came back empty). Removal sites: `agents/registry.yaml`, `agents/agent_definitions/`, the `agents:` selections in `chezmoi/.chezmoidata/{claude,codex}.yaml`, `tests/{sync-codex-sources,phase-agent-handoff}.bats`, `claude/README.md`.

## Remaining backlog

- **ghostbuster → merge agent into the `/ghostbuster` skill** — the old blocker (reviewer fork-tier entanglement) is gone: `reviewer.md` no longer names it. Now a clean dotfiles-local collapse if ever wanted; the 2026-07 audit notes its taxonomy is movable but the read-only grant is what `explorer` would have to supply.
- **de-slop catalogue as single source of truth** — `/de-slop` (dotfiles) and `/age`'s per-language `deslop-*.md` refs (easy-cheese) still duplicate the anti-pattern catalogue with no shared source. Unifying is cross-repo.
- **`cheez-read` / `cheez-write` naming residue** — remaining mentions live in `agents/lib/tool-reroute/io.js` deny-messages and `agents/hooks/registry.yaml` comments; harmless while those skills exist under `~/.agents/skills`.

KEEP (isolation genuinely load-bearing): `explorer`/`researcher`/`reviewer`/`coder` (phase backbone), `ghostbuster`, `nih-scanner`, `roquefort-wrecker`, `whey-drainer`, `duckdb-expert`, `worktree-content-digest`. `/wreck` (adversarial, standalone) and `/press` (corrective, diff-scoped, pipeline-gated) are distinct phases — not redundant.

## Shipped

- **2026-07-31** — the five-specialist removal above.
- **PR #253** — `fromage-age-arch` bugfixes (namespace + `Write` disallow), `fromage-pasteurize` → `fromage-secaudit` rename, and the safe scoring modernization above (all agents since removed).
- **PR #252** (sibling, skill-tier) — Claude skills render shared-only (the agent-tier analogue of the agent shared-only change in #248).
