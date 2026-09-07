# tmux plugin wiring and theming gotchas

## continuum silently disarms when status-right is overwritten after plugin load

`tmux-continuum` arms its interval-save hook by appending a call to
`continuum_save.sh` to `status-right` at plugin load time. Any tmux config
that rewrites `status-right` *after* the TPM run line silently removes that
hook — no error, saves just stop.

This bit us in June 2026: `@continuum-restore` was on, resurrect was declared,
but no save files existed anywhere under `~/.local/share/tmux/resurrect/`. The
symptom looked like resurrect not working; the root cause was continuum never
saving because the save hook had been wiped.

**Verify continuum is actually armed:**

```sh
tmux show-option -gv status-right   # must contain continuum_save.sh
ls ~/.local/share/tmux/resurrect/   # must have at least one save file after ~1 minute
```

## Ordering contract in tmux.conf

Because of how continuum arms itself, the ordering is strict:

1. **`set -g status-right …`** (theme/status-right composition, including
   `#{E:@catppuccin_status_*}` modules) — do this *before* the TPM run line.
2. **`run ~/.tmux/plugins/tpm/tpm`** — TPM runs all plugins; continuum appends
   to whatever `status-right` is at this moment.
3. catppuccin must be declared *before* tmux-resurrect and tmux-continuum in the
   `@plugin` list so its `status-right` expressions are already expanded when
   continuum appends.

The canonical layout in root `tmux.conf`:

```
# 1. load theme.conf (sets @thm_* + status-right)
source-file -q ~/Dev/dotfiles/tmux/theme.conf

# 2. plugin declarations (order matters)
set -g @plugin 'catppuccin/tmux'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'

# 3. TPM run line (always last)
run '~/.tmux/plugins/tpm/tpm'
```

**Sanctioned exception — post-TPM `set` lines that don't touch `status-right`.**
"Always last" is specifically about `status-right` (and anything continuum
appends to it). Re-asserting an *unrelated* option after the TPM run is safe.
As of July 2026, `tmux.conf` has no post-TPM `set` line — tmux-sensible was
removed (nearly-dead-weight; its two useful effects, `display-time 4000` and
`status-keys vi`, were inlined into the Quality of life block instead), which
was the only reason a post-TPM re-assert existed: tmux-sensible unconditionally
flipped `status-keys` to emacs on load (verified in its source), so the old
config re-asserted vi after TPM to win the race. The rule to remember stands
regardless: never rewrite `status-right` after TPM; any other post-TPM `set`
is fine if one is ever needed again.

## catppuccin/tmux palette injection via theme/generate.sh

`theme/generate.sh` emits `set -g @thm_*` overrides into `tmux/theme.conf`
before TPM loads. catppuccin/tmux v2 reads these user options and uses them
instead of its built-in flavour definitions. This means the repo's base24
scheme (not the stock catppuccin mocha/latte palette) drives all catppuccin
colours.

`tmux/theme.conf` is a **generated artifact** — do not hand-edit it. To change
the palette, edit `theme/schemes/<name>.yaml` and run `dots sync` (which calls
`theme/generate.sh`) to regenerate.

## Live plugin tree vs repo tree

- `~/.tmux/plugins/` — the live installs managed by TPM (independent clones).
  This is what tmux actually loads.
- `tmux/plugins/` in the repo — gitignored and **unreferenced as of June 2026**.
  It is dead weight left over from an earlier layout. Do not add files here
  expecting them to be loaded.

## Isolated smoke checks

Use a private socket and a temporary `@resurrect-dir` before loading root `tmux.conf`.
A separate socket protects user sessions, but it does not separate resurrect save files.
The save-directory override prevents test sessions from replacing the user's saved sessions.[^isolation]

The 2026-09-07 trial uses tmux 3.7b and agent-tty 0.5.0.
It checks configured options, TPM bindings, prefix splits with cwd retention, pane focus, copy-mode entry and exit, and detach.
Continuum's save hook remains armed after a second config load.
Manual resurrect save writes the test session into the temporary directory.
Automatic restore stays off by design; this prevents stale sessions from appearing during a fresh launch.[^restore]

Window dimensions match 120x40, 80x24, and 40x15, minus one status row.
Initial agent-tty resize captures show stale duplicate status rows.
An explicit `tmux refresh-client` produces clean frames at all three sizes.
The trial does not establish whether tmux or the capture tool causes the stale frames.
The zsh prompt wraps inside narrow panes; the tmux borders and status line remain intact after refresh.
These captures establish layout evidence, not terminal palette fidelity.
The trial does not test physical mouse input, the OS clipboard, or Ghostty's extended-key negotiation.
All test clients and servers are removed after the trial.[^trial]

[^isolation]: Installed `tmux-resurrect/scripts/helpers.sh:1-6` selects a shared default directory unless `@resurrect-dir` overrides it.
[^restore]: `tmux.conf:172-175`.
[^trial]: Local 2026-09-07 trial: `.context/tmux-smoke.py`, `.context/tmux-smoke.log`, and `.context/tmux-smoke-refreshed.log`. These files are gitignored evidence.
