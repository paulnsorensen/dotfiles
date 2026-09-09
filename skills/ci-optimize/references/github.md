# GitHub Actions capture

Use the GitHub CLI as the transport. Capture the selected run and the complete job population for the same run attempt.

## Capture example

```bash
set -euo pipefail
run_id=123456789
attempt=1
repo=OWNER/REPOSITORY
capture=CAPTURES.json
[[ ! -e "$capture" ]] || { printf 'refusing to replace %s\n' "$capture" >&2; exit 1; }
run_json=$(gh api "repos/$repo/actions/runs/$run_id/attempts/$attempt")
jobs_json=$(gh api --paginate --slurp \
  "repos/$repo/actions/runs/$run_id/attempts/$attempt/jobs?per_page=100")
tmp_capture="$capture.tmp.$$"
trap 'rm -f "$tmp_capture"' EXIT
jq -n \
  --argjson run "$run_json" \
  --argjson pages "$jobs_json" \
  --arg repo "$repo" \
  --argjson run_id "$run_id" \
  --argjson attempt "$attempt" \
  --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    schema_version: 1,
    source: "github-actions",
    captures: [{
      run: $run,
      job_pages: $pages,
      collection: {
        run_id: $run_id,
        attempt: $attempt,
        selected_job_ids: [101, 102],
        expected_job_ids: [101, 102],
        captured_at: $captured_at
      },
      context: {
        repository: $repo,
        workflow: ($run.name // ($run.workflow_id | tostring)),
        workflow_id: ($run.workflow_id | tostring),
        event_class: $run.event,
        workload_label: "selected validation jobs",
        validation_contract: "record required checks separately",
        runner_toolchain: "record from job metadata",
        cache_state: "unknown"
      }
    }]
  }' > "$tmp_capture"
if ! ln "$tmp_capture" "$capture"; then
  printf 'refusing to replace %s\n' "$capture" >&2
  exit 1
fi
rm "$tmp_capture"
trap - EXIT
```

The wrapper contains the run metadata, every attempt-specific job page, collection identity, selected IDs, expected IDs, and context labels. The hard link publishes without clobbering a concurrent capture.

Record the requested repository, run ID, attempt, selected job IDs, expected job IDs, capture timestamp, source revision, and context labels. The input capture must contain the run metadata and all attempt-specific job pages. Preserve `jobs[].run_id` and `jobs[].run_attempt` when the API returns them.

The API page population is authoritative for this capture. Do not substitute a workflow summary, a different attempt, or a single jobs page. Follow the repository's authentication policy. Never store tokens, environment dumps, or raw logs in the measurement dataset.

## Full-wait rule

For an eligible initial attempt, calculate:

```text
full_wait_seconds = latest selected job completion - run.created_at
```

A rerun remains diagnostic and is always ineligible for primary full-wait in schema version 1. The input has no attempt-creation anchor field. Do not use `run.updated_at` as completion. A missing expected job or missing selected completion makes the observation incomplete.

## Acceptance check

A shorter wait is not enough. Compare the validation contract separately. Confirm that required checks, coverage, artifacts, and failure handling remain present. Report separate observations for multiple workflows unless their measurement boundary is shared.

Consult the [workflow-run attempt endpoint](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run-attempt) and [attempt jobs endpoint](https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run-attempt) when API fields or pagination rules change.
