# lspmux

[lspmux](https://codeberg.org/p2502/lspmux) multiplexes LSP server connections
so multiple Claude sessions share a single language server process rather than
each spawning their own.

## Architecture

```
Claude session A ──┐
                   ├── lspmux daemon ── pyright (one process)
Claude session B ──┘
```

Wrapper scripts installed by `dots sync` intercept calls to LSP binaries
(e.g., `pyright`, `typescript-language-server`) and route them through the
lspmux daemon. If the daemon is not running, the wrapper falls back to
executing the real binary directly — no configuration or intervention needed.

Wrapper scripts are installed to `$DOTFILES_DIR/bin/` (`~/Dev/dotfiles/bin/`)
ahead of the real binaries on PATH. The LSP plugin calls the same binary name it
always did; the wrapper handles routing transparently.

## Wrapper behavior

Wrappers fail fast if lspmux is not available:

1. lspmux running → forward request to shared server
2. lspmux not running → **error** (fix: `lspmux server` or check launchd)
3. lspmux not installed → **error** (fix: `cargo install lspmux`)

## Debugging

**Check if a wrapper is being called:**

```bash
# Confirm wrapper is ahead of real binary on PATH
which pyright

# Should show ~/Dev/dotfiles/bin/pyright, not the real binary path
```

**Check daemon status:**

```bash
lspmux status
launchctl list com.lspmux.server
```

**Inspect launchd logs:**

```bash
log show --predicate 'subsystem == "com.lspmux.server"' --last 1h
```

## Performance

- First session: identical to direct execution (no shared server yet, daemon starts one)
- 2nd+ session: near-instant attach (no JIT warm-up, shared parse cache)
- Memory: one server process instead of N, regardless of session count
- Overhead per request: negligible (local Unix socket IPC)

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| `lspmux: command not found` | `~/.cargo/bin` on PATH? | Add to PATH or reinstall: `cargo install lspmux` |
| Daemon not auto-starting | launchd plist installed? | `dots sync` then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lspmux.server.plist` |
| LSP not working at all | Wrapper on PATH? | `which pyright` — should be `~/Dev/dotfiles/bin/pyright` |
| LSP slow (fallback mode) | Daemon running? | `lspmux server` to start manually |
| Config not applied | Config path correct? | Edit `~/Library/Application Support/lspmux/config.toml` |

## Files installed by `dots sync`

| File | Purpose |
|---|---|
| `~/Dev/dotfiles/bin/<lsp-name>` | Wrapper scripts for each LSP (installed via `dots sync`) |
| `~/Library/LaunchAgents/com.lspmux.server.plist` | launchd auto-start agent |
| `~/Library/Application Support/lspmux/config.toml` | lspmux configuration (from template) |

Templates live in `claude/lspmux/` in this repo.
