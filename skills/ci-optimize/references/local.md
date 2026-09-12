# Local timing adapters

Use the repository's existing timing tool. Define the command, revision, environment, cache state, and workload label before execution. Define the run count, warmup policy, and evidence file before execution.

Do not require Hyperfine. When it is available, set measured runs to the planned `--minimum-samples` value plus failure headroom:

~~~bash
set -euo pipefail
minimum_samples=3
warmup_runs=3
measured_runs=$((minimum_samples + 2))
tmp_export=$(mktemp hyperfine.json.XXXXXX)
hyperfine --ignore-failure --runs "$measured_runs" --warmup "$warmup_runs" --export-json "$tmp_export" 'just check'
hyperfine_json=hyperfine.json
if ! ln "$tmp_export" "$hyperfine_json"; then
  printf 'refusing to replace %s\n' "$hyperfine_json" >&2
  exit 1
fi
rm -f "$tmp_export"
~~~

Warmup runs are not measured and do not appear in `times`. Extra measured runs provide headroom for failed rows.

The JSON export records `command`, `times`, and `exit_codes` for each result. Keep every result row.

The importer requires a nonempty `times` list, equal `times` and `exit_codes` lengths, finite nonnegative durations, and integer exit codes. It rejects missing or null exit codes as unknown.

Map a nonzero exit code to `failed`. Do not drop that measured row.

## Import with `from-hyperfine`

Convert the export with the helper's `from-hyperfine` subcommand. The subcommand imports data and never runs the workload.

~~~bash
python3 "$CI_OPTIMIZE_HELPER" from-hyperfine \
  --input hyperfine.json \
  --command 'just check' \
  --revision abc123 \
  --environment macos-arm64 \
  --cache-state warm \
  --workload-label "repository gates" \
  --tool-version "$(hyperfine --version)" \
  --output LOCAL.json
~~~

`--sample-prefix` defaults to `sample`. Pass `--tool-version` to record the Hyperfine version. When omitted, the normalizer omits `benchmark_source.version`.

The optional `--captured-at` value records capture time. When omitted, the importer uses the input file modification time.

The helper rejects zero or multiple Hyperfine results, unequal arrays, unknown exit codes, invalid durations, and output replacement without `--force`.

Use `--force` only when you intend to replace an existing explicit output file.

The resulting dataset has this shape:

~~~json
{
  "schema_version": 1,
  "source": "local",
  "context": {
    "command": "just check",
    "revision": "abc123",
    "environment": "macos-arm64",
    "cache_state": "warm",
    "workload_label": "repository gates",
    "benchmark_source": {"tool": "hyperfine", "version": "1.18.0", "evidence_file": "hyperfine.json"},
    "captured_at": "2026-01-01T00:10:00Z"
  },
  "observations": [
    {"identity": {"id": "sample-0"}, "status": "success", "duration_seconds": 12.4, "exit_code": 0, "warmup": false, "eligibility": true, "reasons": [], "provenance": {"tool": "hyperfine", "version": "1.18.0", "evidence_file": "hyperfine.json"}},
    {"identity": {"id": "sample-1"}, "status": "failed", "duration_seconds": 15.1, "exit_code": 1, "warmup": false, "eligibility": false, "reasons": ["failed"], "provenance": {"tool": "hyperfine", "version": "1.18.0", "evidence_file": "hyperfine.json"}}
  ],
  "exclusions": [
    {"identity": {"id": "sample-1"}, "reasons": ["failed"]}
  ]
}
~~~

Map every measured attempt. Use `failed`, `cancelled`, or `timed_out` only when external evidence supports that status.

Preserve a supplied duration only when it is finite and nonnegative. Do not classify a warm cache as a cause.

Local evidence cannot establish CI wait improvement.

The Hyperfine [benchmark result](https://github.com/sharkdp/hyperfine/blob/master/src/benchmark/benchmark_result.rs) and [JSON export](https://github.com/sharkdp/hyperfine/blob/master/src/export/json.rs) define the input shape.
