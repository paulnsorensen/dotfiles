# GitHub Actions capture

Use the GitHub CLI as the transport. Capture the selected run and the complete job population for the same run attempt, for every run in the cohort.

## Capture example

Capture at least the planned `--minimum-samples` count of runs, plus headroom for exclusions. Headroom covers a rerun or an incomplete job page. The loop below accumulates one `captures` array before publishing it once.

```bash
set -euo pipefail
repo=OWNER/REPOSITORY
attempt=1
# example: minimum-samples 3 plus headroom
run_ids=(123456789 123456790 123456791 123456792 123456793)
capture=CAPTURES.json
tmp_capture=$(mktemp "$capture.tmp.XXXXXX")
trap 'rm -f "$tmp_capture"' EXIT
captures='[]'
for run_id in "${run_ids[@]}"; do
  run_json=$(gh api "repos/$repo/actions/runs/$run_id/attempts/$attempt" \
    | jq '{id, workflow_id, event, head_sha, run_attempt, status, conclusion, created_at}')
  jobs_json=$(gh api --paginate --slurp \
    "repos/$repo/actions/runs/$run_id/attempts/$attempt/jobs?per_page=100" \
    | jq '[.[] | {total_count, jobs: [.jobs[] | {id, run_id, run_attempt, name, status, conclusion, started_at, completed_at}]}]')
  selected_ids=$(jq '[.[].jobs[].id]' <<<"$jobs_json")
  captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  entry=$(jq -n \
    --argjson run "$run_json" \
    --argjson pages "$jobs_json" \
    --arg repo "$repo" \
    --argjson run_id "$run_id" \
    --argjson attempt "$attempt" \
    --argjson selected_ids "$selected_ids" \
    --arg captured_at "$captured_at" \
    '{
      run: $run,
      job_pages: $pages,
      collection: {
        run_id: $run_id,
        attempt: $attempt,
        selected_job_ids: $selected_ids,
        expected_job_ids: $selected_ids,
        captured_at: $captured_at
      },
      context: {
        repository: $repo,
        workflow_id: ($run.workflow_id | tostring),
        event_class: $run.event,
        workload_label: "selected validation jobs",
        validation_contract: "unknown",
        runner_toolchain: "unknown",
        cache_state: "unknown"
      }
    }')
  captures=$(jq --argjson entry "$entry" '. + [$entry]' <<<"$captures")
done
jq -n --argjson captures "$captures" '{schema_version: 1, source: "github-actions", captures: $captures}' >| "$tmp_capture"
if ! ln "$tmp_capture" "$capture"; then
  printf 'refusing to replace %s\n' "$capture" >&2
  exit 1
fi
rm -f "$tmp_capture"
trap - EXIT
```

`selected_ids` defaults to every captured job; override it before publishing when the approved job set is a subset of the captured jobs. Replace `validation_contract`, `runner_toolchain`, and `cache_state` with real values before comparing: the helper treats `unknown` as unresolved context and blocks a comparison built from it. The hard link publishes without clobbering a concurrent capture.

Record the requested repository, run ID, attempt, selected job IDs, expected job IDs, capture timestamp, source revision, and context labels. The input capture must contain the run metadata and all attempt-specific job pages. Preserve `jobs[].run_id` and `jobs[].run_attempt` when the API returns them.

The API page population is authoritative for this capture. Do not substitute a workflow summary, a different attempt, or a single jobs page. Follow the repository's authentication policy. Never store tokens, environment dumps, or raw logs in the measurement dataset. The `jq` filters above keep only the fields the helper reads.

## Full-wait rule

For an eligible initial attempt, calculate:

```text
full_wait_seconds = latest selected job completion - run.created_at
```

A rerun remains diagnostic and is always ineligible for primary full-wait in schema version 1. The input has no attempt-creation anchor field. Do not use `run.updated_at` as completion. A missing expected job or missing selected completion makes the observation incomplete, not rejected.

## Acceptance check

A shorter wait is not enough. Compare the validation contract separately. Confirm that required checks, coverage, artifacts, and failure handling remain present. Report separate observations for multiple workflows unless their measurement boundary is shared.

Consult the [workflow-run attempt endpoint](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run-attempt) and [attempt jobs endpoint](https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run-attempt) when API fields or pagination rules change.
