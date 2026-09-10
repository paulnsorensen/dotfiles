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

## Provenance and the unknown token

Every capture template value must be a real value or the literal `unknown`. The helper's unknown check blocks that token, an empty string, or an absent value. A placeholder reminder sentence would still compare as a real value and mask a context difference.[^cli]

A capture keeps only the fields the normalizer reads, projected out of the full API response. A stored capture cannot leak commit author emails, runner labels, or step logs.[^attempts]

`from-hyperfine` keeps the import-only boundary for Hyperfine users: it reads one export and writes a normalized local dataset, and it never runs the benchmarked command.[^cli]

A comparison report carries a `provenance` block per side: run identity for CI, revision and benchmark source for local. This lets a saved-percent claim trace back to the runs and command that produced it.[^tests]

## Skill approval and deployment

The skill separates a measurement run plan from approval of optimization edits.
A request to optimize does not approve an unspecified cache or workflow change.
Local commands, cache operations, costs, cleanup, installs, and remote actions need explicit run-plan authorization.[^skill]

The pressure test confirms that the skill leaves source unchanged before plan approval.
It also rejects faster CI results when required coverage or its artifact disappears.
This protects the validation contract rather than accepting any smaller number.[^skill]

Claude selects the local skill through `claude.skills`.
Its frontmatter uses the repository's `sonnet` / `medium` route.
The generic skill validator rejects these host fields; the repository's model-effort tests define the applicable contract.[^routing]
The assembler retains nested directories and executable file attributes.
Thus, the helper becomes `exact_scripts/executable_ci_optimize.py` in source state.
Byte tests must use encoded source names, not deployed target names.[^assembly]

The existing OMP and profile paths consume local skills through their own assembly paths.
This selection does not change Codex global skill selection.[^assembly]

## Repository gates

The Bats wrapper includes helper unit tests in the existing test gate.
The Python lint recipe checks both the helper and its tests.
No repository verification command changes its name or adopts implicit autofix.[^gates]

Related: [[just-check-read-only-gate]] records why generic task-runner defaults cannot replace this repository's verification policy.

[^cli]: `skills/ci-optimize/scripts/ci_optimize.py`, `ci`, `local`, and `compare` commands.
[^attempts]: [GitHub attempt jobs endpoint](https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run-attempt); [GitHub run attempt endpoint](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run-attempt).
[^tests]: `tests/ci_optimize/` exercises the CLI data and comparison contracts.
[^skill]: `skills/ci-optimize/SKILL.md`; approval and validation-equivalence pressure scenarios, 2026-09-08.
[^routing]: `tests/agent-skill-model-effort.bats`, selected non-inline skill tests; `skills/harness-doctor/SKILL.md`, existing routing convention.
[^assembly]: `.sync-lib.sh`, `_cz_encode_name` and `sync_claude_chezmoi_sources`; `tests/chezmoi-wiring.bats`, assembled payload test.
[^gates]: `tests/ci-optimize.bats`; `justfile`, `lint-python` and `check` recipes.

*Source: approved ci-optimize implementation contract and endpoint verification · Updated: 2026-09-08 · Supersedes: none*
