---
name: claude-workflows
model: opus
effort: high
description: >
  Designs or reviews a multi-agent workflow (a Workflow tool script, an Agent SDK orchestrator,
  or a sub-agent pipeline) against cited best practices. Use when the user says "write a multi-agent
  workflow", "design an orchestration", "fan out agents", "review this workflow", "agents keep running
  out of context", "make this multi-agent workflow cheaper", or invokes /claude-workflows. Do NOT use for one
  sub-agent call (/cook), a review of ordinary code (/age), the Workflow script API reference
  alone (workflow-authoring), or GitHub Actions (/ci-optimize).
---

# claude-workflows

Produce a workflow design or a workflow review that applies seven practices.
The practices are typed contracts, cheap repair, budget recovery, a task ontology, an advisor gate, code-side determinism, and fit with the host setup.

## Core rule

Code owns control flow, state, limits, and checks. Agents own judgment.
Every agent returns a typed object. Code validates that object before the next stage reads it.

## Inputs

Parse the text after the skill name.

- `design <goal>` — write a new workflow for the goal.
- `review <path>` — review an existing workflow script or orchestrator.
- No mode — ask for the mode and the target.

## Flow

0. **Choose the form.** A Workflow cannot pause. Keep user questions, approval gates, and run state in the calling skill. Put only independent units that each fit one fresh context into a Workflow. Use one agent, not a Workflow, for one unit of work. Done when each stage is marked skill-side or workflow-side.
1. **Ground.** Load the built-in workflow-authoring skill when the target is a Workflow tool script. That skill owns the runtime API, the runtime limits, and the quality patterns. This skill does not copy them. Outside Claude Code, that skill is absent; mark its runtime checks as unverified. Read `references/environment.md` for the host hooks, tools, and agent types. Read the target or the goal. Done when you can name each stage, the data it passes, and the tools its agents use.
2. **Model the work.** Build the ontology from `references/ontology.md`. Done when its code checks pass. Each criterion has an exact check and a task. Each reference resolves. The task graph has no cycle.
3. **Gate the approach.** Call a read-only advisor from `references/advisor.md` when a leverage trigger fires or code cannot check the plan. The second round re-checks the first-round concerns only. Done when the advisor approves, or after one revision round.
4. **Type the contracts.** Give each agent call a schema constant from `references/schemas.md`. Done when each call has a schema and a code validator.
5. **Add repair.** Route validator errors through `references/repair.md`. Done when each invalid output takes a bounded repair or redo path.
6. **Plan for exhaustion.** Size tasks and add checkpoints from `references/budget-recovery.md`. Done when a null or partial result resumes from durable state, and each `needs-*` status names the input that resumes it. A no-progress guard stops the loop.
7. **Move work into code.** Apply `references/determinism.md`. Done when no prompt asks a model to count, sort, deduplicate, or cross-check a list.
8. **Verify independently.** Merge the done task branches in a code-gated integrate step. Give each criterion a verifier that did not write the code. Write each check in a form that runs under the host hooks. Call the advisor before done. Done when each criterion has a pass, fail, or unrun verdict with evidence.

In `design` mode, start from `assets/workflow-template.js`. It implements steps 2 to 8.
The template fits one shape: plan, implement, and verify. For review, research, audit, or discovery work, take the shape from the workflow-authoring quality patterns. Then apply steps 4 to 7 to each agent call.
In the dotfiles repository, `tests/workflows/claude-workflows-template.test.mjs` proves its control flow. That path does not exist in other repositories.
In `review` mode, run steps 2 to 8 as checks against the target. Also check the target against workflow-authoring:

- A barrier whose next stage does not need all prior results. The fix is a `pipeline()`.
- A runtime limit that the script can hit. Check the concurrency, agent, and per-call item caps.
- `args` sent as a JSON string.
- A `workflow()` call inside a child workflow. Nesting allows one level only.

Also check the target against `references/environment.md`:

- A prompt or a check that tells an agent to use a tool that a host hook denies.
- An agent that only runs `git` or `gh` commands. Code or one script can do that work.
- An argument parser that rejects a bare string or a missing optional field before it suggests the correct form.
- A `needs-*` or `blocked` status with no resume input. A rerun that repeats completed stages is a defect.
- A human approval loop built from several stateless runs. Move that loop into the calling skill.

## Output

Design mode returns the script and a stage table:

```markdown
| Stage | Agent (type, model) | Schema | Code gate after it | Failure path |
|---|---|---|---|---|
```

Review mode returns a summary line, then findings ordered by severity:

```markdown
| # | Severity | Practice | Location (file:line) | Issue | Fix |
|---|---|---|---|---|---|
```

Tag each finding `<certain>` or `<speculative>`. Drop a finding that you cannot tie to a line.

## What this skill never does

- It never lets an implementer grade its own work.
- It never gives the advisor write tools.
- It never writes an unbounded retry or continuation loop.
- It never tells an agent to use a tool that a host hook denies.
- It never drops coverage silently; each skipped item goes to `log()` and the result.

## References

- `references/schemas.md` — read at step 4, or when a review finds free-text status fields.
- `references/repair.md` — read at step 5, or when outputs fail validation.
- `references/budget-recovery.md` — read at step 6, or when agents die, stall, or run out of context.
- `references/ontology.md` — read at step 2, or when the run validates tasks instead of outcomes.
- `references/advisor.md` — read at step 3, or when a design has no pre-implementation review.
- `references/determinism.md` — read at step 7, or when prompts carry work that code can do.
- `references/environment.md` — read at step 1, at step 8, and when a stage fails on a hook, a guard, or a missing tool.
- `references/sources.md` — read when a claim needs its source URL.
- `evals/README.md` — read before you change this skill. The cases come from failed runs of real workflows.
- `assets/workflow-template.js` — read in design mode before you write the script.
