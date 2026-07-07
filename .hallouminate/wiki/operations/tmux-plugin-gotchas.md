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

The canonical layout in `tmux/tmux.conf`:

```
# 1. load theme.conf (sets @thm_* + status-right)
source-file ~/.config/tmux/theme.conf

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
