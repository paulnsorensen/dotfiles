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
_Code_: packages/sync.sh:584-614 (`sync_native_harnesses`)

**Renovate runner** — the self-hosted cron workflow executing Renovate against this repo's four pinned surfaces.
_Avoid_: update bot
_Code_: NEW ENTITY (.github/workflows/renovate.yml + renovate.json5)
