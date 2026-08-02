# ADR-001 — Use model-relative OMP compaction

Status: accepted

Related spec: `/Users/paul/.local/share/cheese/paulnsorensen-dotfiles/specs/codex-omp-harness-upgrade.md`.

## Context

The managed OMP configuration combines `strategy: shake` and `keepRecentTokens: 20000` with `thresholdTokens: 120000`. Against the effective 272k model catalog, the fixed threshold compacts at roughly 44% of the available window. OMP's model-aware default is approximately 85%, while the desired `shake` strategy and 20k retained tail are independent choices. A fixed global threshold also ages poorly as model context windows change.

## Decision

Keep `shake` and `keepRecentTokens: 20000`, remove `thresholdTokens`, and do not replace it with another global fixed value. Verify the rendered field is absent under OMP 17.2.4 so OMP derives its trigger from the active model catalog. Leave Codex's context-window and auto-compaction settings undeclared for the same provider-relative reason.

## Alternatives

- Keep 120k: preserves current timing but wastes more than half of the available context on the current catalog.
- Raise the fixed threshold: improves today's ratio but recreates drift when models change.
- Replace `shake` with the default pruning strategy: unnecessary; trigger timing and compaction strategy are separate concerns.

## Consequences

Compaction occurs later on large-context models and follows future catalog changes without registry edits. Sessions may hold more context than they do today, so the cutover must assert the intentional absence and smoke the effective 17.2.4 configuration rather than testing only source YAML.

Sources: `chezmoi/.chezmoidata/omp.yaml`; research report `~/.local/share/cheese/paulnsorensen-dotfiles/research/omp-codex-harness-settings/omp-codex-harness-settings.md`.
