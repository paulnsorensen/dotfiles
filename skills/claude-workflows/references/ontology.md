# Spec and task ontology

Read at Flow step 2, or when a run validates tasks instead of outcomes.

## Entities

| Entity | ID | Fields | Written by | Mutable after planning |
|---|---|---|---|---|
| Goal | none | one sentence | user | no |
| Criterion | `AC-n` | `statement` (one observable outcome), `check_kind`, `check` (exact command, test, or target) | planner | no |
| Task | `T-n` | `brief`, `satisfies[]` (criterion IDs), `depends_on[]` (task IDs) | planner | no |
| Outcome | `T-n` | `status`, `completed[]`, `remaining[]`, `checkpoint` | implementer | yes |
| Verdict | `AC-n` | `passes`, `evidence` | verifier | yes |
| Open question | none | text | planner | answered by user |

Criteria are the contract. Tasks are a plan to meet them. Verdicts attach to criteria, not to tasks.

## Code checks before any write

1. Each criterion has a statement and an exact check.
2. Each task satisfies at least one criterion.
3. Each criterion has at least one task.
4. Each `satisfies` and `depends_on` reference resolves.
5. The task graph has no cycle. A topological sort gives the execution waves.
6. `open_questions` is empty. Otherwise return `needs-input` to the user. Spec-kit has the same gate for `[NEEDS CLARIFICATION]` markers [s13].

A barrier per wave is correct, because a task needs the results of its dependencies.

## Validation

1. Judge the end state, not the steps. Agents take valid different paths [s12].
2. Give each criterion a fresh verifier that did not implement it. The verifier runs the check itself.
3. Treat implementer claims as leads, not evidence. Agents marked features done after unit tests passed while the feature failed [s9].
4. Prefer end-to-end checks to inspection.
5. Freeze criteria during implementation. Only verdict fields change. Anthropic found that agents overwrite JSON less often than Markdown [s9].
6. When implementation shows that a criterion is wrong, stop. Replan through the advisor. Never edit the criterion in place.
7. Fail a criterion in code when its tasks are not done. Do not spawn a verifier for it.
8. Use one rubric judge with pass or fail for clear-answer outputs [s12]. Use adversarial refuters for contested findings.

## Related formats

- Spec-kit writes acceptance scenarios as tests inside the spec [s13].
- Kiro splits requirements, design, and tasks, and adds an analyze step for inconsistencies [s14].
- Anthropic's long-running harness keeps a JSON feature list where agents change only `passes` [s9].
