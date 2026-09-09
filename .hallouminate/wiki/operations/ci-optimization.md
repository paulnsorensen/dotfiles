# CI optimization measurements

The measurement helper keeps CI wait separate from local command timing.
A local speedup cannot establish a shorter CI wait.[^cli]

## Import-only boundary

`skills/ci-optimize/scripts/ci_optimize.py` imports captures; it does not run benchmarks or call GitHub.
Existing tools collect evidence under the user's command and credential policy.
This boundary keeps deterministic arithmetic separate from source edits and remote actions.[^cli]

Python's standard library supplies JSON parsing, timestamp arithmetic, and descriptive statistics.
The helper adds no runtime dependency or benchmark service.
It exposes three commands: `ci`, `local`, and `compare`.[^cli]

## CI wait and attempt identity

Full wait starts at run creation and ends at the latest selected job completion.
This includes pre-start delay without claiming that all delay is runner queue time.
Parallel job durations are diagnostics, not values to add for full wait.
The capture must retain every attempt-specific jobs page and explicit expected and selected job IDs.[^attempts]

Version 1 excludes reruns from primary wait comparison.
The verified capture contract has no independent attempt-creation anchor for a rerun.
Reusing the original creation time would include the gap before the rerun.
Job timings and exclusion reasons remain available for diagnosis.[^cli]

## Comparison limits

Failed, cancelled, timed-out, incomplete, and warmup records remain visible.
Only eligible observations enter successful-sample statistics.
Minimum sample counts are explicit; statistics describe observations, not causation.
Comparisons preserve revision provenance but require matching workload and validation identity.[^tests]

Environment, cache-state, and local-command changes require exact acknowledgement.
An acknowledgement cannot waive a different workflow, event, workload, or validation contract.
It also cannot prove that checks and artifacts remain equivalent.
The optimization workflow must verify those properties separately.[^tests]

## Repository gates

The Bats wrapper includes helper unit tests in the existing test gate.
The Python lint recipe checks both the helper and its tests.
No repository verification command changes its name or adopts implicit autofix.[^gates]

Related: [[just-check-read-only-gate]] records why generic task-runner defaults cannot replace this repository's verification policy.

[^cli]: `skills/ci-optimize/scripts/ci_optimize.py`, `ci`, `local`, and `compare` commands.
[^attempts]: [GitHub attempt jobs endpoint](https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run-attempt); [GitHub run attempt endpoint](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run-attempt).
[^tests]: `tests/ci_optimize/` exercises the CLI data and comparison contracts.
[^gates]: `tests/ci-optimize.bats`; `justfile`, `lint-python` and `check` recipes.

*Source: approved ci-optimize implementation contract and endpoint verification · Updated: 2026-09-08 · Supersedes: none*
