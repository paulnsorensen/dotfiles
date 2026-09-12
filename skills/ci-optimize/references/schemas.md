# Measurement schemas and comparison

The helper accepts schema version `1` only. It validates container shapes, timestamps, finite nonnegative durations, identity uniqueness, required enum values, and interval order. It returns one JSON object on standard output when no output path is supplied. Treat context values that trim to case-insensitive `unknown` as unknown.

## Errors and exit codes

Every input error is one line. A `ci` or `local` error has no `<path>` prefix. For example, `ci-optimize: captures[0]: run.id must be an integer`. Only `compare`'s `observations[i]` error carries the path. The form is `ci-optimize: <path>: observations[i]: <message>`. An argument, acknowledgement, or output error is `ci-optimize: <message>`.

| Exit code | Meaning |
| --- | --- |
| `2` | Malformed input, an unsupported schema version, or JSON nested too deeply. |
| `1` | A runtime or write failure, including an existing output path (the message names `--force` as the way to overwrite it). |
| `0` | The command emitted valid JSON output. |

## CI input

Set `source` to `github-actions`. Provide a nonempty `captures` list. Each capture contains `run`, `job_pages`, `collection`, and `context`.

`run` includes `id`, `workflow_id`, `event`, `head_sha`, `run_attempt`, `status`, `conclusion`, and `created_at`. `job_pages` contains every captured page with `total_count` and `jobs`; every page must report the same `total_count`. `collection` names `run_id`, `attempt`, `selected_job_ids`, `expected_job_ids`, and `captured_at`. IDs are unique positive integers. Selected IDs are a subset of expected IDs; a missing expected ID makes the observation incomplete, not rejected.

`context` includes string values for `repository`, `workload_label`, and `validation_contract`. It may include `workflow`, `workflow_id`, `event`, `event_class`, `runner_toolchain`, and `cache_state`. The helper creates one observation per capture. Jobs outside the selected set remain recorded but do not define the metric's end. A missing expected job is `missing_expected_jobs`. A larger job population than the declared total is `inconsistent_job_population`. A smaller page set than the declared total is `incomplete_job_pages`. An unavailable selected job is `selected_jobs_unavailable`. None of these is a hard input error.

A complete two-run cohort has this shape:

```json
{
  "schema_version": 1,
  "source": "github-actions",
  "captures": [
    {
      "context": {
        "repository": "owner/repo",
        "workflow": "verify",
        "workflow_id": "7",
        "event_class": "pull_request",
        "workload_label": "required validation",
        "validation_contract": "required-checks-v1",
        "runner_toolchain": "ubuntu-python-3.12",
        "cache_state": "warm"
      },
      "run": {
        "id": 99,
        "workflow_id": 7,
        "event": "pull_request",
        "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
        "created_at": "2026-01-01T00:00:00Z"
      },
      "job_pages": [{
        "total_count": 2,
        "jobs": [
          {"id": 101, "run_id": 99, "run_attempt": 1, "name": "lint", "status": "completed", "conclusion": "success", "started_at": "2026-01-01T00:00:10Z", "completed_at": "2026-01-01T00:05:00Z"},
          {"id": 102, "run_id": 99, "run_attempt": 1, "name": "test", "status": "completed", "conclusion": "success", "started_at": "2026-01-01T00:00:20Z", "completed_at": "2026-01-01T00:08:00Z"}
        ]
      }],
      "collection": {"run_id": 99, "attempt": 1, "selected_job_ids": [101, 102], "expected_job_ids": [101, 102], "captured_at": "2026-01-01T00:10:00Z"}
    },
    {
      "context": {
        "repository": "owner/repo",
        "workflow": "verify",
        "workflow_id": "7",
        "event_class": "pull_request",
        "workload_label": "required validation",
        "validation_contract": "required-checks-v1",
        "runner_toolchain": "ubuntu-python-3.12",
        "cache_state": "warm"
      },
      "run": {
        "id": 100,
        "workflow_id": 7,
        "event": "pull_request",
        "head_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
        "created_at": "2026-01-02T00:00:00Z"
      },
      "job_pages": [{
        "total_count": 2,
        "jobs": [
          {"id": 201, "run_id": 100, "run_attempt": 1, "name": "lint", "status": "completed", "conclusion": "success", "started_at": "2026-01-02T00:00:10Z", "completed_at": "2026-01-02T00:04:30Z"},
          {"id": 202, "run_id": 100, "run_attempt": 1, "name": "test", "status": "completed", "conclusion": "success", "started_at": "2026-01-02T00:00:20Z", "completed_at": "2026-01-02T00:07:30Z"}
        ]
      }],
      "collection": {"run_id": 100, "attempt": 1, "selected_job_ids": [201, 202], "expected_job_ids": [201, 202], "captured_at": "2026-01-02T00:10:00Z"}
    }
  ]
}
```

## Local input

Set `source` to `local`. Provide command, revision, environment, cache state, workload label, benchmark source, and a nonempty `samples` list. Each sample has a unique ID, status, and Boolean `warmup`; duration and exit code may be null for unsuccessful samples. Allowed statuses are `success`, `failed`, `cancelled`, and `timed_out`.

Success requires exit code `0` and a finite nonnegative duration. Failure requires a nonzero integer exit code. Cancelled and timed-out records may have a null exit code. Unsuccessful records may have a null duration. Any supplied duration remains subject to finite nonnegative validation.

