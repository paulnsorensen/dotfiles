# Zed Workspace and External Agents

Use Zed External Agents over ACP for Codex, Claude, and OMP. Keep the workspace code-first: Project Panel left, editor center, Agent Panel right, and a closed-by-default bottom terminal. This is the committed default, not a lock on per-workspace rearrangement.

## External-agent decision

- Retain both existing Codex entries: Zed's `codex-acp` ACP Registry entry with `fast-mode`, and the repository-managed custom `Codex` adapter pinned in `packages/packages.yaml`. Codex retains its native login, and the repository stores no credentials. See [[zed-codex-acp]].
- OMP has a direct ACP stdio entry point: `omp acp`. Configure it as a Zed custom agent rather than using the unrelated upstream Pi adapter.
- Install Claude Agent from Zed's ACP Registry when needed. Claude authentication and billing remain agent-owned, not Zed-provider-owned.

Zed documents External Agents as ACP subprocesses where the agent owns runtime, authentication, model selection, tools, and native configuration. Its registry is the preferred path for common agents; custom `agent_servers` entries are the correct path for a local command such as OMP.

## Workspace layout

The default puts the Project Panel on the left at 260px, Agent Panel on the right at 520px, and Terminal Panel at the bottom at 280px but closed. `bottom_dock_layout: "contained"` preserves full-height side docks. Zed treats widths and positions as defaults: users can resize and rearrange panels in a workspace.

Zed's Agentic layout is an intentional alternative, not this default: it places the Agent Panel and Threads Sidebar left, while Project/Git panels move right. Use `workspace: use agentic layout` to try that agent-first arrangement.

## Accessibility theme

Use the Modus Themes extension and select `Modus Vivendi Deuteranopia` in dark mode and `Modus Operandi Deuteranopia` in light mode. The upstream deuteranopia palette avoids red/green-only coding and uses yellow/blue distinctions, including diff additions/removals; it targets 7:1 foreground/background contrast. The Zed extension must still be installed on each machine before a checked-in `theme` setting can resolve.

A theme cannot make status accessible when Zed communicates it by color alone. Verify Git add/remove markers, diagnostics, project-tree status, selection/focus states, and primary-language syntax with a deuteranopia simulator or a user with deuteranopia.

## Sources

- [Zed External Agents](https://zed.dev/docs/ai/external-agents)
- [Zed visual customization](https://zed.dev/docs/visual-customization)
- [Zed parallel agents](https://zed.dev/docs/ai/parallel-agents)
- [Modus Themes Zed extension](https://github.com/vitallium/zed-modus-themes)
- [Modus Themes accessibility rationale](https://protesilaos.com/emacs/modus-themes)
- [WCAG 2.1 SC 1.4.1: Use of Color](https://www.w3.org/WAI/WCAG21/Understanding/use-of-color.html)
