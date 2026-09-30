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

## Desktop installation and Tailscale connections

The package registry installs the macOS desktop app through the `t3-code` cask.
The app updates itself; `greedy: false` excludes it from forced cask upgrades.[^desktop]
Mise separately owns the pinned `t3` CLI used on servers.[^cli]

Run `dots sync --no-upgrade` to install missing packages without upgrading unrelated packages.

Join the Mac and server to the same tailnet.
For an existing server, run this command on that server:[^remote]

```bash
t3 pair --tailscale
```

Paste the fresh pairing URL into **Settings → Connections → Add environment** in the desktop app.
The HTTPS route persists across restarts.
Use `--tailscale-serve-port 8443` if the default port is occupied.[^remote]
Check existing Tailscale Serve routes before changing them.

For a new foreground server, use:[^remote]

```bash
t3 serve --tailscale-serve
```

Alternatively, select **SSH** in **Add environment** and enter `user@tailscale-host`.
T3 starts or reuses a remote server and manages the tunnel.[^remote]

Keep pairing URLs, tokens, and client authorization state outside Git.
Pair each client separately; do not copy authenticated app storage through chezmoi.
Pairing URLs authorize access and must stay private.[^remote]
The dotfiles registry manages launch settings, not authenticated remote connections.

See [[../operations/remote-access]] for Tailscale installation.

[^desktop]: `packages/packages.yaml`, macOS-only entries; [Homebrew T3 Code cask](https://formulae.brew.sh/cask/t3-code), checked 2026-09-29.
[^cli]: `chezmoi/dot_config/mise/config.toml:93`; local `t3 --version` reports 0.0.42.
[^remote]: [T3 Code remote access](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md), checked 2026-09-29. Local `t3 pair --help` confirms both Tailscale flags in 0.0.42.

_Source: package registry, T3 CLI help, and upstream documentation · Updated: 2026-09-29 · Supersedes: none_

## Service version upgrades

The service does not run the mise-installed `t3` CLI. `t3 service install`
writes a unit whose `ExecStart` points at its own runtime copy,
`~/.t3/runtime/versions/<version>/t3`, and
`~/.t3/runtime/service-state.json` records `activeVersion`. A bump of the
`npm:t3` pin in `chezmoi/dot_config/mise/config.toml` therefore never moves
the headless server by itself.

`dots sync` closes that gap. `sync_mise` in `packages/sync.sh` calls
`sync_t3_service` (`packages/lib-t3-service.sh`) after `mise install`. When
a service is installed and its active version is older than the pin, it runs
`t3 update <pin> --yes`, which restarts the service and cuts off running
threads. It never downgrades a service that a manual `t3 update` moved
ahead of the pin. A failure only warns.

`t3 update` does not migrate `service-state.json` across a state protocol
change. The 0.0.42 → 0.0.44 update (2026-09-30) left protocol 2 on disk.
The 0.0.44 launcher logged `Service state is invalid or unsupported`,
crash-looped, and systemd hit `StartLimitBurst`. Repair: `t3 service
install` from the new version rewrites the state as protocol 3, after
`systemctl --user reset-failed t3code.service` clears the start limit.
`sync_t3_service` runs that repair after every update, and also whenever
`t3 service status` reports `needs an update or repair`.

mise hides fresh `npm:t3` releases behind its `minimum_release_age`, so
`mise upgrade --bump` can trail Renovate's 4-hour soak by days.

## Gotchas

- T3 reads `settings.json` at thread start. Restart T3 or open a new thread
  after `dots sync`.
- The T3 provider key is `claudeAgent`, not `claude`.
- Only `providers.claudeAgent.launchArgs` is registry-owned. Provider
  toggles, `defaultThreadEnvMode`, and sidebar state stay T3-owned; add new
  T3 UI keys to `lib/t3-settings-ignore.txt`, not to the registry.
- Tests: `tests/t3-config.bats` (settings) and `tests/lib-t3-service.bats`
  (service upgrade).
