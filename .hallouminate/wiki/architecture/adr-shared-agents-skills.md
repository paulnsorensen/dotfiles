# ADRs: shared `~/.agents/skills` as a chezmoi `exact_` dir

Decision series from the `shared-agents-skills-exact` spec (/mold session, 2026-09-05). Spec: `~/.local/share/cheese/paulnsorensen-dotfiles/specs/shared-agents-skills-exact.md`. Research: `.cheese/research/zed-omp-skill-paths.md`. Extends [[adr-chezmoi-authoritative-claude]] ADR-001 to the harnesses it left frozen.

**Symptom that started it:** after ADR-001 retired `ap install global` (last run 2026-06-30), nothing wrote local or plugin skills for Codex, Copilot, Zed, or OMP. `~/.agents/skills` and `~/.github/skills` kept a June snapshot: retired skills (`tdd-assertions`, `self-eval`, `spec-verify`, `scout`) survived and live ones (`de-slop`, `claude-local`, `session-analytics`) went stale. Only external sources refreshed, through `chezmoi/lib/install-external.sh` (`npx skills add`), which reconciles per source only.

## approach: chezmoi `exact_` dirs, mirroring `~/.claude/skills` [status: accepted]

- **Context:** Three ways to fix the frozen dirs: a chezmoi `exact_` assembly (one writer, deletions propagate), a reconciler bolted onto `install-external.sh` (a third writer on the same dir), or prune-only (Codex loses local skills).
- **Decision:** Assemble the shared dir the way `sync_claude_chezmoi_sources` assembles `~/.claude/skills`.
- **Alternatives:** the reconciler recreates the "three writers, no authority" structure ADR-001 rejected; prune-only is a regression for Codex.
- **Why npx cannot feed an `exact_` dir:** chezmoi applies from its *source* tree and deletes target files the source lacks. `npx skills add` writes the *target*, so chezmoi would delete its output on the next apply. The assembler clones sources with git into `~/.cache/dotfiles/claude-skill-sources/` and copies into the source tree before apply.

## f1-selection: reuse `.claude.skills` for every harness [status: accepted]

- **Decision:** one list in `chezmoi/.chezmoidata/claude.yaml` drives Claude, OMP, and the shared dir.
- **Alternatives:** per-harness lists (`.codex.skills`, …) mirror `.codex.agents` but multiply the config-drift surface; an optional `skills_exclude:` per harness is YAGNI until a real exclusion exists.
- **Precedent:** `sync_omp_chezmoi_sources` already read `.claude.skills`.

## f2-target: one shared `~/.agents/skills`; remove `~/.github/skills`; retire OMP's `exact_skills` leg [status: accepted]

- **Context:** Codex, Zed, Copilot, and OMP's `agents` provider all read `~/.agents/skills`. `~/.github/skills` is a second Copilot root; `~/.omp/agent/skills` is OMP's native root that outranks the shared one.
- **Decision:** one `exact_` dir at `chezmoi/private_dot_agents/exact_skills`; `.chezmoiremove` drops the other two; `omp.yaml` sets `skills.enableAgentsUser: true` explicitly (key present in the pinned `~/.local/bin/omp`).
- **Consequence:** a shared dir cannot withhold a file from one reader. Per-harness exclusion is gone; Copilot sees milknado's skills both natively and in the shared dir.
- **Consequences:** the first `dots sync` deletes every entry in `~/.agents/skills` the source does not contain. This includes hand-installed skills. `~/.agents/.skill-lock.json` sits outside the `exact_` dir. It keeps stale codex/copilot records until the `skills` CLI rewrites it. Cursor's reconcile is `--agent cursor` scoped.

## f3-npx-leg: keep `install-external.sh` for Cursor only [status: accepted]

