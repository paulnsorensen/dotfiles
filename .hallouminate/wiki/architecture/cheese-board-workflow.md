# cheese-board workflow

`claude/workflows/cheese-board.js` is the strategy layer above `cheese-factory`. It triages open issues and gathers ideas. It grounds them in the repo wiki, synthesizes themes and initiatives, and researches open external facts. It then mints validated mini-specs, and each spec is one `cheese-factory` input. It writes spec files, a report, and one wiki page. It never mutates GitHub and never runs `cheese-factory`.

## Shape

Gather → Ground → Strategy → Advise → Resolve → Spec → Verify → Report → Record.

- **Gather** runs the `triage-sweep` child workflow (`scope: 'issues'`) and one idea explorer concurrently. Code maps triage routes to lanes: `fix-now` and `rescope` go to spec, `needs-design` to mold, `deferred` to defer, `needs-human` to human, and a `certain` close to the close batch. A `likely` close goes to human.
- **Ground** is one explorer that queries hallouminate. It collects ADRs, locked conventions, roadmap direction, gotchas, and earlier `strategy/cheese-board-*` pages, and it lists prior research documents. Code assigns decision IDs (`D-n`). When this stage fails, the run continues without decisions, records a gap, and ends `partial`.
- **Strategy** is a correct barrier, because each strategist needs every item. Three lens strategists (leverage, risk, architecture) see the items and the decisions. One Opus synthesizer merges their proposals. `checkStrategy()` places every live item exactly once and resolves refs, including `overrides` to `D-n`. It also enforces unique kebab-case slugs and `maxSpecs`, and rejects cycles.
- **Advise** is the judge advisor. It receives the decisions, so it can reject a strategy that contradicts the wiki. With `auto: true` it allows one revision, then returns `needs-input` with no resume channel. Without `auto`, it also asks `blocking_questions` and the run pauses (see Interactive mode).
- **Spec** runs one independent chain per spec initiative:
  - research: `workflow('brie-ground', question)` for each of the initiative's `research_questions`
  - draft: Opus, given the relevant decisions and the research
  - taste-test: taste-tester
  - install: a coder stages the file in a temp dir and runs `validate-spec --strict` and `curd-count`. It moves the file into place only when both pass.

  One redraft is allowed, then the initiative goes to mold.
- **Verify** is a judge that re-runs both mold gates on every installed spec, because the installer cannot grade itself.
- **Report**: code computes the factory waves and renders the report. A haiku coder writes the report. A done advisor signs off.
- **Record** runs only after the done advisor approves. One agent writes `strategy/cheese-board-<stamp>.md` to the repo wiki with `add_markdown`, and the next Ground reads it as kind `strategy`. The page is an uncommitted wiki change in the checkout.

## Decisions and why

- **Grounding comes before the strategy, not inside the drafter.** The drafter's wiki row comes after the strategy is already fixed. Recorded decisions must constrain the themes and the lanes, so the strategists, the synthesizer, and the advisor all see them.
- **Overriding a decision means /mold, unless the user keeps it.** An initiative that lists a `D-n` in `overrides` changes a recorded decision. With `auto: true`, `normalizeStrategy()` moves it to mold and its dependents block. In interactive mode the run asks "spec or mold?" with mold recommended. The answer `spec` keeps the lane. The spec then carries a `## Decision overrides` section after Non-goals, and the report says "kept in the spec lane by the user".
- **Research uses the brie-ground child, with a cap.** brie-ground nests no workflow, so the one-level nesting rule allows it as a child. `LIMITS.maxResearch` (4) caps the runs across specs in priority order. The plan is all or nothing per initiative, because a partial plan sends the initiative to mold and wastes its slots. `LIMITS.maxQuestionsPerInitiative` (2) caps each initiative. Overflow goes to mold with the questions that were not researched. A `dont_know` answer goes to mold. A failed child fails the spec, and the spec is never drafted blind.
- **The prelude owns the grounding contract.** `GROUNDING_SCHEMA`, `GROUND_RULES`, `DECISION_KINDS`, `RESEARCH_CONFIDENCE`, `MOLD`, and `brieGround()` live in `claude/workflow-prelude/prelude.js`. cheese-factory and move-my-cheese use the same contract ([[adr/cheese-factory-workflow]] ADR-018). `research()` here wraps `brieGround()` and maps its result to spec statuses.
- **Provenance carries the research.** The mold mini-spec template reserves `## Provenance` with a `briesearch:` line for tier-2 synthesis. `validate-spec --strict` accepts it. A spec without research has no Provenance section.
- **/culture is not invoked.** Inside a workflow, the lens panel and the advisor do /culture's trade-off work. Record covers its durable-knowledge role.
- **Resolver-owned paths.** Specs go to `mold.pyz artifact-path specs <slug>`, the durable corpus that `cheese-factory` resolves. The report goes to `artifact-path notes cheese-board-<stamp>`. `strategy` is not a valid artifact phase.
- **No chaining into cheese-factory.** `cheese-factory` calls `workflow('age-fanout')`, and nesting allows one level only. The result returns `factory_queue` waves of `/cheese-factory <path>` commands.
- **Never overwrite.** A slug whose path already exists becomes `exists`, and its dependents block.
- **Opus on the two judgment calls.** The synthesizer and the spec drafter set `model: 'opus'`. The other agents keep their agent-type models.
- **Code assigns IDs and numbering.** Code assigns `IDEA-n`, `D-n`, and AC numbers. A spec-lane initiative moves to mold in code when it has a leverage trigger, an open question, an override, or too many research questions.
- **Args need a stamp.** Scripts cannot read the clock, so `args.stamp` (YYYY-MM-DD) dates each spec and names the report and the wiki page.

