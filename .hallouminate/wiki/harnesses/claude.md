# Claude Code

Anthropic's CLI and the primary harness. Claude isolated launches use native closed-world flags; Codex isolates through its own config-root wrapper. Docs: <https://code.claude.com/docs>.

Config lives under `~/.claude/`. The repo deploys it as a Claude *plugin tree* (`~/.claude/plugins/local/global/`) plus shared user-scoped files, wired live via `~/.claude/settings.json` (`enabledPlugins` + `extraKnownMarketplaces`). See [[../architecture/agent-profile]] § the `global` install.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://code.claude.com/docs/en/hooks> | `agents/hooks/registry.yaml` → plugin `hooks/` (wiring in `plugin.json`, NOT `settings.json`). SessionStart cheese-flair hook + its `shared_assets`. |
| Sub-agents | [sub-agents](https://code.claude.com/docs/en/sub-agents) · [frontmatter fields](https://code.claude.com/docs/en/sub-agents#supported-frontmatter-fields) | `agents/registry.yaml` + `agent_definitions/` → `.claude/agents/<n>.md` only (user-scoped, priority 4, full frontmatter). The renderer does **not** also write a plugin-scoped copy — that produced duplicate `global:`-prefixed agents and was dropped. The plugin tree still carries skills/commands/hooks/`.mcp.json`, just no `agents/`. |
| MCP | [mcp](https://code.claude.com/docs/en/mcp) · per-tool globs: [settings](https://code.claude.com/docs/en/settings#available-settings) | `agents/mcp/registry.yaml` → plugin-scoped `.mcp.json`. `gate_unless: CHEESE_FLOW` skips servers the cheese-flow plugin already ships. `scope` honored (claude-only). **Per-tool `mcp__server__tool` permission globs are documented on the Settings page, not the MCP page.** |
| System prompt | [CLI flags](https://code.claude.com/docs/en/cli-reference#system-prompt-flags) · [memory cascade](https://code.claude.com/docs/en/memory) | `agents/preamble.md` injected via `--system-prompt-file` in the `cc`/`ccc`/`ccr` wrappers (`zsh/claude.zsh`). `agents/AGENTS.md` → `~/.claude/CLAUDE.md` (user cascade: managed → user → project → local, loads on top). Two docs: the `--system-prompt[-file]` / `--append-system-prompt[-file]` flags live in the CLI reference; the CLAUDE.md/AGENTS.md load order lives in the memory page. |
| Settings / config | [settings](https://code.claude.com/docs/en/settings#available-settings) | `~/.claude/settings.json` is produced by chezmoi's `modify_settings.json` from `chezmoi/lib/claude-settings-authoritative.json`: repo-owned keys win, live/runtime keys that should survive (`permissions.allow`/`deny`/`ask`/`additionalDirectories`, `enabledPlugins`, `extraKnownMarketplaces`) are preserved or intentionally reasserted, and unknown live key paths fail sync until classified. See [[../operations/claude-dotfiles-ownership]]. |
| Skills | [skills](https://code.claude.com/docs/en/skills#frontmatter-reference) | `skills/` (local, copied) + `_registry.yaml` (external, `npx skills add`) → `~/.claude/skills/`. |

## Isolated settings (`ap` isolated launch)

Claude is the **only** harness where `ap launch` builds a closed world with Claude-native CLI flags. An isolated `profiles/<name>/profile.yaml` (`isolated: true`) renders to ephemeral flags (`overlay.py:build_isolated_flags`):

- `--strict-mcp-config --mcp-config <tmp .mcp.json>` — only the profile's MCPs.
- `--setting-sources ""` — strips the inherited user `settings.json`.
- `--tools <csv>` — hard tool whitelist, **only emitted when the profile declares `tools`** (`overlay.py:281` — `if manifest.tools:`).
- `--append-system-prompt-file <profile>/CLAUDE.md` — if `system_prompt` declared.
- `--settings <tmp settings.json>` — `permissions` + `enabledPlugins`.

Gotcha: `--setting-sources ""` closes the **MCP world and inherited settings** (no inherited allowlist), but **not** the built-in tool surface. A profile with **no `tools` key omits `--tools` entirely**, so claude keeps its full default built-in tools (Bash, Read, …) — the closed world is the MCPs + settings, not the tools. Declaring `tools` narrows to exactly that whitelist + `permissions_deny`; leaving it out keeps everything (`todo` does this deliberately, adding `--dangerously-skip-permissions`). Shipped Claude isolated profiles: `review`, `todo`, `fe`, `spec`, `plugin`, `tui`, `oss-docs`, and `skills-doctor`. `mgmt` is not isolated; it reaches GitHub planning through the `gh` CLI + `/gh` skill over Bash.

## System prompt replacement

Only a launch flag replaces Claude's system prompt. `--system-prompt-file` (used by the `cc` wrappers and `bin/dotsclaude`) swaps the default text for `agents/preamble.md`; `--append-system-prompt-file` adds after it. No `settings.json` key does either. A plain `claude` launch, such as a mise shim behind a launcher, therefore sends Anthropic's default prompt. Codex and OpenCode differ: their global config files carry the override (see [[../architecture/t3-code-launch]]).

**Why an output style is not a substitute:** a custom output style looks like a settings-level route, but it never enters the system prompt. Claude Code 2.1.302 delivers the style as an `output_style_instructions` attachment, rendered as a `<system-reminder>` that starts `# Output Style: <name>` inside the first user message. The system blocks stay byte-identical to the default, and `keep-coding-instructions: false` removed nothing from them. So a style only appends, from a lower-authority position.

Verified on 2026-10-18 with a sentinel style in `.claude/output-styles/`, selected by `--settings` and by project `settings.json`, in `-p` and in T3's stream-json mode. Read the result from the session transcript: `api-request-shape` holds the sent system blocks, and the `attachment` entries hold the reminder.

## Quirks

- Docs host is `code.claude.com/docs`, not `docs.claude.com` (that's the API/Agent-SDK surface).
- Agents render **shared-only** to `.claude/agents/<n>.md` (user-scoped, priority 4) — the renderer no longer writes a plugin-scoped (priority 5) copy. Writing both produced duplicate `global:<agent>` entries in Claude's roster (the plugin namespace) for zero benefit, since the user-scoped file already wins precedence and is the cross-harness surface. Body-less agents therefore emit no Claude file (the shared writer is body-guarded); every real registry agent has a `body_path`, so none are dropped.
- `worktree-guard.js` and other pre-tool hooks are Claude-specific (`claude/hooks/`), separate from the harness-agnostic `agents/hooks/` registry.
- Skills with `context: fork` run in the **background by default** (since `2.1.218`); `background: false` in frontmatter forces the invoking turn to wait. `test-sandbox` sets `background: false` because its result is the answer to the turn. The long Opus audits (`nih-audit`, `ghostbuster`) and the TUI skills keep the background default. The nested-subagent depth budget is 3 (since `2.1.219`) and the concurrent-subagent cap is 20 (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`). Whether a backgrounded fork consumes one depth level before its own `Agent` calls is unconfirmed; run `nih-audit` or `ghostbuster` once to check before relying on depth-2 nesting inside them.
- **Linux sandbox uses apt `bwrap`, never brew (2026-10-22)**: Ubuntu sets `kernel.apparmor_restrict_unprivileged_userns = 1`. `/etc/apparmor.d/bwrap-userns-restrict` exempts only the path `/usr/bin/bwrap`. A brew `bwrap` comes earlier on PATH than `/usr/bin` and fails with `setting up uid map: Permission denied`. PR #1412 added brew `bubblewrap` to `packages/packages.yaml`, and a later change removed it. Keep `bwrap` from the apt `bubblewrap` package.
