# T3 Code launch regime — why chezmoi owns Claude launch args

T3 Code (`~/.t3`, systemd unit `t3code.service`) launches Claude through the
Agent SDK as an unattended child session. Chezmoi authors the provider keys
so that T3 sessions use the shared preamble and route file work through tilth
like every other harness.

## What T3 adds to a session

Observed on 2026-10-18 with T3 0.1.0 and Claude Code 2.1.301. The source is
the `api-request-shape` entries of T3 session transcripts, compared with a
plain `claude -p` session.

- **The `t3-code` MCP server.** It has 83 tools: threads, delegated tasks,
  the scheduler, queues, projects, previews, devices, attachments, secrets,
  pull-request links and watches, and worktrees. No overlap with tilth or
  hallouminate.
- **Identity line.** T3 keeps the `claude_code` preset line ("You are Claude
  Code, Anthropic's official CLI for Claude, running within the Claude Agent
  SDK."). A plain `claude -p` session opens with "You are a Claude agent,
  built on Anthropic's Claude Agent SDK."
- **Appended system prompt, about 8,500 characters.** T3 does not change the
  default prompt text. It appends these blocks:
  - `<runtime_info>`: the session runs in T3; images and videos embed by
    absolute path.
  - `<pull_request_linking>`: register every pull request with
    `link_pull_request`; watch and unwatch rules.
  - `## T3 Code orchestration`: delegated tasks versus top-level threads,
    workspace selection before `t3_thread_launch`, scheduled tasks, secret
    requests, and thread links.
  - `### Showing visuals`: build an HTML page, check it with `html_preview`,
    and publish it with `html_render`.
- **`permissionMode: bypassPermissions` by default.** T3 maps its runtime
  mode (`full-access` → `bypassPermissions`, `auto` → `auto`,
  `auto-accept-edits` → `acceptEdits`), but the decode falls back to bypass
  whenever `--dangerously-skip-permissions` is absent from launch args. An
  explicit `--permission-mode` in the claudeAgent `launchArgs` overrides
  every path, including the mode picked in the T3 UI. The registry pins
  `auto` (since 2026-10-06; `acceptEdits` before).

Everything else (claude.ai connectors, plugins, tilth, context7) loads from
`~/.claude` as in an interactive session.

## Preamble wrappers (binaryPath)

T3 launches each harness through `providerInstances.<id>.config.binaryPath`.
The registry points three instances at the `bin/dots*` wrappers. Each wrapper
replaces the native system prompt with `agents/preamble.md`:

| Instance | Wrapper | Mechanism |
|---|---|---|
| `claudeAgent` | `bin/dotsclaude` | `--system-prompt-file <clone>/agents/preamble.md`. T3 still appends its own blocks after the preamble. |
| `codex` | `bin/dotscodex` | `-c model_instructions_file="<clone>/agents/preamble.md"` before the subcommand. T3 runs `<binaryPath> app-server`. |
| `opencode` | `bin/dotsopencode` | Merges work-agent prompts and the preamble path into `OPENCODE_CONFIG_CONTENT`. T3 runs `<binaryPath> serve` and sets that variable (`"{}"` by default). |

**Why wrappers when config already does it:** Codex reads
`model_instructions_file` from `config.toml`, and OpenCode reads its agent
prompts from `opencode.json`. Both are global config, so T3 sessions got the
preamble before the wrappers existed. The wrappers make the override hold
when that config is missing or stale, and the Claude and Codex wrappers read
the live preamble from the clone. Claude has no config key for a replacement
system prompt, so only `dotsclaude` was ever required.

**Before 2026-10-18 05:09 UTC** the claudeAgent `binaryPath` was the mise
shim, and nothing in the repository set it. T3 Claude sessions sent the
default prompt and no preamble. Session transcripts before that time give a
natural default-prompt sample for comparison.

Verification on 2026-10-18:

- `dotscodex exec` and a `dotscodex app-server` turn, with `AGENTS_DOTFILES`
  pointed at a sentinel preamble. Both rollouts recorded the sentinel as
  `session_meta.base_instructions`, so the flag wins over `config.toml`.
- `dotsopencode serve` with `OPENCODE_CONFIG_CONTENT={}`. `/api/config`
  listed the env source with the four work-agent prompts and the preamble
  path.
- `tests/dots-wrappers.bats` covers the launch lines, the TOML escape, the
  caller-config merge, and prompt parity with the OpenCode registry.

## Why the permission mode matters

Under bypass mode Claude Code itself injects a preamble that says to prefer
Bash (`cat`, `grep`, `sed`) over Read/Edit/Write. The text lives in the
claude binary, not in T3. It contradicts the tilth server instructions in
the same prompt. Session analytics for 2026-09-26/27 showed the effect:
short T3 sessions made zero tilth calls and 43% of their Bash calls were
file reads, against 35% in non-T3 sessions.

`acceptEdits` avoided that preamble, but it approves file edits only. Bash
and MCP calls still prompted, so T3 threads stalled on permission asks.

`auto` approves safe actions without prompts. It also injects a "prefer
Bash" preamble (observed 2026-10-06, Claude Code 2.1.289). The tilth
PreToolUse hooks block the shell reads it suggests, so agents fall back to
tilth after one blocked call. Accept that cost over constant prompts.

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
| `chezmoi/.chezmoidata/t3.yaml` → `dot_t3/userdata/modify_settings.json` | `~/.t3/userdata/settings.json` | Merges `providerInstances.{claudeAgent,codex,opencode}` (`driver`, `config.binaryPath`, and the claudeAgent `config.launchArgs`) into the live file. T3 rewrites this file from its UI, so the guard preserves UI state through `lib/drift-gate.sh` with `lib/t3-settings-ignore.txt`. `lib/t3-settings-retired.txt` deletes the legacy `providers` map. |
| `dot_t3/userdata/claude-settings.json` | `~/.t3/userdata/claude-settings.json` | Passed via `--settings`. Sets `disableClaudeAiConnectors: true` for T3 sessions only, so the connectors never push tilth into the deferred tool list. |
| `dot_config/systemd/user/t3code.service.d/telemetry.conf` (Linux only) | `~/.config/systemd/user/t3code.service.d/telemetry.conf` | Sets `T3CODE_TELEMETRY_ENABLED=false` for the background service. A drop-in, because `t3 service install` and `t3 update` rewrite the unit file. `run_onchange_after_reload-t3-service.sh.tmpl` runs `daemon-reload` only; the setting applies at the next service restart. |
| `zsh/core.zsh` | shell profile | Exports `T3CODE_TELEMETRY_ENABLED=false` for the macOS desktop app, which reads the shell profile, and for foreground `t3 serve`. |

The registry string uses a literal `$HOME`; the modify script expands it
because chezmoi data files are not templated. `--settings` in Claude Code
accepts a file path or inline JSON, so a file keeps quoting out of T3's
launch-args tokenizer.

### Why `providerInstances`, not `providers`

T3 0.1.0 stores provider settings as `providerInstances.<id>.{driver,
enabled, config}`. On load, `migrateLegacyProviderSettings` copies a legacy
`providers.<kind>` blob only into an empty default instance slot; "an
explicit instance already in that slot wins". The registry wrote
`providers.claudeAgent.launchArgs` until 2026-10-18. After the first
migration, that key had no effect, and T3 dropped it on each rewrite. The
live `launchArgs` survived only because the one-time migration had copied
it. The registry sets `driver` on each instance so that a fresh settings
file decodes. Source: strings of `~/.t3/runtime/versions/0.1.0/t3`.

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

## T3 Connect push notifications

T3 Connect sends agent activity to the T3 mobile app as push notifications and Live Activities.
This setup uses publish-only mode because Tailscale Serve already gives remote access.
Publish-only mode adds no managed tunnel.[^connect]

On a headless server, run these commands in this order:

```bash
t3 connect link --headless --publish-only   # prints a device URL and code
systemctl --user restart t3code.service     # the link applies at server start
t3 connect status
```

Approve the device code in a browser before it expires (10 minutes).
The restart stops running T3 threads, so do it when no thread is busy.
A good result shows a stored credential, a provisioned environment link, a relay URL, and publishing enabled.
Use `t3 connect publish` or `t3 connect publish --disable` to change only the publish flag.
Sign in to the T3 mobile app with the same account to receive the notifications.

The link survives restarts and reboots.
T3 keeps the link state in `~/.t3/userdata/secrets/cloud-*.bin` with directory mode 700.
The service is enabled with `Restart=always`, and user linger starts it at boot.
Chezmoi does not manage `secrets/`, so `dots sync` does not change the link.
`t3 update` replaces `~/.t3/runtime/`, not `userdata/`.
`t3 connect unlink`, `t3 connect logout`, a deleted `~/.t3`, or a revoked account authorization removes the link.
If notifications stop, run `t3 connect status` first.

Keep the device code, OAuth token, and `secrets/` files out of Git.

[^connect]: Local `t3 connect --help` and `t3 connect link --help` in t3 0.0.45; setup on crabbot verified with `t3 connect status` on 2026-10-10.

## Gotchas

- T3 reads `settings.json` at thread start. Restart T3 or open a new thread
  after `dots sync`.
- The T3 provider instance key is `claudeAgent`, not `claude`.
- The registry owns only each instance `driver`, the three `binaryPath`
  leaves, and the claudeAgent `launchArgs`. Enable toggles, credentials,
  custom models, `defaultThreadEnvMode`, and sidebar state stay T3-owned;
  add new T3 UI keys to `lib/t3-settings-ignore.txt`, not to the registry.
- The registry writes each wrapper path as `$DOTFILES/bin/dots*`. The modify
  script expands `$DOTFILES` to the parent of the chezmoi source directory,
  so the path follows the clone and does not assume `~/Dev/dotfiles`. A
  `chezmoi apply` from a worktree source writes that worktree path; deploy
  through `dots sync` from the main clone. The wrappers find `agents/` from
  their own location unless `DOTFILES_DIR` or `AGENTS_DOTFILES` is set.
- Tests: `tests/t3-config.bats` (settings), `tests/dots-wrappers.bats`
  (wrappers), and `tests/lib-t3-service.bats` (service upgrade).
- T3 themes are not chezmoi-managed. The theme library (upstream PR #5226)
  keeps custom themes in app storage, not in `settings.json`. Import
  `theme/t3/chocolate-donut-2-color-theme.json` (VS Code format) through
  Settings → Appearance → import, then pick it for dark mode.

### Model reasoning defaults (T3 0.1.6)

T3 0.1.6 supports one `defaultModelSelection`, including its options.
Its settings schema does not expose a per-model reasoning-default map.
Custom-model entries cannot override built-in model capabilities; matching slugs only change names.
Do not add same-slug custom models to change reasoning defaults.
The Codex root `model_reasoning_effort` setting does not replace explicit T3 thread options.[^reasoning-defaults]

[^reasoning-defaults]: Installed T3 0.1.6 executable, embedded `ServerSettings`, `CustomModelEntry`, and `providerModelsFromSettings` source; inspected 2026-11-01.

_Source: local T3 0.1.6 schema and model resolver · Updated: 2026-11-01 · Supersedes: none_
