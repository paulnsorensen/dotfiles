# Agent vs Skill: when a behaviour earns its own context

The cheese ecosystem expresses the same review/quality behaviours twice — as a **sub-agent** (in this repo's `agents/registry.yaml`) and often as a paired **skill** (e.g. `/ghostbuster`, `/nih-audit`, `/wreck`, `/de-slop`). This looks like duplication. Mostly it isn't — the two sit on orthogonal axes by design. This page records the decision criteria and the cross-repo constraint that govern any cleanup of the cheese agents, plus the deferred backlog from the 2026-05 registry review.

See [[agents-dir]] for the registry mechanics and [[agent-profile]] for the renderer.

## The two axes

A behaviour is *not* redundant across an agent and a skill when it differs on either axis:

**Axis 1 — agent-tier vs skill-tier (isolation).** A sub-agent earns its own context window for exactly three reasons:
1. **Parallel fork** — N specialists run at once (the `reviewer` forks `fromage-*` during `/age`; per-curd workers in `/cheese-factory`).
2. **Bulky-evidence isolation** — it consumes a flood of tool output (ast-grep, Serena, full test logs, git history) and hands back a small (~2 KB) digest, keeping the noise out of the orchestrator. (`nih-scanner` ~30 calls, `whey-drainer` test output, `duckdb-expert` query dumps, `explorer`.)
3. **Read-only / write-isolated fork target** — the orchestrator can't inline it safely (`ricotta-reducer`'s no-write boundary; `roquefort-wrecker` + `fromage-fort` write in isolation).

If none of those hold — the behaviour is a linear procedure the orchestrator runs in its own context — it belongs in a **skill**. "Migrate an agent to a skill" = "this never actually needed isolation." The clearest case found: a thin-wrapper skill that makes a single agent call with no fan-out and no context isolation beyond a `$TMPDIR` file (the `/ghostbuster` skill → `ghostbuster` agent relationship).

**Axis 2 — detect-only vs detect-and-fix.** Review agents and `/age` dimensions *find*; skills like `/de-slop` *fix*. `ricotta-reducer` (detect, no-write) vs `/de-slop` (fix) is complementary, not redundant — the no-write boundary is architectural (`disallowedTools`), not incidental.

A pair is genuine duplication only when it collapses to a *single point on both axes*: single-shot, no isolation, same detect-or-fix mode.

## The cross-repo ownership constraint (critical)

This is the constraint that governs what is even *doable* in dotfiles:

- **dotfiles owns**: the agent *bodies* (`agents/agent_definitions/` + `agents/registry.yaml`), the **local** skills (`/ghostbuster`, `/nih-audit`, `/de-slop`, `/scout`, … the `skills/` tree), and `claude/commands/` (`/wreck`, `/test`, `move-my-cheese`, `cheese-convoy`).
- **The external easy-cheese plugin owns** (installed via `npx skills add`, lives at `~/.claude/skills/`, source at `~/Dev/cheese-flow/`): the pipeline skills — `/age`, `/cook`, `/press`, `/cure`, `/affinage`, `/mold`, `/cheese`, etc.

Consequence: editing an **agent body** (scoring vocab, a bugfix, a rename) is dotfiles-local. But changing an agent's *output contract* can break a consumer **across the repo boundary** — so every "modernize" needs to confirm whether the easy-cheese consumer parses the field. And "merge agent into skill" is only doable here when the *skill* is dotfiles-local (e.g. `/ghostbuster`); merging into `/age` or `/affinage` is a cross-repo (easy-cheese) change.

## Scoring vocab: self-filter vs wire-protocol

Several agents predate the current severity-tier model and emitted 0-100 confidence scores (flagged in `skills/session-analytics/references/calibration.md`). Whether modernizing to severity tiers (blocker/high/medium/low + `<certain>`/`<speculative>`) is safe depends on whether the *consumer parses the number*:

- **Self-filter only (safe to modernize)** — the score is an internal "surface ≥50" gate; the consumer reads finding *prose*. `fromage-age-arch`, `ricotta-reducer`, `roquefort-wrecker`, `fromage-fort`. These were modernized in PR #253.
- **Wire-protocol (coupled — do NOT casually modernize)** — `fromage-age-history` emits arithmetic modifiers (+10/+5/−5, capped ±15) the `/age` orchestrator applies *numerically* to cross a threshold; `fromage-secaudit` (formerly `fromage-pasteurize`) uses a ≥50 threshold + prints the score in its output table the consumer reads.

When modernizing a body, leave legitimate *code-measurement* thresholds alone (e.g. `fromage-age-arch`'s "diverge by >15 lines/levels" measures code, not confidence).

## Deferred cleanup backlog (2026-05 review)

Verdicts from the per-agent + per-pair mapping. KEEPs confirmed; the open items:

- **ghostbuster → merge agent into the `/ghostbuster` skill** — the only genuine single-point collapse, but entangled: `ghostbuster` is *also* named as the deslop/dead-code fork target in `reviewer.md:11` + `registry.yaml`'s reviewer description, so a full merge must also strip it from the reviewer fork tier (the deslop dimension then relies on inline + `ricotta-reducer`). Deferred for that reason. Dotfiles-local when done.
- **fromage-age-history → collapse to `explorer` + the `git-file-risk` CLI** — fits the explorer pattern (read-only, 2-3 calls, structured digest), but its output is the arithmetic wire-protocol above and it's a parallel `/age` fork; collapsing touches `reviewer.md` and the `/age` fork behaviour. Partly cross-repo.
- **fromage-fort vs `/affinage`** — `/affinage` (easy-cheese) is a scope *superset* (CI, merge conflicts, `/melt`, `/age`, `/cure`) but does **not** spawn `fromage-fort`; `fromage-fort` keeps the BUG/CONVENTION/STYLE taxonomy + ASK tier + the parallel-spawn contract `move-my-cheese`/`cheese-convoy` rely on. Don't retire until those callers are audited. Cross-repo to resolve.
- **de-slop catalogue as single source of truth** — `/de-slop` (184-line + 5 language refs, dotfiles) and `/age`'s deslop dimension (5-line inline table, easy-cheese) duplicate the anti-pattern catalogue with no shared source; they can drift. Unifying = `/age` citing `/de-slop` → cross-repo.
- **`cheez-read` / `cheez-write` namespace sweep** — `cheese-flow:` → `easy-cheese:` was swept for `cheez-search` in PR #253; `cheez-read`/`cheez-write` remain (e.g. `fromage-fort.skills` at `registry.yaml`, `claude/README.md`). Dotfiles-local follow-up.

KEEP (isolation genuinely load-bearing): `explorer`/`researcher`/`reviewer`/`coder` (phase backbone), `nih-scanner`, `roquefort-wrecker`, `ricotta-reducer`, `fromage-pasteurize`/`secaudit`, `fromage-age-arch`, `whey-drainer`, `worktree-triage`. `/wreck` (adversarial, standalone) and `/press` (corrective, diff-scoped, pipeline-gated) are distinct phases — not redundant.

## Shipped from this review

- **PR #253** — `fromage-age-arch` bugfixes (namespace + `Write` disallow), `fromage-pasteurize` → `fromage-secaudit` rename (kills the `/pasteurize` skill name collision — the agent is a security/dep auditor, the skill is bug diagnosis; zero functional overlap), and the safe scoring modernization above.
- **PR #252** (sibling, skill-tier) — Claude skills render shared-only (the agent-tier analogue of the agent shared-only change in #248).
