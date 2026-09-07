# Ingest Log

## Log

2026-07-01 · 0dc5b5d98eee412c · new-page · operations/claude-dotfiles-ownership.md · Captured Claude Code dotfiles ownership split, settings merge policy, and destructive cleanup rule.
2026-07-01 · 0dc5b5d98eee412c · merged · operations/sync-and-chezmoi.md · Replaced stale create_settings summary with modify_settings authoritative/preserved/unknown-key policy.
2026-07-01 · 0dc5b5d98eee412c · merged · harnesses/claude.md · Updated Claude settings/config row to point at current chezmoi modify_settings ownership.
2026-07-01 · 0dc5b5d98eee412c · merged · architecture/config-drift.md · Updated settings drift model for repo-owned vs ap-managed/live settings.

2026-07-01 · a89d382fedaf2fa3 · merged · operations/claude-dotfiles-ownership.md · Added Claude+chezmoi destructive-management policy: CLI uninstall/remove for runtime objects, modify_ for partial settings ownership, exact/remove only repo-owned paths.

2026-07-03 · claudeplugings · merged · operations/claude-dotfiles-ownership.md, architecture/cross-harness-plugins.md · Bridged native-claude plugins (milknado, hallouminate) into the chezmoi-authoritative pipeline: modify_settings.json overlays enabledPlugins/extraKnownMarketplaces from agents/plugins/registry.yaml; run_onchange + claude-plugin-reconcile.sh prime/prune the CLI marketplace index and installed_plugins.json (manifest-owned only). Corrected the stale "preserved from the live file / reasserted by ap" settings-merge bullet; noted the isolated-only gate on_render_native_plugins.

2026-07-09 · a03e06a48829321c · conflict-flagged · decisions/session-convergence-001-fixture-cli-plus-indexes.md · Reconciled disproven index sub-decision: EXPLAIN on live DB shows DuckDB does not use secondary ART indexes for base-table filter scans (SEQ_SCAN); reverted the CREATE INDEX work, superseded the "profile-derived indexes" half, kept CLI/no-MCP/no-timer.

2026-07-09 · a03e06a48829321c · merged · decisions/session-convergence-002-sweep-in-work-recovery.md · Added implementation note for work-recovery --wheypoint write mode (shipped 2026-07-09; git: provenance branch-only, schema-valid degradation).

2026-07-20 · e89738679e9e5f1d · new-page · operations/omp-fanout-worker-models.md · Captured OMP subagent fan-out guardrails, model-role cost split, and OpenRouter worker model shortlist for cheap coder/menial workers.

2026-07-20 · 79ffca5de4346cf6 · new-page · harnesses/omp.md · Curated OMP Todo behavior, extension seams, adapter constraints, and the guarded-direct-cutover decision.
2026-07-20 · f9494484bf66a3a5 · merged · harnesses/omp.md · Added the implemented Milknado ownership contract, exact input-event protocol, verification coverage, and residual autocomplete/lifecycle limits.

2026-07-20 · fb6d1f78afb65c9f · merged · harnesses/omp.md · Recorded Milknado's fail-closed completion behavior, the repository-wide just check gate, inherited flavor resolution, and config validation coverage.

