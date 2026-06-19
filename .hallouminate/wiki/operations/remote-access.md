# Remote Access (Tailscale + mosh + tmux)

A resilient remote-shell stack for reaching your own machines from anywhere: **Tailscale** (private WireGuard mesh — the transport) → SSH bootstrap → **mosh** (UDP shell that survives roaming, sleep, and IP changes) → **tmux** (session persistence across disconnects). Landed via PR #206, consolidated into the tmux-settings PR (#315).

Canonical invocation, wrapped by the `mtmux` shell function (`zsh/aliases.zsh`):

```bash
mtmux <host> [session]   # = mosh <host> -- tmux new -A -s <session>
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

## Related

- [[sync-and-chezmoi]] — how `packages/packages.yaml` and `dots sync` deploy brew formulae.
- [[tmux-plugin-gotchas]] — the tmux side of the stack (plugin ordering, continuum/resurrect).
