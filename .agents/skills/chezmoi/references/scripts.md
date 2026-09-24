# Scripts

chezmoi runs scripts as part of `apply`. Filename prefixes determine
when and how often.

## Naming

```text
run_<once|onchange>_<before|after>_<name>.<ext>[.tmpl]
```

| Component | Effect |
|---|---|
| `run_` | Required — marks this as a script |
| `once_` | Run only when contents have not been run successfully before |
| `onchange_` | Run when contents change (keyed by filename) |
| `before_` / `after_` | Order relative to applying files (default = after) |
| `.tmpl` | Render as Go template before executing |

Plain `run_<name>` runs every `apply` — rare and usually wrong.

## Common patterns

### One-time install on first apply

```sh
# .chezmoiscripts/run_once_before_install-packages.sh.tmpl
#!/bin/sh
{{- if eq .chezmoi.os "darwin" }}
brew bundle --file=- <<EOF
brew "ripgrep"
brew "fd"
brew "fzf"
{{- if .work }}
brew "awscli"
{{- end }}
EOF
{{- else if eq .chezmoi.os "linux" }}
sudo apt-get update
sudo apt-get install -y ripgrep fd-find fzf
{{- end }}
```

### Re-run when a manifest changes

```sh
# .chezmoiscripts/run_onchange_after_brewfile.sh.tmpl
#!/bin/sh
# hash: {{ include "Brewfile" | sha256sum }}
brew bundle --file={{ joinPath .chezmoi.sourceDir "Brewfile" | quote }}
```

Edit `Brewfile` → `chezmoi apply` re-runs this script. Touch the
manifest hash by editing it; `onchange_` keys off the rendered contents.

### Bootstrap a tool with a per-OS branch

```sh
# .chezmoiscripts/run_once_before_install-rust.sh.tmpl
#!/bin/sh
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path
fi
```

### Conditional based on prompt answer

```sh
# .chezmoiscripts/run_once_after_install-work-tools.sh.tmpl
{{- if .work }}
#!/bin/sh
brew install awscli kubectl helm
{{- end }}
```

If the conditional renders to an empty file, chezmoi skips it.

## .chezmoiscripts/

Scripts that don't correspond to a target file go in `.chezmoiscripts/`.
`run_*` files in any source directory work too, but they map to a
virtual entry in the target tree (which is confusing). Use
`.chezmoiscripts/` by default.

## Working directory

A script in `~/.local/share/chezmoi/dir/run_script` runs with cwd set
to `~/dir`. A script under `.chezmoiscripts/` runs with cwd set to
`$HOME`.

## CHEZMOI environment variables

When chezmoi runs a script, it exports the same template data as env
vars:

| Variable | Source |
|---|---|
| `CHEZMOI_OS` | `.chezmoi.os` |
| `CHEZMOI_ARCH` | `.chezmoi.arch` |
| `CHEZMOI_HOSTNAME` | `.chezmoi.hostname` |
| `CHEZMOI_USERNAME` | `.chezmoi.username` |
| `CHEZMOI_HOME_DIR` | `.chezmoi.homeDir` |
| `CHEZMOI_SOURCE_DIR` | `.chezmoi.sourceDir` |

Add custom env via `[scriptEnv]` in `chezmoi.toml`.

## Pitfalls

### `fork/exec /tmp/...: exec format error`

Cause: a newline before `#!` because of `{{- ... }}` template trimming
or a leading blank line. Fix:

```go-template
{{- /* nothing should render before the shebang */ -}}
#!/bin/sh
```

The `-` on either side of the closing `}}` of the *first* template
line trims the newline.

### `fork/exec /tmp/...: permission denied`

Cause: `$TMPDIR` is mounted `noexec` (common on hardened Linux).
Configure chezmoi to use a different scratch dir:

```toml
# ~/.config/chezmoi/chezmoi.toml
scriptTempDir = "~/.cache/chezmoi"
```

### Scripts run in unexpected order

Default order is alphabetical within `before_` and `after_` groups. If
order matters, prefix with numbers:
`run_once_before_00-prereqs.sh.tmpl`,
`run_once_before_10-brew.sh.tmpl`.

### `run_once_` thinks contents changed but they didn't

The "contents" key is the *rendered* content, not the source. If the
template depends on `.chezmoi.hostname`, the script re-runs on every
host — which is usually what you want. If it isn't, use a constant
template or move the variable bit to a separate `run_onchange_` script.

### Scripts blocking interactive apply

`apply` is non-interactive by default. A script that prompts for input
(e.g. `sudo` without cached creds) hangs forever. Run `sudo -v` before
`chezmoi apply` to cache credentials — `--interactive` does not
authenticate `sudo` by itself — or use a passwordless sudo entry for
the install commands you need.

## Testing scripts

```bash
chezmoi execute-template < .chezmoiscripts/run_once_before_install-packages.sh.tmpl
chezmoi apply --dry-run -v   # shows scripts that would run
chezmoi apply --include=scripts
```

For Bats-driven CI, render the script to disk and run shellcheck on it
before applying.

## Application order

`chezmoi apply` is deterministic. Each run does these steps:

1. Read the source state and the destination state, then compute the target state.
2. Run `run_before_` scripts in ASCII order of target name.
3. Update entries in ASCII order of target name.
   Directories come before the files they contain, including directories that externals create.
   chezmoi fetches and expands externals in this step.
4. Run `run_after_` scripts in ASCII order.

Consequences:

- A `run_before_` script must not read a file that an external provides. Externals apply in step 3.
- chezmoi compares target names with all attribute prefixes removed.
  Given `create_alpha` and `modify_dot_beta`, `.beta` updates before `alpha`, because `.beta` < `alpha` in ASCII.
- chezmoi assumes that the source and the destination do not change during a run.
  A `run_before_` script that writes into either one causes undefined behavior.
