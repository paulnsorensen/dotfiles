# Measurement schemas and comparison

The helper accepts schema version `1` only. It validates container shapes, timestamps, finite nonnegative durations, identity uniqueness, required enum values, and interval order. It returns one JSON object on standard output when no output path is supplied. Malformed input and unsupported versions return exit code `2`; runtime failures return `1`. Treat context values that trim to case-insensitive `unknown` as unknown.

## CI input

Set `source` to `github-actions`. Provide a nonempty `captures` list. Each capture contains `run`, `job_pages`, `collection`, and `context`.

`run` includes `id`, `workflow_id`, `event`, `head_sha`, `run_attempt`, `status`, `conclusion`, and `created_at`. `job_pages` contains every captured page with `total_count` and `jobs`. `collection` names `run_id`, `attempt`, `selected_job_ids`, `expected_job_ids`, and `captured_at`. IDs are unique positive integers. Selected IDs are a subset of expected IDs, and every expected ID exists in the complete capture.

`context` includes string values for `repository`, `workload_label`, and `validation_contract`. It may include `workflow`, `workflow_id`, `event`, `event_class`, `runner_toolchain`, and `cache_state`. The helper creates one observation per capture. Jobs outside the selected set remain recorded but do not define the metric's end.

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

Set `source` to `local`. Provide command, revision, environment, cache state, workload label, benchmark source, and a nonempty `samples` list. Each sample has a unique ID, status, duration, exit code, and Boolean warmup. Allowed statuses are `success`, `failed`, `cancelled`, and `timed_out`.

Success requires exit code `0` and a finite nonnegative duration. Failure requires a nonzero integer exit code. Cancelled and timed-out records may have a null exit code. Unsuccessful records may have a null duration. Any supplied duration remains subject to finite nonnegative validation.

## Normalized dataset

The helper emits `schema_version`, `source`, `context`, `observations`, and `exclusions`. Each observation retains identity, duration or null, eligibility, reasons, and provenance. CI observations retain creation and selected-completion timestamps plus job summaries. CI provenance retains each page `total_count`, collection `expected_job_ids`, collection `selected_job_ids`, and collection `captured_at`. Local observations retain command and measurement metadata. Exclusions remain visible.

## Acknowledgement

An acknowledgement file contains `schema_version: 1`, a nonempty `plan_ref`, and `differences`. Each difference is an exact `field`, `before`, and `after` triple. Allowed fields are `environment`, `cache_state`, and `local command`.

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

Use `--minimum-samples N` with a positive integer. The report contains `comparability`, `reasons`, `before`, `after`, `delta`, `minimum_samples`, `acknowledgement_plan_ref`, and `context_differences`. Each side reports eligible count, excluded count, median, minimum, and maximum. Delta reports saved seconds and saved percent, or null percent when the baseline median is zero. Direction is `observed_faster`, `observed_slower`, `unchanged`, or `unavailable`.

Mixed CI and local sources, incompatible contexts, insufficient eligible samples, or missing measurements produce a limitation. They do not produce a verified CI improvement claim.
