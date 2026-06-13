# Architecture

How this dotfiles repo configures AI coding agents. The model is **one harness-agnostic source of truth, rendered into many harness layouts**.

- [[agents-dir]] — the `agents/` registry system: MCP / hook / sub-agent / skill registries, the system-prompt body, and the shared cheese-flair assets. Declares *what* every agent gets.
- [[agent-profile]] — the `ap` tool (`agent-profile/`): profiles (base / global / isolated), the five per-harness renderers, install vs launch, and the chezmoi drive path. Decides *where and in what shape*.
- [[agent-vs-skill-tiering]] — when a behaviour earns a sub-agent vs a skill (the two axes: isolation, detect-vs-fix), the cross-repo ownership constraint (dotfiles agents ↔ easy-cheese skills), the self-filter-vs-wire-protocol scoring rule, and the deferred cheese-agent cleanup backlog.
- [[harness-permissions]] — each harness's native permission/tool-access model (Claude allow/deny/ask, Codex sandbox+approval+`.rules`, opencode `permission` object, Cursor IDE-UI-vs-CLI split, Copilot `tools` + `--deny-tool`), how `ap` maps profile-declared permissions onto each (only Claude gets full allow+deny; Codex/Cursor/Copilot drop it), the per-repo `ap perms` project overlay (#272, additive on top of the user-level floor), and the known gaps.
- [[mcp-secret-handling]] — why MCP `${VAR}` env refs are passed through to each harness as a runtime placeholder (claude/copilot `${VAR}`, opencode `{env:VAR}`, cursor `envFile`) instead of baked as resolved secrets, and the ingest validation-vs-substitution split.
- [[mcp-schema-loading]] — why the registry's `harnesses` field is a per-request token-budget lever, not just a compatibility flag: Claude Code lazy-loads MCP schemas (ToolSearch) but opencode / Codex / Cursor / Copilot eager-load every schema on every request. The worked example is scoping Todoist (62% of the footprint) out via `harnesses: []`.
- [[config-drift]] — why live harness config drifts from the `ap` render (seed-once `create_` files nothing prunes), the three drift classes (stale remnant / dotfiles bug / expected local), and the `settings.json` hook self-heal behind `/harness-doctor`.
- [[cross-harness-guards]] — the safety hooks (git-guard + the Claude-only pre-tool guards): one classifier, five harness adapters, fail-open, and why the dirty-check needs a plugin not a static deny.

For the harness-specific consumption (and official upstream docs for each native config surface), see [[../harnesses/index]]. For the operational plumbing (sync, chezmoi, local-llm, dev environment), see [[../operations/index]].
