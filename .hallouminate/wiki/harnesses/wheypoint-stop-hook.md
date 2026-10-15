# Wheypoint Stop hook (retired)

The automatic wheypoint checkpoint gate is gone from every harness. The operator removed it on 2026-10-11 (PR #1267). The `/wheypoint` skill stays; agents and users run it on purpose.

## What was removed

- Claude: the `Stop` hook in `chezmoi/.chezmoidata/claude.yaml` and the `wheypoint-stop-gate` registry entries in `agents/hooks/registry.yaml`.
- Codex: the `wheypoint-stop-gate-observe` registry entry, which fed the assembled `hooks.json`.
- OpenCode: the `wheypoint-idle.js` plugin and its `lib/wheypoint-stop-gate.cjs` copy.
- The shared classifier `agents/lib/wheypoint-stop-gate.cjs`, its shell wrapper, and their tests.

## How deployed copies go away

- Claude settings and Codex hooks are built from the registry, so `dots sync` drops the entries.
- `~/.claude/hooks` and `~/.claude/lib` are exact targets, so sync prunes the scripts.
- OpenCode plugin and lib directories are not exact targets. `chezmoi/.chezmoiremove` lists both retired files.
- A Codex `config.toml` with a legacy hand-written wheypoint block keeps it. The prune runs only for scripts that stay in the registry.

## History

PR #1253 replaced a model-judged prompt check with a deterministic file-change policy. That design (shared classifier, Codex event journal, OpenCode queued follow-up) is in Git history before PR #1267. Read it there before you bring back any automatic checkpoint gate.

_Source: PR #1267 · Updated: 2026-10-11 · Supersedes: the deterministic cross-harness gate from PR #1253_