## from-hyperfine

The `from-hyperfine` subcommand imports one Hyperfine export into a normalized local dataset. It does not run the workload. Required flags are `--input`, `--command`, `--revision`, `--environment`, `--cache-state`, and `--workload-label`. Optional flags are `--sample-prefix` (default `sample`), `--tool-version`, `--captured-at`, `--output`, and `--force`. The export must contain exactly one result. The `times` and `exit_codes` lists must have equal lengths. Each duration must be finite and nonnegative. Each exit code must be an integer. A nonzero exit code maps the sample to `failed`; a missing or null exit code is rejected as unknown. When omitted, `--tool-version` leaves `benchmark_source.version` absent.

## Normalized dataset

The helper emits `schema_version`, `source`, `context`, `observations`, and `exclusions`. A CI dataset also emits `context_variants`, an integer count of distinct observation contexts.

Each CI observation retains identity, context, status, conclusion, timestamps, duration, eligibility, reasons, jobs, selected names, and provenance. `pre_start_seconds` is the earliest selected job start minus run creation, or null when no selected job started. CI provenance retains `run_id`, `attempt`, selected and expected job IDs, reconciled `total_count`, and `captured_at`.

Each local observation retains identity, status, exit code, warmup, duration, eligibility, reasons, and provenance. Dataset context carries command, revision, environment, cache state, workload label, benchmark source, and optional `captured_at`.

Exclusions remain visible: each entry pairs an observation's `identity` and `reasons`.

A normalized CI dataset with one observation has this shape:

```json
{
  "schema_version": 1,
  "source": "github-actions",
  "context": {"repository": "owner/repo", "workload_label": "required validation", "validation_contract": "required-checks-v1"},
  "context_variants": 1,
  "observations": [
    {
      "identity": {"run_id": 99, "run_attempt": 1, "workflow_id": 7, "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "event": "pull_request"},
      "context": {"repository": "owner/repo", "workload_label": "required validation", "validation_contract": "required-checks-v1"},
      "status": "completed",
      "conclusion": "success",
      "created_at": "2026-01-01T00:00:00Z",
      "selected_completed_at": "2026-01-01T00:08:00+00:00",
      "duration_seconds": 480.0,
      "eligibility": true,
      "reasons": [],
      "pre_start_seconds": 10.0,
      "jobs": [{"id": 101, "name": "lint", "status": "completed", "conclusion": "success", "selected": true, "started_at": "2026-01-01T00:00:10Z", "completed_at": "2026-01-01T00:08:00Z", "duration_seconds": 470.0}],
      "selected_job_names": ["lint"],
      "provenance": {"run_id": 99, "selected_job_ids": [101], "expected_job_ids": [101], "total_count": 1, "attempt": 1, "captured_at": "2026-01-01T00:10:00Z"}
    }
  ],
  "exclusions": []
}
```

## Acknowledgement

An acknowledgement file contains `schema_version: 1`, a nonempty `plan_ref`, and `differences`. Pass it with `compare --acknowledgements <file>`. Each difference is an exact `field`, `before`, and `after` triple. Allowed fields are `environment`, `cache_state`, and `local command`.

This acknowledgement records an approved context change:

```json
{
  "schema_version": 1,
  "plan_ref": "plan/ci-runner-2026-01-03",
  "differences": [
    {"field": "environment", "before": "ubuntu-python-3.12", "after": "ubuntu-python-3.13"},
    {"field": "cache_state", "before": "cold", "after": "warm"}
  ]
}
```

An acknowledgement can make these exact context differences comparable only when each triple matches an observed difference. It cannot waive source kind, repository, workflow, event class, workload label, validation contract, missing context, or unknown values. It records intent. It does not prove causation or authorize edits.

## Compare and report

Use `--minimum-samples N` with a positive integer. `compare` accepts only the nested `context` shape: `{"source": ..., "context": {...}, "observations": [...], "exclusions": [...]}`. A flat or hybrid dataset without a nested `context` object is rejected.

The report contains `schema_version`, `source`, `comparability`, `reasons`, `before`, `after`, `delta`, `minimum_samples`, acknowledgement data, context differences, and provenance. Each side reports eligible count, excluded count, median, minimum, and maximum. `context_differences` lists every observed difference. `acknowledged_differences` lists only entries matched by the acknowledgement file.

`provenance.before` and `provenance.after` carry the evidence for each side's numbers. CI provenance includes `repository`, `workflow_id`, `event`, and every eligible run's `run_id`, `run_attempt`, and `head_sha`. Local provenance includes `revision`, `command`, and `benchmark_source`. Local comparison context also includes `revision`, which links a saved-percent claim to the measured tree.

Delta reports saved seconds and saved percent, or null percent when the baseline median is zero. Direction is `observed_faster`, `observed_slower`, `unchanged`, or `unavailable`.

For `compare`, exit `0` means that the helper emitted a report. Accept a comparison only when `comparability` is `true`, both sides meet `minimum_samples`, and the validation contract remains preserved. Mixed CI and local sources, incompatible contexts, insufficient eligible samples, or missing measurements produce a limitation. They do not produce a verified CI improvement claim.

Report CI and local results in separate sections. Describe observations, not causation.
