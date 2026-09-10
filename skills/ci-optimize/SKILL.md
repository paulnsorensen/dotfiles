---
name: ci-optimize
model: sonnet
effort: medium
description: Optimize CI with measured GitHub Actions and local timing evidence. Use for workflow comparisons, speedup validation, and approval-gated change plans.
---

# CI optimization

Measure before changing. Preserve required checks, artifacts, repository gates, and the user's approval boundary.

## Discipline

**Iron Law:** No optimization edit or remote mutation occurs without a measured evidence set and explicit approval of a concrete change plan.

Explicit authorization is required before destructive cleanup, paid infrastructure, source edits, dependency installs, or remote dispatch.

**Red Flags** — stop when you notice these:

- A check or artifact is removed to create a numerical gain.

The rationalization table below covers the other stop conditions.

| Rationalization | Why it fails | Required action |
| --- | --- | --- |
| “The cache change is obvious, so I can apply it now.” | Measurement cannot authorize a source or remote mutation. | Present the plan and wait for approval. |
| “The local command is faster, so CI is faster.” | Local and CI sources measure different systems. | Report them separately. |
| “The jobs run in parallel, so their durations add up.” | Full wait ends at the latest selected completion. | Calculate from run creation. |
| “The rerun has the same workflow, so it is comparable.” | Version 1 excludes reruns and has no attempt-creation anchor field. | Keep timings as diagnostics and exclude primary wait. |
| “Failed benchmark rows add noise.” | Failures expose workload and tool behavior. | Preserve them as exclusions. |

## Workflow

1. Read the repository instructions and identify the authoritative verification commands.
2. Select one GitHub Actions workflow, event class, workload, validation contract, and job set.
3. Capture at least the planned `--minimum-samples` count of runs, plus headroom for exclusions, before proposing a change.
4. Also capture every selected attempt-specific jobs page before proposing a change.
5. Skip local timing for a CI-only request.
6. Otherwise, obtain explicit run-plan authorization for the safe command, cache plan, and expected cost before local timing.
7. Resolve `CI_OPTIMIZE_HELPER` as `$SKILL_DIR/scripts/ci_optimize.py`, where `SKILL_DIR` is this `SKILL.md`'s absolute directory.
8. Import each source from the consumer repository's working directory.
9. Compare compatible normalized datasets with an explicit minimum sample count.
10. Present one concrete plan with affected files, expected benefit, risks, and verification steps.
11. Wait for explicit plan approval before any tracked-source edit, CI dispatch, or remote mutation.
12. After approval, use the repository's existing implementation and verification workflows.
13. Repeat the complete CI capture, including queue and startup delay, then verify checks and artifacts.

Read [references/github.md](references/github.md) for GitHub capture and full-wait rules. Read [references/schemas.md](references/schemas.md) before constructing input, acknowledgement, or comparison files. Read [references/local.md](references/local.md) when adapting local timing output.

Use an existing `justfile` command only when the approved plan needs it. Preserve existing Makefiles and repository gate names.

## Commands

Run these commands from the consumer repository's working directory:

```text
python3 "$CI_OPTIMIZE_HELPER" ci --input CAPTURES.json
python3 "$CI_OPTIMIZE_HELPER" from-hyperfine --input HYPERFINE.json --command 'COMMAND' --revision REVISION --environment ENV --cache-state STATE --workload-label LABEL
python3 "$CI_OPTIMIZE_HELPER" local --input SAMPLES.json
python3 "$CI_OPTIMIZE_HELPER" compare --before BEFORE.json --after AFTER.json --minimum-samples N
```

Use `--output PATH` for a new output file. Add `--force` only to replace an existing explicit output file. The helper does not execute commands, edit workflows, install dependencies, dispatch runs, or commit changes.

## Evidence rules

The primary CI metric is the latest selected job completion minus run creation; do not sum parallel jobs, and do not waive identity, context, or acknowledgement rules.

Read [references/github.md](references/github.md) for full-wait and eligibility rules. Read [references/schemas.md](references/schemas.md) for provenance, exclusion, and acknowledgement rules.