- **Decision:** the script refuses the chezmoi-owned harnesses in both namespaces it mixes — `CHEZMOI_OWNED_HARNESSES="codex copilot zed omp"` (ap names, per-source `harnesses:` loop) and `CHEZMOI_OWNED_AGENTS="codex github-copilot zed"` (skills-CLI ids, global `HARNESSES`) — and scopes `skills remove` with `--agent`.
- **Alternatives:** delete the leg (Cursor loses external skills unless it reads `~/.agents/skills` — unverified, follow-up FU-1); feed Cursor from the shared dir (drags Cursor's separate local-skill source into scope).
- **Gotcha:** `skill_agents.txt` maps `copilot=github-copilot`; a single refusal list in one namespace misses the other.

## f4-plugins: plugin skills enter the shared dir under the native rule [status: accepted]

- **Decision:** a plugin's skills land in the shared dir when at least one shared-dir harness gets it decomposed. Zed and OMP have no plugin system, so every listed plugin enters through them.
- **Alternatives:** no plugin leg (Codex loses milknado; Zed/OMP never get wiki-* skills); ship everything (Codex and Copilot list hallouminate twice).

## f4-mechanism: express the rule as `skills/_registry.yaml` sources [status: accepted]

- **Context:** `ap` validates plugin `harnesses:` against `SUPPORTED_ITEM_HARNESSES = (claude, codex, cursor, copilot)` (`agent-profile/agent_profile/harnesses.py:8-33`); `zed` and `omp` cannot appear in `agents/plugins/registry.yaml`.
- **Decision:** register `paulnsorensen/milknado` (`harnesses: [codex, zed, omp]`) and `paulnsorensen/hallouminate` (`harnesses: [zed, omp]`) as external skill sources with `skills_path: plugins/<name>/skills`. The list is the shared-dir set minus the plugin's resolved native set; `native: true` resolves to `harnesses ∩ {claude, codex, copilot}`.
- **Alternatives:** teach `ap` two harnesses it cannot render; a plugin leg with a fixed reader set (hallouminate never enters).
- **Gotcha:** the native rule now lives by hand in two files; `tests/config-validation.bats` cross-checks them.

- **Amendment (2026-09-05, found at the merged-tree gate):** `ap`'s `ingest._expand_external_skills` also validates each skill-registry source's `harnesses:` against `SUPPORTED_ITEM_HARNESSES`, so `zed`/`omp` broke `parse_manifest()` (11 pytest cases). Decision: `ap` subtracts a fixed `SHARED_DIR_ONLY_HARNESSES = ("zed", "omp")` before validation and skips a source left with no `ap` harness; typos still fail loud. Rejected: a second `shared_harnesses:` key (two keys, one meaning) and extending `SUPPORTED_ITEM_HARNESSES` (every renderer learns harnesses it cannot render). The `ap` fix also attaches the filtered `harnesses` to each external skill item. A `[claude]`-only source (skillz-that-grillz) now renders for Claude only. Previously `ap` rendered it for every harness. Pinned by `test_expand_external_skill_claude_only_source_keeps_claude_harness`.

## Implementation

Landed in the `chezmoi-housekeeping-and-adr` curd (wave 3): `chezmoi/.chezmoiignore` (`!.agents/**`), `chezmoi/.chezmoiremove` (`.github/skills`, `.omp/agent/skills`), `.gitignore` (drops `chezmoi/dot_omp/private_agent/exact_skills/`, adds `chezmoi/private_dot_agents/exact_skills/`), `chezmoi/.chezmoidata/omp.yaml` (`skills.enableAgentsUser: true`), `tests/chezmoi-wiring.bats` (AC-6, AC-10, and a rewritten swap assertion in the e2e apply test), `tests/omp-config.bats` (AC-9). The upstream assembler, npx Cursor-only leg, and plugin registry sources were already in place on `feat/shared-agents-skills` before this curd started.

**Cut halt:** the live `chezmoi --source <dir> diff --dry-run` gate needs a real `$HOME` and chezmoi's symlink handling for `.chezmoiroot`/exact_ dirs is not exercised by this curd's Bats-only RED/GREEN loop; no receipt from that gate exists here. AC-8 (the live-machine `dots sync` check that `~/.agents/skills` ends up de-slop-identical with `~/.github/skills`/`~/.omp/agent/skills` absent) is the integration barrier's gate, not this curd's.
