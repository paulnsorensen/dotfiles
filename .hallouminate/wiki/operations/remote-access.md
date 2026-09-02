# Remote Access (Tailscale + mosh + tmux)

A resilient remote-shell stack for reaching your own machines from anywhere: **Tailscale** (private WireGuard mesh — the transport) → SSH bootstrap → **mosh** (UDP shell that survives roaming, sleep, and IP changes) → **tmux** (session persistence across disconnects). Landed via PR #206, consolidated into the tmux-settings PR (#315).

Canonical invocation, wrapped by the `mtmux` shell function (`zsh/aliases.zsh`):

```bash
mtmux <host> [session]   # = mosh --predict=adaptive <host> -- tmux new -A -s <session>
                         # host = MagicDNS name or Tailscale IP; session defaults to "main"
```

`tmux new -A -s` (attach-or-create) means a dropped connection leaves the session running; the next `mtmux` re-attaches it.

## What the repo wires automatically (`dots sync`)

- **mosh** — a plain brew formula in `packages/packages.yaml` (mac + linux). Listens on UDP 60000–61000.
- **`zshenv`** (root `zshenv`, sourced for *every* zsh invocation incl. non-interactive inbound SSH/mosh):
  - Sets a UTF-8 `LANG` default (`export LANG="${LANG:-en_US.UTF-8}"`) — **mosh refuses to start without a UTF-8 locale**, and a non-interactive inbound session often has none.
  - Prepends `/opt/homebrew/bin` to `PATH` on Apple Silicon only — an inbound SSH/mosh session must find `mosh-server`, which isn't on macOS `path_helper`'s default PATH.
- **`tmux.conf`** already supports `tmux new -A -s` — no tmux change needed.

## Tailscale is NOT auto-installed — and why

Tailscale is a **manual, one-time install**, documented as a comment in `packages/packages.yaml` (not an entry). The reason is the gotcha worth remembering:

- **macOS**: install the website / App Store GUI variant (a single variant — never run two side by side). That GUI client is the daemon.
- **Linux**: the official installer `curl -fsSL https://tailscale.com/install.sh | sh`, which adds Tailscale's apt repo **and wires the `tailscaled` systemd daemon**. Then `tailscale up`.

Why not a `packages.yaml` entry? Main (PR #304) **replaced the apt package path with Homebrew-on-Linux** (`packages/sync.sh` no longer has `sync_apt`/`apt_check_pkg`). #206 was originally built against the old apt path with a custom `apt_install:` field that surfaced the official installer — that whole mechanism was deleted in #304. Under the brew model, a `- tailscale: { platform: linux }` entry would just run `brew install tailscale`, which provides the *binaries* but **not** the systemd daemon a remote-access node needs. So the official installer remains the correct path, and Tailscale stays a documented manual step rather than a half-working auto-install. (This is also why the envelope of #206 dropped its `apt_install` field and apt-source sync code — they were orphaned by #304.)

## Other manual one-time steps (can't be dotfiles)

- **macOS, to mosh *into* this Mac**: enable OpenSSH — System Settings → General → Sharing → **Remote Login** (or `sudo systemsetup -setremotelogin on`). mosh bootstraps over OpenSSH even though Tailscale is the transport. Tailscale's *own* SSH server is a separate feature (open-source CLI variant only) and is not needed for the mosh path.
- **Linux host**: `sudo systemctl enable --now ssh` and `locale-gen en_US.UTF-8` (mosh's UTF-8 requirement, server side).
- **Both**: `tailscale up`, then connect by MagicDNS name (`mtmux <machine>`). The default ACL already permits your own devices.

## Slow or bursty output: client backpressure and window-size contention

Run `tmux-clients` (`zsh/aliases.zsh`) to see each client's `written`,
`discarded`, and size. A nonzero `discarded` means that client fell behind.

**Discard mechanism.** Since tmux 2.5, `tty.c` discards a client's output
buffer once it exceeds 8x its pane area in bytes, checked every 100 ms, and
resumes below 1/8 pane area, then forces a full redraw of that client
(tmux CHANGES, 2017-05-09: "discard output until it is drained and we are
able to do a full redraw"). This is the buffer-then-jump feel. No config
tunes or disables this (tmux issue #1019, open).

**Cause 1: slow client.** A client that reads slower than tmux writes — a
laggy phone link, a slow renderer — fills the buffer, triggering a discard
and redraw. **Cause 2: window-size contention.** `window-size latest` sizes
shared windows to whichever attached client acted most recently (tmux.1);
a small phone client going active can shrink the window for everyone.
Whether a better `window-size`/`aggressive-resize` default exists for this
mix of clients is an open question the research did not confirm.

**Remedies, in order:**

1. Detach stale or idle clients with `tmux-detach-others` (`tmux
   detach-client -a`) so only the active client drives sizing.
2. Give phone clients their own session name instead of sharing one; moshi
   lets the user set the tmux session it attaches (getmoshi.app/docs/tmux).
3. Keep cmux updated. Two cmux clients on one remote tmux session drove the
   tmux server to 100% CPU (cmux issue #10129), fixed by cmux PR #10142.
   A related freeze during heavy output stays open (cmux issue #10471).
4. Compare plain Ghostty SSH against cmux's ssh-tmux mirror to isolate
   client render cost from tmux's own discard behavior.

Mosh paces full-screen redraws at half the smoothed round-trip time (MIT
mosh paper), so large outputs over mosh look chunky by design, not by bug.
`MOSH_SERVER_NETWORK_TMOUT` resets on any datagram, so a roaming phone
client keeps its mosh-server alive across network changes.

## Related

- [[sync-and-chezmoi]] — how `packages/packages.yaml` and `dots sync` deploy brew formulae.
- [[tmux-plugin-gotchas]] — the tmux side of the stack (plugin ordering, continuum/resurrect).
