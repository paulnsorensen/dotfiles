# Pitfalls

The chezmoi troubleshooting page is the canonical reference:
<https://chezmoi.io/user-guide/frequently-asked-questions/troubleshooting/>.
The items below are the ones that bite people most often.

## Editing the source directly

**Problem.** You open `~/.local/share/chezmoi/dot_zshrc` in `$EDITOR`,
edit, save. Next `chezmoi apply` doesn't change anything (template
tokens are literal) or chezmoi can't decrypt (you've corrupted the
encrypted blob).

**Fix.** Always `chezmoi edit ~/.zshrc`. chezmoi opens a hardlink in a
temp dir; decrypts and templates round-trip transparently; your editor
sees the right syntax (because the basename matches the target).

For pure git operations (commit, log, push) use `chezmoi cd`, which
drops you into the source dir.

## Forgetting `chezmoi diff` before `apply`

**Problem.** `exact_dot_config/nvim/` deletes a plugin you installed
manually but forgot to re-add. `apply` happily wipes it because the
source state didn't include it.

**Fix.** `chezmoi diff` (or `chezmoi apply --dry-run -v`) every time.
On personal machines develop the muscle of always doing the dry run
first; on shared machines it's mandatory.

## `.chezmoiignore` matches the wrong paths

**Problem.** You add `~/.zshrc` to `.chezmoiignore` expecting chezmoi
to skip it. It doesn't, because the ignore matches *source-relative*
paths.

**Fix.** Use the source name: `dot_zshrc`. Same for
`private_dot_ssh/config`. The file is also a template — gate
platform-specific entries with
`{{- if ne .chezmoi.os "darwin" }}...{{- end }}`.

## CRLF line endings on Windows

**Problem.** Editing templates on Windows produces CRLF endings. The
rendered shell scripts then fail on Linux/macOS with cryptic errors.

**Fix.** Either:

- Add a `.gitattributes` to the dotfiles repo with `* text eol=lf`, OR
- Set `core.autocrlf = input` in the dotfiles repo's `.git/config`.

## Prompt functions in regular templates

**Problem.** You use `promptStringOnce` in a regular dotfile template.
`chezmoi apply` now prompts you every time.

**Fix.** Move the prompt to `.chezmoi.toml.tmpl`. The answer becomes a
`[data]` key, which the regular template references as `{{ .key }}`.
Prompt functions are config-template-only by design — chezmoi runs
templates frequently (apply / diff / status / re-add) and interactive
prompts in the middle of automation are unusable.

## `exec format error` running scripts

See `references/scripts.md` — newline before `#!`. Fix with `-`
template trim on the first line.

## `permission denied` running scripts

See `references/scripts.md` — `noexec` `$TMPDIR`. Set `scriptTempDir`
in config.

## Encrypted age files prompted on every apply

**Problem.** Your age identity is passphrase-encrypted but you didn't
set up `age-plugin-yubikey` or a passphrase cache, so you're typing
the passphrase on every apply.

**Fix.** Either store the identity unencrypted at
`~/.config/chezmoi/key.txt` (mode 600 on a trusted machine is fine) or
use `age-plugin-yubikey` so the hardware token unlocks it.

## `exact_` deleted my files

**Problem.** `exact_` on a directory tells chezmoi to remove anything
in the target dir not present in the source. You used it on
`~/.config/` and now half your config is gone.

**Fix.** `exact_` is for narrow, fully-managed directories (e.g. a
small `~/.config/git/`). On `~/.config/` overall, omit `exact_` and
let chezmoi only manage what you told it to manage.

## Forgetting to add `key.txt.age` to `.chezmoiignore`

**Problem.** You committed your passphrase-encrypted age identity at
the source root. chezmoi tries to render it as a target file, fails or
writes garbage to `~/key.txt.age`.

**Fix.** Add `key.txt.age` (or wherever you put it) to
`.chezmoiignore`. It's data for your bootstrap script, not a target.

## `chezmoi.toml` vs `.chezmoi.toml.tmpl` confusion

There are two configs:

- `~/.config/chezmoi/chezmoi.toml` — the *rendered* config, lives
  outside the source repo. This is what chezmoi reads at runtime.
- `~/.local/share/chezmoi/.chezmoi.toml.tmpl` — the *template*, lives
  inside the source repo. chezmoi renders this once on `chezmoi init`
  and writes the result to the path above.

Edit the `.tmpl` for repeatable bootstrap behavior. Edit the rendered
`.toml` only for ephemeral local overrides — and even then it's
better to add machine data via `chezmoi edit-config-template`.

## Symlinks vs symlink mode

**Problem.** You set `mode = "symlink"` expecting `chezmoi apply` to
symlink everything. It doesn't symlink encrypted, executable, private,
or templated files (because those need real content) and you don't
realize the difference until something is hard to debug.

**Fix.** Use `mode = "symlink"` only if you understand it as
"symlink-when-possible". Most users want the default `mode = "file"`
(real files, copy-on-apply) — it's predictable.

## Plain text `.chezmoidata` in a public repo

**Problem.** You put `email`, `work_org`, etc. in `.chezmoidata/local.yaml`
"because it's not secret"… then notice the public repo exposes your
work email and team identifiers, which feed phishing.

**Fix.** Treat `.chezmoidata/` like any other source file. Anything
identity-related goes in `.chezmoi.toml.tmpl` via `promptStringOnce`,
or fetched from a password manager at apply time. `.chezmoidata/` is
for *machine* data (Brew taps, package lists, etc.) that's the same
across humans.

## `chezmoi init` with a stale clone

**Problem.** `chezmoi init` on a machine that already has a partial
clone leaves the repo in a half-state — branches mismatched, config
unrendered.

**Fix.** Either start fresh (`rm -rf ~/.local/share/chezmoi` and
`chezmoi init <repo>`) or use `chezmoi cd` and reconcile the git
state manually before `chezmoi init --apply`.

## Diagnostic first-aid kit

```bash
chezmoi doctor                  # one-shot health check (deps, paths, config)
chezmoi data                    # dump the entire template namespace
chezmoi managed                 # list every target chezmoi knows about
chezmoi unmanaged               # files in target dir chezmoi could manage
chezmoi verify                  # exit non-zero if state differs
chezmoi state dump              # raw script-state DB
chezmoi execute-template '...'  # render a template fragment ad hoc
```

`chezmoi doctor` is the first command to run when something is off —
it catches missing CLIs (`op`, `age`, `gpg`, `bw`), broken paths,
incompatible shell integration, and encryption misconfigurations in
one pass.
