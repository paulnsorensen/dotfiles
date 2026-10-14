# cheese-board workflow

`claude/workflows/cheese-board.js` is the strategy layer above `cheese-factory`. It triages open issues, gathers ideas, synthesizes themes and initiatives, and mints validated mini-specs. Each spec is one `cheese-factory` input. It writes spec and report files only. It never mutates GitHub and never runs `cheese-factory`.

## Shape

Gather → Strategy → Advise → Resolve → Spec → Verify → Report.

- **Gather** runs the `triage-sweep` child workflow (`scope: 'issues'`) and one idea explorer concurrently. Code maps triage routes to lanes: `fix-now` and `rescope` go to spec, `needs-design` to mold, `deferred` to defer, `needs-human` to human, and a `certain` close to the close batch. A `likely` close goes to human.
- **Strategy** is a correct barrier, because each strategist needs every item. Three lens strategists (leverage, risk, architecture) propose a strategy. One synthesizer merges the proposals. `checkStrategy()` places every live item exactly once, in an initiative or in `parked`. It also resolves refs, gives each spec slug a unique kebab-case value, enforces `maxSpecs`, and rejects cycles.
- **Advise** is the judge advisor. It allows one revision, then returns `needs-input`.
- **Spec** runs one independent chain per spec initiative: draft (explorer), taste-test (taste-tester), then install (coder). The coder stages the file in a temp dir and runs `validate-spec --strict` and `curd-count`. It moves the file into place only when both pass. One redraft is allowed, then the initiative goes to mold.
- **Verify** is a judge that re-runs both mold gates on every installed spec, because the installer cannot grade itself.
- **Report**: code computes the factory waves and renders the report. A haiku coder writes the report. A done advisor signs off.

## Decisions and why

- **Resolver-owned paths.** Specs go to `mold.pyz artifact-path specs <slug>`, the durable corpus that `cheese-factory` resolves (`cheese-factory.js` Resolve prompt). They do not go to `.cheese/specs/`, which is legacy. The report goes to `artifact-path notes cheese-board-<stamp>`. `strategy` is not a valid artifact phase.
- **No chaining into cheese-factory.** `cheese-factory` calls `workflow('age-fanout')`, and nesting allows one level only. The result returns `factory_queue` waves of `/cheese-factory <path>` commands. A spec whose prerequisite is not written and verified goes to `blocked` with a reason.
- **Never overwrite.** A slug whose path already exists becomes `exists`, and its dependents block. A re-run therefore never clobbers a spec that an earlier run wrote.
- **Code assigns IDs and numbering.** Idea IDs (`IDEA-n`) and AC numbers come from code, so an agent cannot collide or skip. A spec-lane initiative with a leverage trigger or an open question moves to mold in code (`normalizeStrategy()`).
- **Opus on the two judgment calls.** The synthesizer and the spec drafter set `model: 'opus'`. The `explorer` agent type defaults to Sonnet, and these two calls decide the strategy and the contract that cheese-factory cooks. The strategists, taste-tester, and installer keep their agent-type models.
- **Args need a stamp.** Scripts cannot read the clock, so `args.stamp` (YYYY-MM-DD) dates each spec and names the report.

## Gotchas

- `curd-count` counts the bullets under `## Goals`. A spec with no Goals section has 0 curds, and `cheese-factory` rejects it. The renderer always writes Goals from the drafter's `goals[]`.
- mold's grounding-table parser splits on every `|`, even an escaped `\|`. `cell()` replaces `|` with `/`.
- `validate-spec --strict` accepts an extra `## Sources` section and JSON-quoted YAML scalars (for example `inputs: "issue #1"`).

Tests: `tests/workflows/cheese-board.test.mjs` stubs the `triage-sweep` child through the `workflow` override.

Related: [[architecture/saved-workflows]], [[adr/cheese-factory-workflow]].

*Source: cheese-board design session (2026-10-14), with /claude-workflows and an advisor revise round.*
