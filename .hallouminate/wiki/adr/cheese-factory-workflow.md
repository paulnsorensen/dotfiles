# ADRs — cheese-factory-workflow

Decisions behind replacing `claude/workflows/curd-flock.js` with the spec-driven `/cheese-factory` workflow. Spec: durable corpus `specs/cheese-factory-workflow.md` (`~/.local/share/cheese/paulnsorensen-dotfiles/`).

## ADR-001: Real-skill phase agents over prompt-modeled phases  [status: accepted]

- **Context:** curd-flock approximated the cook/review phases with inline prompts + JSON schemas. The redesign mirrors the easy-cheese pipeline; prompt copies drift as the skills evolve.
- **Decision:** Each workflow phase agent invokes the real skill (`/cook <spec> --auto`, `/press`, `/age`, `/cure`, `/plate`) carrying ultracook's no-chain-forward directive; handoff slugs land in the curd worktree's `.cheese/`.
- **Alternatives:** Prompt-modeled (self-contained, no skill dependency, drifts); hybrid (mixed fidelity). Rejected for drift and inconsistency.
- **Consequences:** Exact easy-cheese behavior and durable handoffs; new dependency on Skill-tool availability inside workflow agents — gated by a pre-implementation smoke check, with prompt-modeled as the flagged fallback.

## ADR-002: Barrier plate overrides the never-push contract  [status: accepted]

- **Context:** curd-flock never pushed — it handed back branches. The user explicitly added plate/stack (opus) to the chain.
- **Decision:** One opus plate agent runs once after all curd chains: stacks clean `curd/<slug>` branches into a stacked-PR chain (ordinary PR in single-pass). Dirty curds (re-age still medium+) are excluded and reported. Plate never merges.
- **Alternatives:** Per-curd independent PRs (no stacking/ordering); prepare-don't-push (kept the old contract, user declined).
- **Consequences:** Unattended pushes/PRs from a workflow run; bounded by never-merge and dirty-curd exclusion.

## ADR-003: Reuse `mold.pyz curd-count` via agent-side Bash  [status: accepted]

