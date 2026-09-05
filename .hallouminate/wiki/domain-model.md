# Domain model — dotfiles

Cumulative ubiquitous language for this repo's agent-orchestration domain. Merge, don't overwrite; context-specific terms only.

**Curd** — one file-disjoint unit of a decomposed spec, implemented on its own `curd/<slug>` branch in its own worktree.
_Avoid_: task, unit, slice
_Code_: skills/mold/references/curd-count.md:40-54 (`candidate_curds`)

**Single-pass** — cheese-factory's non-fan-out mode: one worktree running the full phase chain against the parent spec.
_Avoid_: linear mode
_Code_: NEW ENTITY (claude/workflows/cheese-factory.js mode)

**Taste-test** — the standalone post-cook reviewer gate (drift / readability / scope / production-path / wired-callers).
_Avoid_: quick review
_Code_: claude/workflows/cheese-factory.js:252-263 (`tastePrompt` lens set)

**Mini-spec** — per-curd spec written by the decomposer at `specs/<parent>--<curd>.md`, using mold's mini-spec schema.
_Avoid_: sub-spec
_Code_: skills/mold/SKILL.md § Agent-invoked mini-spec mode

**Plate barrier** — the single opus plate agent that runs once after all curd chains, stacking clean branches into a stacked-PR chain (never merges).
_Avoid_: publish step
_Code_: NEW ENTITY (claude/workflows/cheese-factory.js phase)

**No-chain-forward** — directive carried by every phase spawn overriding a skill's `--auto` chaining: write your handoff slug and stop.
_Code_: ~/.claude/skills/ultracook/SKILL.md:87-91

**Pinned surface** — any package whose installed version is exactly recorded in a manifest and moves only via merged bump PRs (never machine-side upgrade).
_Avoid_: managed package, locked dep
_Code_: NEW ENTITY (chezmoi/dot_config/mise/config.toml + packages.yaml `version:` fields + claude.yaml MCP args)

**Brew remainder** — the ~16 formulae + taps + casks left on unpinned brew after the mise migration; the only surface `dots up` still upgrades.
_Avoid_: legacy packages
_Code_: packages/packages.yaml (post-migration residue)

**Exempt channel** — own-authored package deliberately left floating (tilth/hallouminate nightlies, milknado@main); a trusted-author boundary, not an oversight.
_Avoid_: unpinned dep
_Code_: chezmoi/.chezmoiscripts/run_onchange_after_install-{tilth,hallouminate}.sh.tmpl

**Mise manifest** — the repo-authored, chezmoi-deployed mise config holding all aqua/backend tool pins.
_Avoid_: tool-versions file
_Code_: NEW ENTITY (chezmoi/dot_config/mise/config.toml → ~/.config/mise/config.toml)

**Harness** — a native AI coding agent binary (claude, codex, omp) managed by sync's native-harness loop.
_Avoid_: agent binary
_Code_: packages/sync.sh:680-708 (`sync_native_harnesses`)

**Renovate runner** — the self-hosted cron workflow executing Renovate against this repo's four pinned surfaces.
_Avoid_: update bot
_Code_: NEW ENTITY (.github/workflows/renovate.yml + renovate.json5)

**Vault provider** — the secret backend selected by `vault_resolve` for the privileged credential-provisioning path.
_Avoid_: vault CLI, detected executable
_Code_: `bin/lib/vault.sh` (`vault_resolve`, `_vault_resolve_unlocked`)

**Vault source locator** — the non-secret, provider-specific identity of the item or project from which the operator reads runtime credentials.
_Avoid_: vault profile, source URI
_Code_: `bin/lib/vault.sh` (`_vault_onepassword_item`, `_vault_project_id`)

**Vault resolution lock** — the persistent mode-0600 advisory-lock inode that serializes provider readiness probes through `flock` on Linux or pathname-and-command `lockf` on macOS.
_Avoid_: cache lock, PID lock, disposable lock file
_Code_: `bin/lib/vault.sh` (`_vault_with_resolution_lock`, `vault_resolve`)

**Daily user** — the interactive OS account that launches managed harnesses and may be controlled by an adversarial agent.
_Avoid_: agent identity, trusted user
_Code_: `zsh/core.zsh` (retired credential names are removed before harness launch)

**Broker service identity** — a dedicated system account that owns exactly one credentialed upstream MCP consumer.
_Avoid_: vault user, proxy user
_Code_: `bin/agent-secret-install`; `services/agent-secret/`

**Operator identity** — a separate authenticated OS account allowed to approve one exact pending mutation through the broker control socket.
_Avoid_: daily user, agent approver
_Code_: `bin/agent-secretctl`

**MCP firewall** — the broker enforcement point that filters the advertised and callable MCP tool surface and gates mutations without exposing credentials.
_Avoid_: credential proxy, secret API
_Code_: `scripts/agent-secret-broker.py`

**Shared skills dir** — `~/.agents/skills`, the one skill root read by Codex, Zed, Copilot, and OMP's `agents` provider; chezmoi-owned (`chezmoi/private_dot_agents/exact_skills`) after the `shared-agents-skills-exact` spec.
_Avoid_: codex skills dir, agents dir
_Code_: `.sync-lib.sh` (`sync_shared_agents_chezmoi_sources`); `agent-profile/agent_profile/renderers/codex.py:7`

**Skill assembler** — a `.sync-lib.sh` function that stages local, vendored-external, and plugin skills into a chezmoi `exact_` source tree before apply (`sync_claude_chezmoi_sources`, `sync_shared_agents_chezmoi_sources`).
_Avoid_: installer, sync step
_Code_: `.sync-lib.sh:538-619`

**npx leg** — `chezmoi/lib/install-external.sh`, the `npx skills add` installer for harness dirs chezmoi does not own; Cursor-only after `shared-agents-skills-exact`.
_Avoid_: external installer, skills CLI path
_Code_: `chezmoi/lib/install-external.sh`; `bin/dots:175-178`

**Plugin source** — a `skills/_registry.yaml` entry for a plugin repo (`skills_path: plugins/<name>/skills`) whose `harnesses:` is the shared-dir set minus the plugin's resolved native set from `agents/plugins/registry.yaml`.
_Avoid_: decomposed plugin, plugin skill leg
_Code_: `skills/_registry.yaml` (milknado, hallouminate entries); [[architecture/adr-shared-agents-skills]]
