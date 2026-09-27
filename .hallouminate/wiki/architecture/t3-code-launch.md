# T3 Code launch regime — why chezmoi owns Claude launch args

T3 Code (`~/.t3`, systemd unit `t3code.service`) launches Claude through the
Agent SDK as an unattended child session. Chezmoi authors two keys for it so
T3 sessions route file work through tilth like every other harness.

## What T3 adds to a session

- **The `t3-code` MCP server.** In-process, 21 tools: `preview_*` (browser
  preview drive), `device_*`, and `link_pull_request` /
  `unlink_pull_request` / `list_thread_pull_requests`. No overlap with tilth
  or hallouminate.
- **Appended system prompt.** A `<runtime_info>` line, a worktree-isolation
  block, and `<pull_request_linking>` rules.
- **`permissionMode: bypassPermissions` by default.** T3 maps its runtime
  mode (`full-access` → `bypassPermissions`, `auto` → `auto`,
  `auto-accept-edits` → `acceptEdits`), but the decode falls back to bypass
  whenever `--dangerously-skip-permissions` is absent from launch args. An
  explicit `--permission-mode` in `providers.claudeAgent.launchArgs`
  overrides every path.

Everything else (claude.ai connectors, plugins, tilth, context7) loads from
`~/.claude` as in an interactive session.

## Why bypass mode matters

Under bypass mode Claude Code itself injects a preamble that says to prefer
Bash (`cat`, `grep`, `sed`) over Read/Edit/Write. The text lives in the
claude binary, not in T3. It contradicts the tilth server instructions in
the same prompt. Session analytics for 2026-09-26/27 showed the effect:
short T3 sessions made zero tilth calls and 43% of their Bash calls were
file reads, against 35% in non-T3 sessions.

## Why hallouminate timed out only in T3

The plugin runs `hallouminate serve` via PATH. The T3 service PATH puts
`~/.cargo/bin` first, where a stale 0.4.1 Rust build hung on `serve` and
hit the 30 s `CONNECT_TIMEOUT`. `~/.local/bin/hallouminate` (0.11.1, npm
nightly) answers in about 1.5 s. Fix: remove the cargo binary and
`mise reshim`. Not a chezmoi concern, recorded here because the symptom
looked like a T3 MCP problem.

## What chezmoi owns

| Source | Target | Purpose |
|---|---|---|
| `chezmoi/.chezmoidata/t3.yaml` → `dot_t3/userdata/modify_settings.json` | `~/.t3/userdata/settings.json` | Merges `providers.claudeAgent.launchArgs` into the live file. T3 rewrites this file from its UI, so the guard preserves UI state through `lib/drift-gate.sh` with `lib/t3-settings-ignore.txt`. |
| `dot_t3/userdata/claude-settings.json` | `~/.t3/userdata/claude-settings.json` | Passed via `--settings`. Sets `disableClaudeAiConnectors: true` for T3 sessions only, so the connectors never push tilth into the deferred tool list. |

The registry string uses a literal `$HOME`; the modify script expands it
because chezmoi data files are not templated. `--settings` in Claude Code
accepts a file path or inline JSON, so a file keeps quoting out of T3's
launch-args tokenizer.

## Gotchas

- T3 reads `settings.json` at thread start. Restart T3 or open a new thread
  after `dots sync`.
- The T3 provider key is `claudeAgent`, not `claude`.
- Only `providers.claudeAgent.launchArgs` is registry-owned. Provider
  toggles, `defaultThreadEnvMode`, and sidebar state stay T3-owned; add new
  T3 UI keys to `lib/t3-settings-ignore.txt`, not to the registry.
- Tests: `tests/t3-config.bats`.
