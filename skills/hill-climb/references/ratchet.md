# Ratchet gate

A ratchet gate is a CI check with a threshold per metric.
The threshold moves only toward better values. A regression fails the build.
This keeps every gain after the thread ends.

## Ratchet file

The file is JSON. Commit it beside the code it protects, for example `perf/ratchet.json`.

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
- `revision` records the commit that set the threshold.

## Commands

- `add` records a new metric. It refuses an existing name.
- `check` is the gate. It fails on a regression or a missing metric. `--partial` permits a subset.
- `tighten` moves thresholds to better values. It refuses a worse value and writes nothing.
- `measure` runs the benchmark N times. It fails when the spread exceeds the tolerance.

`check` reports `improved` when a value beats its threshold. Run `tighten` in the same change.

## Wire the gate

Use the repository's existing gate recipe. Do not add a new task runner.
Copy `ratchet.py` into the repository, for example `tools/ratchet.py`. CI must not depend on a home-directory skill path.

```bash
value=$(node --predictable bench/message-tree.js | tail -n 1)
python3 tools/ratchet.py check --file perf/ratchet.json --value "message-tree.instructions=$value"
```

Run the gate on every pull request. A failing gate blocks merge.

## Policy

- Tighten in the same commit as the change that earned the gain.
- Never loosen through the helper. A human edits the file and gives the reason in the pull request.
- Accept a loosening only for a deliberate trade-off, such as a correctness fix. Record the trade-off.
- Remove a metric only when its benchmark is retired. Record the reason in the same pull request.
