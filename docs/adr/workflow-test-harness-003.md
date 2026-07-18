### ADR-003: Fold workflows-parse.sh into the harness suite and gate CI on `just smoke`  [status: accepted]

- **Context:** Two parallel guards would drift (`workflows-parse.sh` + the new suite), and CI ran only `just lint` + `just test` — `just smoke`, the workflow guard's home, never gated a PR (`.github/workflows/test.yml:34,57`).
- **Decision:** Delete `tests/workflows-parse.sh`; port its parse check (as `all-parse.test.mjs` over all shipped workflow scripts) and `ultracook-fleet-worker.toml` key checks into the node:test suite; repoint `just smoke` at `tests/workflows-test.sh`; update the justfile `lint-shell` file list; add `just smoke` to the CI `test` job.
- **Alternatives:** (a) Keep both scripts side by side — rejected: split-brain guard, the grep-based one keeps producing false green. (b) Leave workflow tests local-only — rejected: a guard that never runs on PRs cannot gate regressions.
- **Consequences:** One guard, CI-enforced. Cost: CI `test` job now needs node (preinstalled on ubuntu-latest runners) and the smoke leg's runtime (~seconds).

(2026-07: `ultracook-fleet*` renamed to `milknado-fleet*`; the checks now target the renamed files.)
