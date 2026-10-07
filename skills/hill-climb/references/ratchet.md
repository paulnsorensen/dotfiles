# Ratchet gate

A ratchet gate is a CI check with a threshold per metric.
The threshold moves only toward better values. A regression fails the build.
This keeps every gain after the thread ends.

## Ratchet file

The file is JSON. Commit it beside the code it protects, for example `perf/ratchet/<thread>.json`.
Keep one ratchet file per thread in `perf/ratchet/`.

```json
{
  "metrics": {
    "message-tree.instructions": {
      "command": "node --predictable bench/message-tree.js",
      "direction": "lower",
      "revision": "abc1234",
      "threshold": 1840211,
      "tolerance": 0,
      "unit": "instructions"
    }
  },
  "version": 1
}
```

- `direction` is `lower` or `higher`. It names the better direction.
- `tolerance` is relative slack for `check` only. Use 0 for deterministic counts.
- `revision` records the base commit that the gain was measured against.
- Tolerance is relative to the absolute threshold. A threshold of 0 therefore gets no slack, even with a nonzero tolerance.

## Commands

- `add` records a new metric. It refuses an existing name.
- `check` is the gate. It fails on a regression or a missing metric. `--partial` permits a subset.
- `tighten` moves thresholds to better values. It refuses a worse value and writes nothing.
  It also writes nothing when no metric improved.
- `measure` runs the benchmark N times. It fails when the spread exceeds the tolerance.
  It also fails on a nonzero exit (`error: command-failed`) or after `--timeout` seconds (`error: timeout`).

`check` reports `improved` when a value beats its threshold. Run `tighten` in the same change.

## Wire the gate

Use the repository's existing gate recipe. Do not add a new task runner.
Copy `ratchet.py` into the repository, for example `tools/ratchet.py`. CI must not depend on a home-directory skill path.

```bash
set -euo pipefail
for file in perf/ratchet/*.json; do
  [ -e "$file" ] || continue
  python3 -c 'import json, sys
for name, entry in json.load(open(sys.argv[1]))["metrics"].items():
    print(name, entry.get("command", ""), sep="\t")' "$file" |
  while IFS=$'\t' read -r name command; do
    [ -n "$command" ] || { echo "$file: $name has no stored command" >&2; exit 1; }
    value=$(bash -c "$command" </dev/null | tail -n 1)
    python3 tools/ratchet.py check --partial --file "$file" --value "$name=$value"
  done
done
```

The loop runs the `command` that `ratchet.py add --command` stored for each metric.
Record a `command` for every metric, or the gate fails. The command must print the metric on its last line.
The loop skips an empty `perf/ratchet/` directory and checks every ratchet file, so a new thread needs no CI change.

Run the gate on every pull request. A failing gate blocks merge.

## Policy

- Tighten in the same commit as the change that earned the gain.
- Never loosen through the helper. A human edits the file and gives the reason in the pull request.
- Accept a loosening only for a deliberate trade-off, such as a correctness fix. Record the trade-off.
- Remove a metric only when its benchmark is retired. Record the reason in the same pull request.
