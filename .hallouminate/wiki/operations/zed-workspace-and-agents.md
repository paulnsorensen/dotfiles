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

## Vim, fonts, and editor behavior (2026-08-26)

`settings.json.tmpl` now also configures vim mode and editor basics: `vim_mode` with system clipboard, smartcase f/t motions, relative line numbers, and `vertical_scroll_margin: 5` mirroring vimrc's `scrolloff=5`; `tab_size: 2` matching vimrc's `tabstop=2`; `format_on_save` (reversed to `on` on 2026-08-27 with per-language LSP formatting — see the update below) plus final-newline/trailing-whitespace on save; prek remains the commit-time backstop. Fonts are JetBrainsMono Nerd Font (buffer + terminal, size 14) with Hack Nerd Font Mono fallback. A managed `keymap.json` binds `ctrl-h/j/k/l` pane navigation in `Editor && vim_mode == normal` only (deliberately NOT in Terminal context, so the terminal keeps its own ctrl-h/j/k/l; cost: those keys can't navigate out of a focused terminal) and `cmd-j` → `workspace::ToggleBottomDock`. Claude Code is a fourth `agent_servers` entry: registry key `claude-acp` (NOT `claude-code-acp`).

`theme/generate.sh` gained a `generate_zed_theme()` target: the active base24 scheme renders to `chezmoi/dot_config/zed/themes/dotfiles-theme.json` (fixed filename so scheme switches never strand a stale file; theme name inside is the scheme name). The checked-in Modus Deuteranopia pair stays the default — the generated theme is a manual-select alternative and is dark-only. Zed theme gotchas learned: the theme `$schema` is v0.2.0 (a v0.2.1 bump PR exists but is unmerged as of Aug 2026); `players[]` entries must set `background` to the same accent as `cursor` and `selection` to that accent with a `3d` alpha suffix, or participant chips vanish and selections paint opaque; provenance is folded into the `author` field because loader tolerance for JSONC comments/unknown keys is unverified. Regression coverage: `tests/zed-config.bats` (template render) and the zed test in `tests/theme-palette.bats` (generator).

## MCP context servers + built-in LSP (2026-08-27)

`settings.json.tmpl` now wires MCPs and Zed's own language servers.

**MCP context servers target Zed's native Agent Panel, not the ACP agents.** The ACP agents (Codex, Claude, OMP) already load their MCPs from their own native configs; the ACP host does not forward Zed's `context_servers` to them (as of 2026-08 there is no auto-forward — cf. the same gap for tool permissions, Zed issue #57355). So `context_servers` fills the one surface that had nothing: Zed's built-in agent. It carries the full roster — `tilth`, `context7`, `tavily`, `hallouminate`, `milknado` — each `"source": "custom"`. Secret-bearing `context7`/`tavily` reuse the shared per-service `agent-secret-proxy` sockets (`/var/run/dotfiles-agent-secrets/<svc>.sock`): no plaintext, no `env`/`envFile`, and no new broker, because those sockets are shared across Claude/Codex/OMP. See [[architecture/mcp-secret-handling]].

**ACP parity.** `chezmoi/dot_omp/private_agent/mcp.json` gained brokered `tavily` to match Claude/Codex. `hallouminate`/`milknado` stay absent from OMP's `mcp.json` and from Claude's user-scope `mcps` on purpose: both harnesses install them as native plugins (OMP `.omp.plugins`; Claude via `agents/plugins/registry.yaml`), so listing them again would double-load the server under both the bare and plugin-scoped names.

**Built-in LSP + the format-on-save reversal.** Global `format_on_save` flipped `off` → `on` with `formatter: "language_server"`, reversing the earlier "prek owns formatting, Zed never formats" stance (prek stays the commit-time backstop for newline/whitespace). Per-language: Python formats via external `ruff format -`; Rust via rust-analyzer with `check.command: clippy`; `Shell Script` and `Markdown` opt out (`format_on_save: "off"`) to avoid shfmt surprises and prose reflow.

**Folded live drift.** Two live-only keys that were never in source are now in the template so `chezmoi` stops dropping them each sync: the `telemetry` opt-out block (diagnostics/metrics/anthropic_retention false) and OMP's ACP `default_config_options.model: openai-codex/gpt-5.6-sol` pin (= `modelRoles.strong`). Zed's empty `proxy: ""` is deliberately not carried — Zed re-materializes it.

Regression coverage for this change: `tests/zed-config.bats`, `tests/omp-config.bats`, `tests/agent-secret-config.bats`.
