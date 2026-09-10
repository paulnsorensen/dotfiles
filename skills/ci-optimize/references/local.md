# Local timing adapters

Use the repository's existing timing tool. Define a safe command, revision, environment, cache state, workload label, run count, warmup policy, and evidence file before execution.

Do not require Hyperfine installation. When Hyperfine is available, anchor `--runs` to the planned `--minimum-samples` value plus headroom for warmup or failed rows. Publish the export without clobbering a concurrent run:

```bash
set -euo pipefail
minimum_samples=3
runs=$((minimum_samples + 2))
tmp_export=$(mktemp hyperfine.json.XXXXXX)
hyperfine --ignore-failure --runs "$runs" --warmup 0 --export-json "$tmp_export" 'just check'
hyperfine_json=hyperfine.json
if ! ln "$tmp_export" "$hyperfine_json"; then
  printf 'refusing to replace %s\n' "$hyperfine_json" >&2
  exit 1
fi
rm -f "$tmp_export"
```

The JSON export records `command`, `times`, and `exit_codes` in each result. Keep every result row. A missing `times` array, unequal `times` and `exit_codes` lengths, or an unknown exit code is not a successful duration. A null exit code is unknown and remains a signal, not success.

## Import with `from-hyperfine`

Convert the published export with the helper's `from-hyperfine` subcommand. It is import-only: it reads the export, builds samples, and writes a normalized local dataset. It never runs the workload.

```bash
python3 "$CI_OPTIMIZE_HELPER" from-hyperfine \
  --input hyperfine.json \
  --command 'just check' \
  --revision abc123 \
  --environment macos-arm64 \
  --cache-state warm \
  --workload-label "repository gates" \
  --tool-version "$(hyperfine --version)" \
  --output LOCAL.json
```

`--sample-prefix` names each sample; it defaults to `sample`. `--tool-version` records the Hyperfine version; it defaults to `unknown`. The helper rejects an export with zero or more than one result, a missing or unequal-length `times`/`exit_codes` pair, or a non-integer exit code. It maps a nonzero exit code to `failed`. Add `--force` only to replace an existing explicit output file.

The resulting dataset has this shape:

```json
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
```

Map every measured attempt. Use `failed`, `cancelled`, or `timed_out` only when external evidence supports that status. Preserve a supplied duration only when it is finite and nonnegative. Do not classify a warm cache as a cause. Local evidence cannot establish CI wait improvement.

The Hyperfine result shape is documented in [`benchmark_result.rs`](https://github.com/sharkdp/hyperfine/blob/master/src/benchmark/benchmark_result.rs) and [`export/json.rs`](https://github.com/sharkdp/hyperfine/blob/master/src/export/json.rs).
