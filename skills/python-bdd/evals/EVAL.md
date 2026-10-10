# Python BDD evaluation intent

This file states author intent before candidate results. It is independent of the current skill body.

## Questions

- Does an explicit user request produce executable behavior specifications for a Python product?
- Do scenarios exercise real external boundaries and exact visible results?
- Does brownfield work preserve the existing environment, tests, and behavior?
- Do tests detect a representative production regression and run against an installed artifact?
- Does the response distinguish focused local checks, full CI parity, and unrun checks?
- Does the user-only skill avoid implicit routing on unrelated requests?

## Behaviors

- **BDD-01 — Product contract.** Specify observable outcomes before implementation. For the ledger case, accept positive amounts with at most two decimal places. Reject `abc`, zero, negative, and more precise amounts without changing saved state. A fresh process reports entries and their total in one stable currency. The candidate may choose command names and output syntax. Its oracle must precede observations and must not change to match a failure.
- **BDD-02 — Real boundary.** Run steps through a CLI or HTTP interface and persistent storage. Do not substitute a mocked service, private method, or in-memory duplicate for the product boundary.
- **BDD-03 — Isolation and exactness.** Give each scenario isolated persistent state. Check exact externally visible output or an exact parsed response, including error and unchanged-state outcomes.
- **BDD-04 — Brownfield preservation.** Inspect existing tests, dependency manager, and CI before edits. Preserve useful unit tests and unrelated behavior. Do not replace Behave or Poetry merely to use the new uv and pytest-bdd preference.
- **BDD-05 — Regression sensitivity.** Make one reversible, representative production defect cause the relevant BDD test to fail. Restore production code and show the test passes. Do not weaken the oracle.
- **BDD-06 — Installed artifact.** Exercise the built, installed wheel in an isolated environment. Do not treat source-tree imports as installation proof.
- **BDD-07 — Gate parity.** Report focused local commands and the repository's full CI-equivalent commands with exact pass, fail, and unrun states. Do not claim speed gains without a measured comparison.
- **BDD-08 — Time discipline.** Under a time limit, preserve useful unit tests and prioritize one high-value end-to-end behavior over broad test churn.
- **BDD-09 — Invocation boundary.** This skill is user-only. An unrelated or unit-only request must not implicitly invoke or impose BDD. This is an expected routing behavior, not a guarantee enforced by every harness.
- **BDD-10 — Honest evidence.** Distinguish authored cases, executed checks, and human judgments. Do not infer that green tests prove all requirements.

## Negative Cases

- A test passes through a mock, private method, or duplicated algorithm while the user interface or persistence is broken.
- A rejected amount creates a row, changes a balance, or succeeds with an error-shaped message.
- A candidate rewrites its expected output after observing a failing run.
- A brownfield migration deletes unit tests or rewrites Poetry and Behave without a user request.
- A speed claim uses no before-and-after measurement.
- A unit-only or non-Python request triggers this user-only skill without explicit selection.

## Notes

`cases.json` is a repository-local, runner-neutral case list. It is not a SkillEvaluator, skillz, Anthropic, or other runner schema. The object keys and rubrics are instructions for a human or an independently selected runner; they are not executable assertions. Do not launch autoimprove, paid model calls, or a custom eval engine from this directory. Keep these requirements stable when observations differ. Record new gaps separately and revise intent only through an explicit review.
