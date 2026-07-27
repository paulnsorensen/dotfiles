# ADRs — manifest-pinned packages (supply-chain redesign)

## ADRs

Rationale record for the `manifest-pinned-packages` spec (durable spec: `~/.local/share/cheese/paulnsorensen-dotfiles/specs/manifest-pinned-packages.md`; research slugs under `.cheese/research/`). Session date: 2026-07-24. Related: [[operations/sync-and-chezmoi]], [[architecture/agents-dir]].

### ADR-001: Hybrid manifest strategy — mise:aqua migration + Renovate regex pins  [status: accepted]

- **Context:** ~90 packages install unpinned across brew/npx/uv/cargo/curl. Renovate has NO homebrew datasource, and brew cannot install arbitrary historical versions — so pinning inside brew is unenforceable. The aqua registry covers 45 of the tools (incl. claude, codex, rtk) with checksum + cosign/SLSA verification, and Renovate natively manages mise.toml.
- **Decision:** Migrate the 45+7 pinnable tools to a chezmoi-deployed mise manifest; pin the 15 remaining packages.yaml entries (npm/uv/cargo/gh-extension) and the MCP npx args via Renovate regex custom managers.
- **Alternatives:** (B) regex-pins-only — rejected: advisory-only versions for the largest surface, no verification. (A) mise-only — rejected: leaves npm/uv/cargo/MCP surfaces floating. Do Nothing — rejected: `npx -y @latest` at every Claude launch was the worst live exposure.
- **Consequences:** Real machine-side verification for ~52 tools; new tool (mise) in the bootstrap chain; brew shrinks to a ~16-formula remainder + casks.

### ADR-002: Self-hosted Renovate on an Actions cron  [status: accepted]

- **Context:** Hosted Mend app is zero-infra but grants a third-party service PR-write access — incoherent with a supply-chain-hardening redesign.
- **Decision:** `renovatebot/github-action` (SHA-pinned) on a cron workflow, with a fine-grained `RENOVATE_TOKEN` PAT because GITHUB_TOKEN-created PRs do not trigger `on: pull_request` CI, which would deadlock automerge-on-green.
- **Alternatives:** Hosted Mend Renovate app — rejected by user for the third-party write grant.
- **Consequences:** We own config/maintenance + a PAT rotation duty; no external app trust.

### ADR-003: Pin claude/codex via aqua; disable self-updaters  [status: accepted]

- **Context:** Harnesses shipped on curl-installer channels with self-update (`packages/sync.sh sync_native_harnesses`). Inventory found both in the aqua registry (`anthropics/claude-code`, `openai/codex`).
- **Decision:** Install via mise:aqua at exact pins; disable self-update; remove native/brew copies so mise shims win PATH. omp (no aqua entry) pins via its installer's `--ref <tag>`.
- **Alternatives:** Keep self-updaters (freshness-first) — user explicitly chose pin-with-lag.
- **Consequences:** Bump lag (cooldown + registry lag) accepted; checksummed, reviewable harness updates.

### ADR-004: Two-bot split — Dependabot keeps github-actions + uv; Renovate owns custom surfaces  [status: accepted]

- **Context:** Dependabot (with 7-day cooldown) already covers workflows + agent-profile from the same-day CI-scan work; it has no custom-manager mechanism for anything else.
- **Decision:** Keep Dependabot's existing scope; add Renovate only for the surfaces Dependabot cannot express (mise config, packages.yaml, claude.yaml, omp ref). Renovate's github-actions manager stays disabled to avoid double PRs.
- **Alternatives:** Consolidate everything into Renovate — viable, one bot; rejected to preserve the just-landed Dependabot config and its zizmor-mandated cooldown.
- **Consequences:** Two bot configs to maintain; zero overlap by construction.

### ADR-005: `dots up` repurposed — pinned surfaces immutable machine-side  [status: accepted]

- **Context:** `dots up` (UPGRADE_MODE) upgraded everything to latest, defeating any pin.
- **Decision:** `dots up` = git pull + `dots sync` + brew-remainder/cask upgrade only. Pinned surfaces change exclusively via merged bump PRs (7-day cooldown; automerge patch/minor on green CI, majors manual).
- **Alternatives:** Scheduled launchd auto-pull+sync — deferred, not rejected; escape-hatch-with-warning — rejected as pin-defeating.
- **Consequences:** Machine convergence is pull-driven and reviewable; the unpinned remainder still needs occasional `dots up`.

### ADR-006: Own-authored channels exempt from pinning  [status: accepted]

- **Context:** tilth/hallouminate npm nightlies and milknado@main are the user's own release channels; uv's `--exclude-newer` cooldown cannot cover git deps anyway.
- **Decision:** Leave them floating; the `run_onchange_after_install-*.sh.tmpl` nightly scripts stay untouched. Third-party moving refs (skills-ref@main, rtk@master) DO get pinned (rtk via aqua).
- **Alternatives:** Pin everything — rejected: daily nightly-bump PR noise with no trust gain (author == user).
- **Consequences:** A trusted-author boundary exists in the manifest; documented, deliberate.

### ADR-007: Apply the manifest before package convergence  [status: accepted]

- **Context:** A mise pin can change in the chezmoi source without changing packages.yaml; running package sync before chezmoi apply leaves the machine on the old tool version. A failed install must also remain retryable rather than becoming a cache hit.
- **Decision:** On a configured machine, .sync applies the dotfiles/chezmoi entries first, then runs packages/sync.sh. On a fresh machine, it invokes package sync in bootstrap-only mode against the repository's mise manifest, verifies chezmoi became available, applies chezmoi, then performs normal package convergence. The package cache hashes packages.yaml, the selected mise config, and the OMP pin; it is written only after all installers succeed.
- **Consequences:** A manifest-only bump converges in the same sync; bootstrap failures stop before partial convergence is reported as complete; dots up can pull the bump and run pin-aware upgrade mode without floating pinned channels.

Sources: .sync:47-73, packages/sync.sh:44-63, 291-329, 667-689, and bin/dots:205-224.[^1]

[^1]: .sync:47-73; packages/sync.sh:44-63, 291-329, 667-689; bin/dots:205-224
