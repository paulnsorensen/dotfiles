# cheese-board strategy 2026-10-14

Scope: open bugs in the Workflow-tool skills (#1305, #1279, #1272, #1271, #1270) plus one seed idea, a cheese-board scope argument. The strategy has four themes and five initiatives. IN-4 is the only spec in the factory queue. IN-1, IN-2, IN-3, and IN-5 go to /mold in that order. #1270, #1271, and #1272 are in the close batch, because #1267 (commit 1f3fe1db) fixed them.

The strategy advisor approved this strategy in round 3. The done advisor asked for report fixes only: record the IN-1 lane change, order the mold list, and correct one line citation. The operator applied them by hand and recorded this page, so the Record phase did not run in code. The next cheese-board run reads this page as kind strategy.

This run used a session-only scoped copy of cheese-board. The copy filtered triage-sweep by issue number and raised `advisorRevisions` from 1 to 2. The run hit the one-revision cap first, which is the #1305 defect.

## Themes

- **TH-1 One resumable advisor contract**: Every workflow that stops at needs-input resumes through one shared answers-through-digest contract, so a capped advisor loop never strands a run.
- **TH-2 Honest cheese-factory intake and fan-out**: Cheese-factory states clearly why it rejects or narrows a spec, then a superseding ADR settles stack-versus-merge fan-out on purpose, not by drift.
- **TH-3 Steerable cheese-board runs**: Cheese-board accepts a caller-supplied backlog scope, but only after its advisor and resume contract is stable.
- **TH-4 Lock recurring prompt and check seams**: Prompt-contract and check-execution defects came back across workflows (#1270, #1271, #1274), so each fix gets a regression test.

## Initiatives

| Initiative | Theme | Lane | Depends on | Items | Outcome |
| --- | --- | --- | --- | --- | --- |
| IN-1 Cheese-factory intake signals and continuation tests | TH-2 | mold (moved from spec) | - | references #1279 | A bad free-text spec arg stops with a message that lists the accepted forms; the 0-Goals behavior is decided; tests cover the #1281 continuation paths that existing tests miss. |
| IN-2 Shared advisor resume contract for cheese-board | TH-1 | mold | - | #1305 | At the advisor cap, cheese-board returns a digest with blocking questions, and a rerun with an answers arg resumes it. advisor.md and ADR-017 state the shared rule; move-my-cheese still conforms. |
| IN-3 Decide stacked fan-out versus merged curds | TH-2 | mold | IN-1 | #1279 | A superseding ADR settles ownership of cheese-factory.js (D-20), merged-with-size-cap versus stacked depends_on curds, and free-text spec arg routing. |
| IN-4 Regression guards for Review mode lines and check execution | TH-4 | spec | - | IDEA-5, IDEA-6 | Tests fail if a reviewer or age-fanout prompt builder omits the Review mode line, or if a check runs outside the repository root or not under bash -c. |
| IN-5 Cheese-board scope argument | TH-3 | mold | IN-2 | IDEA-1 | cheese-board triages and strategizes only a given subset (issue numbers, labels, or a focus query) and still requires args.stamp. |

IN-1 moved from spec to mold after Spec. Its draft warned on a spec with 0 Goals bullets, but `curdCountErrors` (claude/workflows/cheese-factory.js:537) and the gotcha in [[architecture/cheese-board-workflow]] reject it. That behavior is a contract choice. Existing tests (tests/workflows/cheese-factory.test.mjs:1146-1185, :2803, :2815) already cover clipping, groundedRanges, and continuation isolation.

Factory queue, wave 1: `/cheese-factory ~/.local/share/cheese/paulnsorensen-dotfiles/specs/prompt-contract-guards.md` (IN-4, 1 curd).

Parked: IDEA-4 (move-my-cheese answers path) is already shipped by #1267. It is the design precedent for IN-2.

## Decisions it relied on

- D-1, D-2 (adr): coupled curds merge into one curd (ADR-008) and curds stay file-disjoint (ADR-005). See [[adr/cheese-factory-workflow]].
- D-4 (adr): workflows are thin wrappers with no routing logic in workflow JS. See [[adr/subagent-routing-overhaul]].
- D-8 (locked): cheese-board Advise allows one revision, then returns needs-input with no resume channel. See [[architecture/cheese-board-workflow]].
- D-9, D-10, D-11: move-my-cheese resumes needs-input through answers bound to a digest; the runtime cannot pause, so approval takes two runs. See [[architecture/move-my-cheese-workflow]].
- D-12, D-13: cheese-board needs args.stamp, never mutates GitHub, and nests one level only.
- D-14 (gotcha): a spec with 0 Goals bullets has 0 curds, and cheese-factory rejects it.
- D-15, D-16, D-18: the reviewer needs the literal Review mode line; checks run from the repository root under bash -c.
- D-20 (roadmap): cheese-factory.js and age-fanout.js are to move into easy-cheese.

## Decisions it would change

- IN-2 overrides D-8; routed to /mold.
- IN-3 overrides D-1 and D-2; routed to /mold.

## Research

- none. No initiative had an open external question.

Report: .cheese/notes/cheese-board-2026-10-14.md (local, not committed).
