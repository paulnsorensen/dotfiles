# Architecture

How this dotfiles repo configures AI coding agents. The model is **one harness-agnostic source of truth, rendered into many harness layouts**.

- [[agents-dir]] — the `agents/` registry system: MCP / hook / sub-agent / skill registries, the system-prompt body, and the shared cheese-flair assets. Declares *what* every agent gets.
- [[agent-profile]] — the `ap` tool (`agent-profile/`): profiles (base / global / isolated), the five per-harness renderers, install vs launch, and the chezmoi drive path. Decides *where and in what shape*.
- [[agent-vs-skill-tiering]] — when a behaviour earns a sub-agent vs a skill (the two axes: isolation, detect-vs-fix), the cross-repo ownership constraint (dotfiles agents ↔ easy-cheese skills), the self-filter-vs-wire-protocol scoring rule, and the deferred cheese-agent cleanup backlog.
- [[mcp-secret-handling]] — why MCP `${VAR}` env refs are passed through to each harness as a runtime placeholder (claude/copilot `${VAR}`, opencode `{env:VAR}`, cursor `envFile`) instead of baked as resolved secrets, and the ingest validation-vs-substitution split.

For the harness-specific consumption (and official upstream docs for each native config surface), see [[../harnesses/index]].
