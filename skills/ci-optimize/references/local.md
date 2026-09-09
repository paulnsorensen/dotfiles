# Local timing adapters

Use the repository's existing timing tool. Define a safe command, revision, environment, cache state, workload label, run count, warmup policy, and evidence file before execution.

Do not require Hyperfine installation. When Hyperfine is available, use explicit failure-preserving flags:

```bash
hyperfine_json=hyperfine.json
[[ ! -e "$hyperfine_json" ]] || { printf 'refusing to replace %s\n' "$hyperfine_json" >&2; exit 1; }
hyperfine --ignore-failure --runs 10 --warmup 0 --export-json "$hyperfine_json" 'just check'
```

The JSON export records `command`, `times`, and `exit_codes` in each result. Keep every result row. A missing `times` array, unequal `times` and `exit_codes` lengths, or an unknown exit code is not a successful duration. A null exit code is unknown and remains a signal, not success.

## Adapter example

For a synthetic smoke test, use this `hyperfine.json` content:

```json
{"results":[{"command":"just check","times":[12.4,15.1],"exit_codes":[0,1]}]}
```

Run this standard-library adapter from the consumer repository. It refuses to replace an existing output file.

```bash
HYPERFINE_JSON=hyperfine.json
LOCAL_INPUT_JSON=local-input.json
python3 - "$HYPERFINE_JSON" "$LOCAL_INPUT_JSON" abc123 macos-arm64 warm "repository gates" <<'PY'
import json
import math
import sys
from pathlib import Path

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
revision, environment, cache_state, workload_label = sys.argv[3:]
payload = json.loads(input_path.read_text(encoding="utf-8"))
results = payload.get("results")
if not isinstance(results, list) or len(results) != 1:
    raise SystemExit("expected one Hyperfine result")
result = results[0]
command = result.get("command")
if not isinstance(command, str) or not command:
    raise SystemExit("result.command must be non-empty")
times = result.get("times")
exit_codes = result.get("exit_codes")
if not isinstance(times, list) or not isinstance(exit_codes, list):
    raise SystemExit("result times and exit_codes must be lists")
if len(times) != len(exit_codes):
    raise SystemExit("result times and exit_codes lengths differ")

def duration(value):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SystemExit("duration must be numeric or null")
    if not math.isfinite(value) or value < 0:
        raise SystemExit("duration must be finite and non-negative")
    return value

samples = []
for index, (time, exit_code) in enumerate(zip(times, exit_codes, strict=True), 1):
    if exit_code is None:
        raise SystemExit(f"sample-{index}: null exit code is unknown; collect status evidence before adapting")
    elif isinstance(exit_code, bool) or not isinstance(exit_code, int):
        raise SystemExit(f"sample-{index}: exit_code must be an integer")
    elif exit_code == 0:
        status = "success"
    else:
        status = "failed"
    samples.append({
        "id": f"hyperfine-{index}",
        "status": status,
        "duration_seconds": duration(time),
        "exit_code": exit_code,
        "warmup": False,
    })

output = {
    "schema_version": 1,
    "source": "local",
    "command": command,
    "revision": revision,
    "environment": environment,
    "cache_state": cache_state,
    "workload_label": workload_label,
    "benchmark_source": {"tool": "hyperfine", "evidence_file": str(input_path)},
    "samples": samples,
}
encoded = json.dumps(output, indent=2, sort_keys=True) + "\n"
try:
    with output_path.open("x", encoding="utf-8") as stream:
        stream.write(encoded)
except FileExistsError as error:
    raise SystemExit(f"refusing to replace {output_path}") from error
PY
```

The adapter rejects null exit codes because their cause is unavailable. It leaves the raw export unchanged and writes no local input. Collect status evidence before creating local input. Do not fabricate cancellation or timeout.

The resulting input has this shape:

```json
{
  "schema_version": 1,
  "source": "local",
  "command": "just check",
  "revision": "abc123",
  "environment": "macos-arm64",
  "cache_state": "warm",
  "workload_label": "repository gates",
  "benchmark_source": {"tool": "hyperfine", "evidence_file": "hyperfine.json"},
  "samples": [
    {"id": "hyperfine-1", "status": "success", "duration_seconds": 12.4, "exit_code": 0, "warmup": false},
    {"id": "hyperfine-2", "status": "failed", "duration_seconds": 15.1, "exit_code": 1, "warmup": false}
  ]
}
```

Map every measured attempt. Use `failed`, `cancelled`, or `timed_out` only when external evidence supports that status. Preserve a supplied duration only when it is finite and nonnegative. Do not classify a warm cache as a cause. Local evidence cannot establish CI wait improvement.

The Hyperfine result shape is documented in [`benchmark_result.rs`](https://github.com/sharkdp/hyperfine/blob/master/src/benchmark/benchmark_result.rs) and [`export/json.rs`](https://github.com/sharkdp/hyperfine/blob/master/src/export/json.rs).