- **Context:** Workflow scripts have no filesystem/Bash access; the fan-out decision needs curd-count's goal-counting.
- **Decision:** A cheap Resolve agent shells out to `mold.pyz curd-count` (and `artifact-path`) and returns structured JSON to the script.
- **Alternatives:** Reimplement goal-counting in JS inside the workflow (duplicate logic, drifts from mold's PARALLEL_THRESHOLD).
- **Consequences:** One canonical threshold shared with /mold//ultracook; adds a python3 + skill-bundle dependency for the Resolve agent.

## ADR-004: Per-curd mini-specs anchor the real skills  [status: accepted]

- **Context:** Real skills take a spec slug; N curds share one parent spec.
- **Decision:** The decomposer writes per-curd mini-specs (mold mini-spec schema) at `specs/<parent>--<curd>.md` via the resolver; single-pass mode uses the parent spec directly.
- **Alternatives:** Inline curd briefs in prompts (no durable anchor; press/age/cure would have nothing to read).
- **Consequences:** Whole chain per curd reads/writes against a durable spec; corpus gains derived spec files per run.

## ADR-005: File-overlapping curds merge instead of warn-and-proceed  [status: accepted]

- **Context:** curd-flock's overlap check was advisory (log a warning, fan out anyway) — a race window on shared files. ultracook folds shared-file curds back to linear.
- **Decision:** JS merges any file-overlapping curds into one curd (one worktree, combined brief); if merging leaves one curd, run single-pass.
- **Alternatives:** Warn-only (curd-flock behavior); abort the run on overlap.
- **Consequences:** Fan-out is always file-disjoint by construction; a heavily-coupled spec degrades gracefully to single-pass.

## ADR-006: Review moved from per-curd to a barrier whole-diff age  [status: accepted]

- **Context:** The shipped design aged each curd in isolation (cook→taste→press→age→cure→re-age per curd). Curds are file-disjoint (ADR-005) but behavior still composes — curd A and curd B can each review clean alone and break together. The union diff was reviewed by nobody. Per-curd age also cost N opus reviewers where one whole-diff pass suffices.
- **Decision:** The per-curd chain shrinks to cook→taste→press. A new **Integrate** barrier merges surviving `curd/*` branches into `integration/<parent>` (slug-sorted, `--no-ff`; a conflict excludes that curd with reason). The whole `origin/main...HEAD` diff is aged once; findings are routed to owning curds by file (disjointness makes routing deterministic), cures run in parallel per flagged curd, one re-merge + re-age pass follows, and still-dirty curds are excluded from plate. A global medium+ verdict with no per-curd routing marks all integrated curds dirty (fail-closed, never plate unreviewed findings).
- **Alternatives:** Keep per-curd age + add a second barrier age (max coverage, double review cost); per-curd age with per-curd fan-out (no cross-curd coverage, multiplies dispatches). Rejected for cost and coverage respectively.
- **Consequences:** Cross-curd interactions are reviewed; N−1 reviewer dispatches saved. Trade-off: the age barrier waits for all chains (loses the pipeline overlap the per-curd age had), and excluding a dirty curd at plate time means the plated set differs from the reviewed integration — reported, accepted.

## ADR-007: age-fanout child workflow with runtime skill-file pointers  [status: accepted]

- **Context:** `/age`'s scale-triggered fan-out mode (SKILL.md Seams 2–5) cannot run when `/age` executes inside a dispatched sub-agent — level-1 agents can't spawn sub-agents, so workflow-driven ages silently degraded to one inline reviewer. Workflow scripts CAN fan out; but reimplementing /age's dimension rubrics in workflow prompts is exactly the prompt-copy drift ADR-001 rejected.
- **Decision:** A shared child workflow `claude/workflows/age-fanout.js` (Packet → Review → Reconcile) implements Seams 2–4 with **zero copied review semantics**: agent prompts point at the deployed skill files (`~/.claude/skills/age/references/{packet,dimensions}.md`, `SKILL.md § Output`), which agents read at runtime — the dimension list itself is parsed live by the Packet agent, so a new dimension in easy-cheese flows through untouched. Parents call `workflow('age-fanout', {worktree_path, range, slug, route_curds?})` and gate on /age's scale threshold (>15 files / ~800 lines); both parents fall back to a single-reviewer `/age` run if the child is unavailable. cheese-factory gates on integrate-reported diff stats; move-my-cheese gates on recon's `gh pr view` stats AND only when the age would be a full review (no marker, or dirty marker) — clean-marker incremental ages stay single-reviewer.
- **Alternatives:** chezmoi-templated prompts interpolating skill text at sync time (still copies, just refreshed — and adds template machinery); specialist-agent pre-fetch feeding digests to one /age reviewer (lower parallelism; keeps a second evidence pathway to maintain). Runtime pointers dominate both.
- **Consequences:** One fan-out implementation shared by both workflows; review semantics have a single source of truth (the vendored easy-cheese skill); the child depends on the deployed skill layout under `~/.claude/skills/age/` — a skill restructure that renames those reference files breaks the pointers loudly (Packet agent returns blocked, parents fall back to single-reviewer).
- **Durability guards (PR #494 review):** fail-loud is enforced, not assumed. The Packet agent must verify the pointed-at files exist and return `skill_files_ok:false` (→ child returns `blocked`, zero reviewers dispatched) on missing/unparseable files; dimensions must byte-match the `###` headings under `## Per-dimension rubrics` and are validated twice — schema `pattern` plus an in-script slug check. The in-script check is the authoritative layer: a runtime's mini JSON-Schema validator may silently ignore `pattern` (the offline test harness did, until support was added). `tests/workflows/age-fanout-skill-contract.test.mjs` pins the deployed `dimensions.md` structure at `just check` time on machines with the skill deployed, and skips (never fails) where it isn't (CI). Residual risk, accepted: a Packet agent that reads the files fine but hallucinates plausible-slug dimensions passes both layers — inherent to the agent-driven pointer design.

## ADR-008: Dependency-coupled curds merge back to one curd, not topological sequencing  [status: accepted]

- **Context (issue #492):** the decomposer over-split a coupled feature (spec `match-length-target`) into parallel curds where curd B consumed exports curd A introduced. ADR-005's merge only sees shared file paths, so semantically-dependent but file-disjoint curds fanned out in parallel off `origin/main` — B correctly refused ("dependency not implemented on origin/main") and the feature never landed despite ~1.1M tokens.
- **Decision:** the decomposer now emits optional `depends_on: [sibling-slug…]` edges and carries explicit splitting rules (split only where curds build/test from `origin/main` alone; a spec-declared multi-site contract is one indivisible curd). `mergeCoupledCurds` (extending ADR-005's `mergeOverlappingCurds`) merges groups coupled by shared files OR a `depends_on` edge, transitively. If merging leaves one curd, the run degrades to single-pass.
- **Alternatives:** topological ordering with dependent curds branched from their dependency's branch (issue option 1) — keeps nominal fan-out but the dependent curd waits anyway (serialization either way), adds stacked-branch bookkeeping across taste/integrate, and a taste gate over B's diff would see A's unreviewed work; warn-and-proceed (rejected already in ADR-005).
- **Consequences:** dependency-coupled work is always implemented in one context, extending ADR-005's file-disjointness invariant from shared paths to semantic dependencies. Coupled specs gracefully collapse to single-pass instead of burning parallel dispatches on curds that must block. Trade-off: a legitimately splittable-but-ordered pipeline loses parallelism — accepted, correctness over wall-clock.

## ADR-009: A drowned cook gets bounded fresh-coder continuations, not terminal failure  [status: accepted]

- **Context (issue #493):** a cook returning `blocked: out of context` was routed straight to `failed`; its partial edits sat uncommitted on a branch 0 commits ahead of main inside an isolation worktree that reaps unchanged-looking trees — work silently discarded, violating the coder's fresh-context handoff contract.
- **Decision:** two layers. (1) `NO_CHAIN_DIRECTIVE` now instructs write-phase agents to commit WIP locally on their branch before writing a partial `halt` slug — the work survives worktree reaping regardless of what the orchestrator does next. (2) On a cook status matching `/^(blocked|halt)\b/i` with a reported `worktree_path`, the orchestrator dispatches up to `COOK_CONTINUATIONS = 2` fresh coders (never resuming the exhausted one), each seeded to re-enter the existing curd branch, commit any remaining partial work as its first action, orient from `git diff origin/main...<branch>` + the partial handoff slug, and finish only the remaining acceptance criteria. Only after the cap does the curd fail, with a message noting the branch may carry committed WIP.
- **Alternatives:** resume the exhausted agent (forbidden — a resumed transcript inherits the spent context and starts near-full); terminal-fail but commit WIP for manual resume (issue option 2 — preserves work but abandons the run's own recovery); unbounded continuations (runaway cost on a curd that can never converge).
- **Consequences:** partial cook work is durable and usually completed within the run at the cost of ≤2 extra sonnet dispatches per drowned curd. A cook that reports `blocked` without a `worktree_path` still fails immediately — nothing to continue from.

_Source: preamble and coder prompt consolidation · Updated: 2026-07-28 · Supersedes: preamble-owned fan-out and continuation attributions_

## ADR-010: Phase-owned checkpoint before one targeted Cook retry [status: accepted]

This decision replaces ADR-009's recovery procedure, not its requirement to preserve partial work.
The September 19, 2026 session shows that handwritten notes and broad continuation assignments still exhaust coders.[^recovery-20260919]

The worker returns compact observations with `needs-context`.
The workflow delegates persistence to one checkpoint coordinator because its JavaScript runtime exposes no filesystem or process primitive.
That coordinator invokes the installed Wheypoint capability without modifying source.
The workflow starts one fresh coder only after the coordinator confirms authoritative context for the same worktree.
The fresh coder reads the resolved ranges before implementation.
Missing observations, failed resolution, and second exhaustion halt.
Generic `blocked` and `halt` statuses do not imply context recovery.[^recovery-20260919]

The procedure removes blanket WIP staging, branch recreation, and broad diff rereads from the recovery prompt.
It leaves model selections and worker budget caps unchanged.
The parent must not implement the remainder automatically.
The coordinator's verified response remains an agent trust boundary; deterministic workflow tests verify routing, not model execution.[^recovery-20260919]

[^recovery-20260919]: `claude/workflows/cheese-factory.js` (`checkpointPrompt`, `validCheckpointResult`, Cook pipeline stage); `tests/workflows/cheese-factory.test.mjs`; [[operations/subagent-dispatch-analytics]]. Decision: September 19, 2026.

## ADR-011: Thin wrapper over easy-cheese contracts on linked wheypoints [status: proposed]

- **Context:** Every handoff passes as agent-echoed JSON. The workflow runtime cannot read files, and no hook checks a handback. A 2026-09-30 explorer digest found 15 handoff failure classes; most trace to this gap. The `/cook` fan path cannot run inside a workflow agent, because a workflow agent cannot spawn sub-agents (ADR-007).
- **Decision:** The script owns only scheduling: waves, boss turns, parking, and barriers. Easy-cheese owns phase meaning: Mold `PlannerRequest`, `validate_curd_plan`, `write-handoff-artifact`, and Wheypoint. State lives in a linked Wheypoint graph. One run record `factory-<spec>` holds an `implements` edge to the spec. `fork` creates one record per curd, and `blocked_by` edges carry dependencies. Agents receive only a pinned `wheypoint:<project>/<curd>@<rev>` ref.
- **Alternatives:** Run `/cook` fan at the top level (no bosses, no deterministic control flow); patch the current loop (keeps the custom decomposer and echoed JSON); do nothing.
- **Consequences:** ADR-005 and ADR-008 curd merging give way to `blocked_by` waves. A pinned revision makes a race fail as `stale-parent`. `shape <run>` reports the whole factory graph.[^factory-20260930]

## ADR-012: Agent-scoped hooks enforce the factory handoff contract [status: proposed]

- **Context:** Claude Code 2.1.285 has no workflow hook event, and hook input carries no workflow run id. `SubagentStop` input carries `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`, and `stop_hook_active`.
- **Decision:** Factory-only agents (`curd-boss`, `factory-coder`, `factory-reviewer`) carry `hooks:` frontmatter. A `PreToolUse` hook on `StructuredOutput` denies an invalid handback and names the failed field. A `SubagentStop` hook records the handback as a Wheypoint revision. This retires the ADR-010 checkpoint coordinator agent.
- **Alternatives:** A global hook that matches `agent_type`; a global hook gated on a `.cheese/` run marker; agent-side checks only.
- **Consequences:** Hooks run only inside factory agents. Hook failures block work, so each hook must fail closed with a clear reason.
- **Smoke evidence (2026-09-30, headless `claude -p`):** settings hooks fired inside a sub-agent. Hooks on a session agent from `--agents` fired, and the agent `Stop` hook arrived as `SubagentStop` with `last_assistant_message`. Hooks in a project `.claude/agents/` file in an untrusted directory did not fire; the binary evaluates agent-frontmatter hooks at launch under workspace trust.
- **Gotcha:** neither renderer emits `hooks:` today (`agent-profile/agent_profile/shared.py` `claude_agent_frontmatter`, `.sync-lib.sh` `_cz_render_claude_agent`).
- **Open:** a workflow `agent()` with `agentType` may ignore frontmatter hooks, and a `StructuredOutput` deny may not trigger a clean retry. The first implementation curd smoke-tests both.[^factory-20260930]

## ADR-013: Curd bosses direct coders through the script loop [status: proposed]

- **Context:** The user wants Opus curd bosses that nest coders. A workflow agent cannot spawn sub-agents, and `workflow()` nests one level only, which `age-fanout` already uses.
- **Decision:** Each curd runs a script loop. The loop calls an Opus boss with the curd ref, and the boss returns one typed decision: dispatch a coder, dispatch a review, raise a fork, or finish. The script runs the decision with a `factory-coder` and calls the boss again.
- **Alternatives:** Flat coders without a boss (the current shape).
- **Consequences:** The boss keeps judgment, and the script keeps control flow and resume caching.[^factory-20260930]

## ADR-014: Forks park the curd and batch at barriers [status: proposed]

- **Context:** A workflow can log or return, but it cannot ask the user mid-run.
- **Decision:** A boss records a gating `question` and a `decision_dossier` fork, so Wheypoint derives `gated`. The curd parks, and the other curds continue. The next barrier returns every parked fork. Resume uses `resumeFromRunId` with the answers in `args`, and each answer resolves its entry with the user's quoted words.
- **Alternatives:** Bosses decide every fork and log it for veto; the first fork stops the run.
- **Consequences:** Only the parked curds' boss turns rerun on resume; finished work returns from the cache.[^factory-20260930]

[^factory-20260930]: Spec `specs/cheese-factory-linked-wheypoints.md` (durable corpus `~/.local/share/cheese/paulnsorensen-dotfiles/`); `~/.claude/skills/wheypoint/references/work-graph.md`; `~/.claude/skills/cook/references/fan-pathway.md`. Decision: September 30, 2026.