- 2026-07-20 · c7392ceb2d2f2bc2 · new-page · architecture/saved-workflows.md · cheese-factory replaces curd-flock (PR #486); page seeded from untracked main-clone copy so the corpus converges
- 2026-07-20 · c7392ceb2d2f2bc2 · merged · architecture/saved-workflows.md · smoke-verified: workflow-spawned agents have the Skill tool (resolves cheese-factory spec open question)
- 2026-07-20 · c7392ceb2d2f2bc2 · merged · architecture/saved-workflows.md · vm-realm deepEqual gotcha for tests/workflows (spread-clone / Array.from convention)

2026-07-24 · ac33ad5418f0c6a0 · new-page · architecture/subagent-routing-policy.md · Discover-then-commit routing doctrine: scoper change profile, hard overrides, 8-dim score, DIRECT/SCOPED_SINGLE/PLAN/FAN_OUT/STAGED/ESCALATE, layered authority, model-role tiers, worker escalation rule, calibration metrics (claims 1–3 of subagent-routing-guide).
2026-07-24 · ac33ad5418f0c6a0 · new-page · architecture/fanout-fanin-discipline.md · Fan-out economics + sizing table, patterns, fan-in contract, write ownership/contract freeze/integrator rule, context packets, validation pyramid, failure modes + recovery ladder (claims 4, 5, 8).
2026-07-24 · ac33ad5418f0c6a0 · merged · architecture/subagent-turn-budgets.md · Added upstream spawn-depth/concurrency caps section: CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH, MAX_CONCURRENT_SUBAGENTS, Explore-inherits-model gotcha, teams-vs-subagents (claim 6).
2026-07-24 · ac33ad5418f0c6a0 · merged · harnesses/codex.md · Added sub-agent routing knobs section: per-agent TOML tiering, config.toml [agents] block (not yet in seed), AGENTS.md as routing-policy carrier (claim 7).

2026-07-24 · 9a680a14e9bdf39a · new-page · operations/prompting-claude-opus-5.md · Opus 5 prompting deltas: review accuracy holds at low effort + report-everything-filter-separately, delegation eagerness/restraint rules, native self-verification (drop verify scaffolding aimed at Opus 5), effort economics (xhigh coding start; low/med strong), 1M ctx default, thinking-disabled artifacts.
2026-07-24 · 9a680a14e9bdf39a · merged · architecture/subagent-turn-budgets.md · Opus 5 delegation-eagerness note under spawn/concurrency caps: explicit criteria or deterministic caps; no self-verify subagents; one when one suffices.
2026-07-24 · 9a680a14e9bdf39a · merged · architecture/subagent-routing-policy.md · Current-state cross-ref: Opus 5 review-at-low-effort / severity-prompt recall / over-verification deltas.

2026-07-24 · 32c0769bb78d8fb7 · new-page · architecture/knowledge-graph-playbook.md · KG playbook digest: stage-tiered models (haiku extraction / sonnet reasoning), hybrid deterministic-blocking + LLM arbitration, shared-memory/blackboard for orchestrator-workers (90.2% / 10-15x), grounded evaluation + escalate-unverifiable, precision-first store writes (scoped vs Opus 5 report-everything reviews), production checklist + feedback-loop doctrine.
2026-07-24 · 32c0769bb78d8fb7 · merged · architecture/fanout-fanin-discipline.md · New section: shared memory instead of the orchestrator bottleneck (blackboard, 90.2% / 10-15x figures, hallouminate as the repo's store).
2026-07-24 · 32c0769bb78d8fb7 · merged · architecture/subagent-routing-policy.md · Two doctrine lines: deterministic pre-filter before LLM arbitration (Layered authority); grounded reviewer + escalate-unverifiable (Where to spend the strong model).

2026-07-28 · ca104a4762647d63 · merged · architecture/global-agents-doc.md · Added the external evidence and working 4–5k effective-global-stack budget hypothesis, clarified technical limits versus adherence targets, recorded content-placement guidance, and refreshed current repo-stack measurements.

2026-07-28 · preamble-20260728 · merged · architecture/agents-dir.md · Reassigned phase handoff ownership from the preamble to the four agent bodies and recorded the compact preamble's direct tilth, wiki-grounding, and delegation responsibilities.
2026-07-28 · preamble-20260728 · merged · adr/cheese-factory-workflow.md · Replaced stale preamble fan-out and continuation attributions with ADR-005 and coder-owned contracts.

2026-08-01 · 6d6acbacd0478a02 · merged · harnesses/omp.md · Corrected exact-version verification to include both pre-final-apply and post-successful-final-apply probes, retention on post-probe failure, and current regression ranges.

2026-08-09 · bitwarden-runbook-20260809 · new-page · operations/bitwarden-secrets-manager.md · Bitwarden provider runbook reconciled against b09e39c: three-Secret inventory (GitHub App dropped), web-application creation to keep values out of the `bws secret create` argv fallback, the single-line constraint imposed by env-output parsing, least-privilege machine account, root-shell token boundary, and rotation with broker restart.
2026-08-09 · bitwarden-runbook-20260809 · new-page · sources/*.md · Localized verified Bitwarden vendor evidence (Secrets, access tokens, machine accounts, CLI, quick start, plans) plus the bws 2.1.0 renderer source behind the single-line constraint.
2026-08-09 · bitwarden-runbook-20260809 · merged · architecture/mcp-secret-handling.md · Linked the provider-side Bitwarden runbook from the broker architecture page.
2026-08-09 · bitwarden-runbook-20260809 · merged · index.md, operations/index.md · Registered the sources section and the Bitwarden runbook.
2026-08-09 · bitwarden-runbook-20260809 · conflict-flagged · sources/bws-2-1-0-output-rendering.md · Corrected the superseded claim that the fetch path uses `-o json` with `jq`: b09e39c ships `bws secret list -o env` with matched-quote stripping, so multiline values remain unsupported and JSON is recorded as the fix if that need returns.

2026-08-17 · mise-precedence-20260817 · new-page · operations/mise-manifest-precedence.md · Recorded the mise config-precedence deadlock (#677) against a re-read of the checkout: proximity-based precedence demotes the manifest below the live config, `verify_harness_versions` gates the only step that would refresh it, and the fix is `apply_mise_manifest` in the prepare phase (`.sync-lib.sh:147`, `chezmoi/.sync:43`) — with an explicit do-not-delete note, since the pre-existing `MISE_CONFIG_FILE` exports make it look redundant. Supersedes the closed #721, which credited those exports with the fix.
2026-08-17 · mise-precedence-20260817 · new-page · operations/mise-github-auth.md · Split the mise/GitHub credential fix out of the precedence page per one-topic-per-file. Corrected provenance to #676 (not #677) and the rate-limit mechanism to non-semver pins forcing remote release-list fetches, with `nextest/cargo-nextest` as the only pin that never cached.
2026-08-17 · mise-precedence-20260817 · new-page · operations/omp-install-etxtbsy.md · Split the omp `ETXTBSY` staging fix (#677) out of the precedence page. Corrected the mechanism direction: the running process holds the inode open for execution and the kernel refuses the writer.
2026-08-17 · mise-precedence-20260817 · merged · operations/sync-and-chezmoi.md · Added the prepare → package-sync → final-apply phase-ordering section that two pages referenced but which did not exist, including the hardcoded-literal behaviour of `verify_harness_versions`.
2026-08-17 · mise-precedence-20260817 · merged · operations/index.md · Registered the three new pages under Packaging and machine state.

2026-08-23 · omp-guard-lockstep-20260823 · merged · operations/sync-and-chezmoi.md · Refreshed the stale `verify_harness_versions` literal (`omp/17.2.12`→`omp/17.3.0`, line spans) and added the OMP guard/pin lockstep gotcha: the two renovate managers over `.sync` and `packages/sync.sh` plus the `groupName: oh-my-pi` packageRule that bundles them into one PR (a split deadlocks automerge on the `tests/packages.bats` tripwire); codex-cli still manual (#743, #754).
2026-08-23 · omp-guard-lockstep-20260823 · merged · operations/mise-manifest-precedence.md · Corrected the same stale `omp/17.2.12` literal and line numbers, cross-linked the new lockstep note.

2026-09-06 · wiki-harvest-20260906 · new-page · operations/just-check-read-only-gate.md · Recorded PR #885: `just check` used to open with `lint-fix` (a mutating step), so verification could silently rewrite tracked source; `check` now runs read-only legs only, plus the nested-worktree markdownlint ignore added in the same PR.
2026-09-06 · wiki-harvest-20260906 · merged · operations/index.md · Registered just-check-read-only-gate.md under Repo-local traps.
2026-09-06 · wiki-harvest-20260906 · merged · architecture/explorer-artifact-contract.md · Corrected stale "proposed, not merged" status: PR #886 (commit 9fc9251) merged and deployed on main; verified against agents/agent_definitions/explorer.md.
2026-09-06 · wiki-harvest-20260906 · merged · architecture/cross-harness-guards.md · Corrected stale "proposed, not merged" status on the Tilth payload coverage section: PR #891 (commit 5b8bb72) merged and deployed on main; verified editTargets/move_file handling against agents/lib/sensitive-file-guard.js and claude/hooks/worktree-guard.js.
