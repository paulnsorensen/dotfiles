# Architecture

How this dotfiles repo configures AI coding agents. The model is **one harness-agnostic source of truth, rendered into many harness layouts**.

- [[agents-dir]] — the `agents/` registry system: MCP / hook / sub-agent / skill registries, the system-prompt body, and the shared cheese-flair assets. Declares *what* every agent gets.
- [[agent-profile]] — the `ap` tool (`agent-profile/`): profiles (base / global / isolated), the five per-harness renderers, install vs launch, and the chezmoi drive path. Decides *where and in what shape*.

For the harness-specific consumption (and official upstream docs for each native config surface), see [[../harnesses/index]].
