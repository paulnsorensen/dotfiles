# ADR-001 — Use model-relative snapcompact compaction

Status: accepted

Related spec: `/Users/paul/.local/share/cheese/paulnsorensen-dotfiles/specs/codex-omp-harness-upgrade.md`.

## Context

A fixed `thresholdTokens: 120000` compacted the effective 272k model catalog at roughly 44% of capacity. Removing that override lets OMP use its model-relative threshold, approximately 85% for the current catalog.

The first replacement strategy was `shake`. Source review found that automatic shake protects a hard-coded 16k recent suffix, not `keepRecentTokens`; elides old tool results and large fenced/XML blocks without judging importance; and falls back to `context-full` summarization unless it recovers below 80% of the compaction threshold. Removed text is normally recoverable through artifacts, but it leaves the active prompt immediately. OMP 17.2.4 also allowed an automatic shake to re-elide a just-read recovery artifact; upstream fixed that in 17.2.5.

## Decision

Pin OMP 17.2.5 and use explicit `strategy: snapcompact` with `keepRecentTokens: 20000`, `midTurnEnabled: true`, and `autoContinue: true`. Keep `thresholdTokens` absent so the trigger follows the active model catalog. Leave Codex's context-window and auto-compaction settings undeclared for the same provider-relative reason.

Snapcompact is OMP's 17.2.5 default and fits the configured OpenAI model, which accepts text and image input. It preserves the recent tail as text and makes older turns directly model-readable as a local image archive instead of depending on the model to notice and retrieve shake artifact links. The explicit strategy records repository policy rather than inheriting a future upstream default change.

## Alternatives

- Keep `shake`: retains exact removed text when artifact persistence succeeds, but removes it from the active prompt, has an unquantified semantic-recall rate, drops non-text blocks from selected mixed-media tool results, and may still fall back to LLM summarization.
- Use `context-full`: works without vision but replaces older history with a model-authored summary, introducing avoidable semantic drift and a remote model call.
- Use `handoff`: gives the cleanest context boundary but creates a new session rather than preserving continuity in the current one.
- Keep or raise a fixed threshold: either wastes available context or recreates drift when model windows change.

## Consequences

Compaction occurs later on large-context models, uses no remote compaction-model call in the normal snapcompact path, and keeps old turns visible to the active vision-capable model. The archive is intentionally lossy at the character level: snapcompact bounds tool-result and argument text before rendering, so exact historical command output may need to be regenerated or reread. A future text-only active model will force OMP's `context-full` fallback.

The cutover must verify the rendered configuration under OMP 17.2.5, assert that `thresholdTokens` remains absent, and retain the 20k recent-tail policy.

Sources: `chezmoi/.chezmoidata/omp.yaml`; [OMP 17.2.5 compaction documentation](https://github.com/can1357/oh-my-pi/blob/v17.2.5/docs/compaction.md); [artifact recovery protection fix](https://github.com/can1357/oh-my-pi/pull/7327); [OMP 17.2.5 release](https://github.com/can1357/oh-my-pi/releases/tag/v17.2.5).
