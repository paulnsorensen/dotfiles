# ADR-003 — Activate the dual-harness upgrade dependency-first

Status: accepted

Related spec: `/Users/paul/.local/share/cheese/paulnsorensen-dotfiles/specs/codex-omp-harness-upgrade.md`.

## Context

The normal sync flow applies chezmoi-managed configuration before normal package convergence. That order is useful for manifest deployment, but a combined OMP/Codex schema migration can otherwise apply new configuration while old binaries are still active. A source-only change also cannot prove the workstation reached the requested versions and effective settings. The user selected live activation and selected retention rather than rollback if a final apply fails after successful upgrades.

## Decision

Treat OMP 17.2.5 and Codex 0.146.0 as one cutover. Run focused source/render tests, install both exact pins, perform the final chezmoi apply under the upgraded schemas, then verify versions, effective configuration, and fresh OMP/Codex scenarios. If the final apply or smoke check fails, return failure with exact diagnostics and retain the successfully upgraded binaries; do not claim completion.

## Alternatives

- Source-only migration: rejected because it leaves live version and effective configuration unproved.
- Keep apply-before-package ordering for this schema change: rejected because the old binary may reject or reinterpret new fields.
- Roll back upgraded binaries after a final-apply failure: rejected by the selected failure policy and adds a second failure-prone mutation path.
- Split the harnesses into separate specs: rejected because pins, activation ordering, drift metadata, and live verification share one release boundary.

## Consequences

The live workstation becomes part of acceptance, not an assumed side effect. Failure can leave a deliberate partial state, but it is observable, retryable, and never reported as complete. Regression tests must cover package-before-final-apply ordering and retention on failure in addition to rendered values.

Sources: `.sync:37-94`; `chezmoi/.sync:30-50`; `packages/sync.sh`; `tests/sync-orchestrator.bats`.