## Interactive mode

The Workflow runtime cannot pause, so approval takes two runs bound by a digest. This supersedes the old rule that Advise returns `needs-input` with no resume channel. The shared prelude owns the protocol (`stable`, `fnv1a`, `digestOf`, `matchAnswers`), and move-my-cheese uses it too ([[architecture/move-my-cheese-workflow]]).

- **Default is interactive.** `auto: true` keeps the unattended behavior. A run with `state`, `digest`, `answers`, or `lanes` and `auto: true` is blocked.
- **Three checkpoints** return `status: needs-input` with `checkpoint`, typed `questions`, `state`, and `digest`: `strategy` (advisor cap, blocking questions, override calls), `spec` (leverage triggers and drafter open questions), and `done` (the done advisor did not approve).
- **Code validates a resume before the first agent.** It checks the state shape, the digest, the answers, closed options, `lanes`, and the auto flag, and it returns every error in one `blocked` result. The digest detects edits, not a hostile caller.
- **A resume restores state.** It does not rerun Gather, Ground, or the first-round Strategy. A strategy resume applies the answers and `lanes`, runs one synthesizer revision, and advises again. A spec resume redrafts only the answered initiatives. A done resume skips Verify and either records (`approve`) or applies one fix to the report.
- **A leverage trigger asks "mold or spec anyway"**, with mold recommended.
- **The `cheese-board` skill drives the loop** with AskUserQuestion, recommended option first. See `skills/cheese-board/SKILL.md`. It stops on any other status.

## Gotchas

- `curd-count` counts the bullets under `## Goals`. A spec with no Goals section has 0 curds, and `cheese-factory` rejects it.
- mold's grounding-table parser splits on every `|`, even an escaped `\|`. `cell()` replaces `|` with `/`.
- `validate-spec --strict` accepts `## Sources`, `## Provenance`, and JSON-quoted YAML scalars.
- `artifact-path notes` prints a checkout-relative path (`.cheese/notes/<slug>.md`). `artifact-path specs` and `research` print absolute paths. `checkResolve()` accepts both forms for the report.
- `artifact-path` rejects a slug with a leading, trailing, or double hyphen, or more than 64 characters. `SLUG_RE` and `validSlug()` match that rule, so Resolve cannot block on a slug that `checkStrategy()` passed.
- Every gap ends the run `partial`: a failed strategist lens, an ungrounded issue, and missing routing when issues were grounded. Dropped seeds, ideas over the cap, and unused themes go to `log()` and to the `dropped` result list.

Tests: `tests/workflows/cheese-board.test.mjs` runs with `auto: true` and stubs both the `triage-sweep` and the `brie-ground` children through the `workflow` override. `tests/workflows/cheese-board.interactive.test.mjs` covers the checkpoints and resume. `tests/workflows/cheese-board-skill-contract.test.mjs` pins the skill file.

Related: [[architecture/saved-workflows]], [[adr/cheese-factory-workflow]].

*Source: cheese-board design session (2026-10-14), with /claude-workflows, an advisor revise round, and a grounding follow-up.*
