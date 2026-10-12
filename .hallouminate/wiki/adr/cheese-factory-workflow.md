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

## ADR-010: Phase-owned checkpoint before one targeted Cook retry [status: superseded by ADR-011]

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

## ADR-011: Commit-SHA continuation with source ranges as data [status: accepted]

- **Context:** ADR-010's wheypoint coordinator must run in the cook's worktree to see its uncommitted state. ADR-012 gives every writer its own isolated worktree, so the coordinator cannot see that state. It also costs one sonnet agent per round. move-my-cheese (`buildTarget`, `claude/workflows/move-my-cheese.js:1097`) continues from a committed SHA instead.
- **Decision:** A cook that runs low on context commits its work, advances `curd/<slug>`, and returns completed, remaining, a checkpoint SHA, and `source_ranges`. Code validates the ranges with `validGroundedRanges` and passes all four as fenced data to a fresh isolated continuation. A null result runs one `salvage()` that reads `refs/heads/curd/<slug>`. A repeated SHA stops the curd as stalled. The limit is 3.
- **Alternatives:** pure move-my-cheese continuation without ranges (loses ADR-010's targeted first read); keep the coordinator and pin it at the SHA (unverified that a wheypoint checkpoint resolves across worktrees).
- **Consequences:** No wheypoint dependency in the workflow. The continuation still reads the named ranges first. Uncommitted work at a hard death is lost; salvage resumes from the last commit.

## ADR-012: Writers advance curd branches with update-ref from a detached HEAD [status: accepted]

- **Context:** `claude/hooks/worktree-guard.js:25-41,60-71` allows writes only under the agent's own worktree root. cheese-factory writers `cd` into the cook's worktree, so the guard blocks their edits. move-my-cheese fixed the same failure in #1267 (wiki: architecture/move-my-cheese-workflow).
- **Decision:** Cook, continuation, corrective, press, and cure each run with `isolation: 'worktree'`. Each checks out `--detach <sha>`, commits, and runs `git update-ref refs/heads/curd/<slug> HEAD`. Each returns `head_sha`, and code passes it to the next writer and to Plate. No worktree checks out `curd/<slug>`.
- **Alternatives:** per-stage branches with `--ignore-other-worktrees` (more refs and cleanup); keep the shared worktree (blocked by the guard).
- **Consequences:** State moves only through refs and SHAs. Plate can check out `curd/<slug>` because no worktree holds it.

## ADR-013: age-fanout returns flat findings for code routing [status: accepted]

- **Context:** ADR-006 routes findings to curds by file, but the age-fanout reconcile model did the routing with `git log --name-only` and reported cheap lows as one global boolean (`claude/workflows/age-fanout.js:128,214-219`). cheese-factory could not cure cheap lows per curd or check the routing.
- **Decision:** When the caller passes `route_curds`, reconcile returns a flat `findings` list. Each item has a severity and `fix_cost_now` (contained, sprawling, or n/a). cheese-factory's integrate step returns `files_by_slug`, and code routes each finding to every curd that owns its file. A finding that needs cure with no owner marks every integrated curd dirty. An unowned low that needs no cure leaves the curds clean. A call without `route_curds` is unchanged, so move-my-cheese is unaffected.
- **Alternatives:** validate the model's `per_curd` in code (the model still routes); defer routing (cheap lows cure every curd).
- **Consequences:** Routing is deterministic and testable. `fix_cost_now` stays a reviewer judgment.

_Source: /mold spec `cheese-factory-hardening` (durable corpus) · Decided: 2026-10-12 · ADR-011 supersedes ADR-010_

## Implementation notes for ADR-011..013 (2026-10-12)

The `cheese-factory-hardening` run implements ADR-011, ADR-012, and ADR-013. Review and user decisions refine them as follows.

- **Cook answers that stay final (user decision B).** A partial cook or continuation with a bad checkpoint SHA goes to `salvage()`. An `ok` cook with a bad `head_sha` fails the curd at stage cook at once. A `needs-context` status, a null result, and a throw also go to `salvage()`. No cook SHA defect re-dispatches `cookPrompt`, because that prompt resets `curd/<slug>` to the base SHA.
- **Cook status outside the enum (user decision, 2026-10-12).** A cook status other than `ok`, `partial`, `blocked`, or `needs-context` also goes to `salvage()`. A redo would reset the curd ref, as for a SHA defect.
- **Ranges.** `groundedRanges` keeps the valid `source_ranges` and drops the rest. A one-line `#n-n` range is valid. This replaces the reject-all check that ADR-011 names.
- **Integration (amends ADR-006).** Integrate and re-merge build on a detached HEAD at the resolved base SHA through one shared merge prompt. They merge each curd by its code-known SHA. No `integration/<parent>` branch exists, because a second worktree cannot check out a branch that another worktree holds.
- **Fail-closed reviews.** A barrier, fan-out, or re-age result whose status is not `ok` is not a review. A blocked barrier fails every integrated curd. A blocked re-age after a cure marks every integrated curd dirty.
- **Plate pin.** Plate checks `refs/heads/curd/<slug>` against the reviewed SHA once, before /plate starts any commit, restack, or push step. A check at push time conflicts with the stacked restack, which rewrites upper-layer SHAs.
- **Typed calls.** A status or SHA error is a substance error, so the producer redoes the call. No formatter repairs it. A writer throw is final; a read-only throw (taste, salvage, reviewers, formatter repairs) retries within `LIMITS.fixRounds`. A short SHA gets a read-only expansion instead of a writer redo. Cook is the exception: its status and SHA defects stay final, as above.
- **Writers read skill files (user decision, 2026-10-12).** The `coder` type has no Skill tool, because the Skill tool adds the full skill listing (about 11k tokens) to every coder spawn. The cook, press, and cure prompts tell the writer to read `~/.claude/skills/<name>/SKILL.md` and follow it, as age-fanout does for the reviewer.
- **Code-owned checks.** A taste pass over a `revise` lens counts as `revise`. A resolved spec must carry `curd_count`. A decomposition above `LIMITS.maxCurds` (12) is a substance error, which keeps a run under the 1000-agent cap.

_Source: `claude/workflows/cheese-factory.js`, `claude/workflows/age-fanout.js`, `tests/workflows/cheese-factory*.test.mjs` · Age reports `.cheese/age/pass{1,2}-cheese-factory-hardening.md` · Updated: 2026-10-12_

## ADR-014: Shared helper prelude as a vendored block with a drift test [status: proposed]

- **Context:** Workflow scripts cannot import. cheese-factory and move-my-cheese hold nine byte-identical helpers, two scratch and SHA regexes that differ in form, and two diverged `typed()` functions. `dots sync` copies `claude/workflows/` with `cp -L` and has no build step (`.sync-lib.sh:406,670`).
- **Decision:** `claude/workflow-prelude/prelude.js` holds the nine helpers plus the two converged regexes (`SCRATCH_WORKTREE_RE` with its `SCRATCH_PATH_SRC`, and `FULL_SHA_RE`). `node claude/workflow-prelude/sync.mjs` pastes it between markers in both workflows. A test fails when a block drifts from the source. Each workflow keeps its own `typed()`. The shared `FULL_SHA_RE` has the `i` flag, so cheese-factory now accepts an uppercase 40-hex SHA.
- **Alternatives:** concat at deploy (repo file differs from deployed file; ADR-007 rejected template machinery); a drift test only (fixes still need manual ports).
- **Consequences:** The deployed file equals the repo file, and the harness and deploy stay unchanged. An edit inside a block fails the test until it moves to the source.

## ADR-015: Extract one read-only check per spec AC at resolve [status: proposed]

- **Context:** Spec ACs are EARS prose with no check command. move-my-cheese's planner emits criteria with checks, and code gates them with `UNSAFE_CHECKS` (`claude/workflows/move-my-cheese.js:189,269`).
- **Decision:** After resolve, one read-only opus agent returns one criterion per spec AC id: a check_kind (command, test, inspection, or ci) and a check. Code requires exact AC-id coverage and gates each command or test with `UNSAFE_CHECKS`. A spec with no AC line skips verification.
- **Alternatives:** judges read the prose and choose a check (less reproducible); the mold spec format carries checks (changes the easy-cheese mold skill and every older spec).
- **Consequences:** Checks are reproducible and reviewable before cook. An extracted check can be weak; the plan advisor reviews it.

## ADR-016: A failed spec criterion blocks Plate [status: proposed]

- **Context:** Today a curd plates when its review is clean, without a check against the spec's ACs.
- **Decision:** Before Plate, one judge per non-ci criterion verifies it at the final integration head. A fail, a missing path, or no valid verdict blocks Plate, and the run returns status partial with the verdicts. CI criteria are deferred.
- **Alternatives:** one corrective round before blocking (ACs do not map to curds); advisory only (no guarantee).
- **Consequences:** Fail closed, as in move-my-cheese. A run can finish clean on review but still not plate.

## ADR-017: Advisor gates on the plan and on done [status: proposed]

- **Context:** move-my-cheese advises on its plan (approve, one revise, or stop) and on done (`claude/workflows/move-my-cheese.js:1103-1108,1599-1621`). cheese-factory starts cook on an unreviewed decomposition.
- **Decision:** A judge in advise mode reviews the curds and criteria before any cook: approve, one revise, or stop. A second advise call after verification gates Plate: only approve proceeds.
- **Alternatives:** a done gate only (a bad plan surfaces late); no advisor.
- **Consequences:** Two or three opus calls per run. A stopped plan spends no cook agents.

_Source: /mold specs `cfh-shared-prelude` and `cfh-criteria-gate` (durable corpus) · Decided: 2026-10-12 · Status proposed until the specs land_
