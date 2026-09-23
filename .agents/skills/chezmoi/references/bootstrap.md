# Bootstrap recipe

A complete, production-grade bootstrap for a fleet of machines (work /
personal / homelab / headless).

## End-to-end new machine flow

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply $GITHUB_USERNAME
```

This:

1. Installs the chezmoi binary to `~/.local/bin/`
2. Clones `https://github.com/$GITHUB_USERNAME/dotfiles` into
   `~/.local/share/chezmoi`
3. Renders `.chezmoi.toml.tmpl` to `~/.config/chezmoi/chezmoi.toml`,
   prompting for any `prompt*Once` answers (e.g. `promptStringOnce`, `promptBoolOnce`)
4. Runs templated `run_once_before_*` scripts (typically
   `install-packages`)
5. Renders and writes every dotfile to `~`
6. Runs templated `run_once_after_*` scripts

If your bootstrap depends on `op` or `age`, install those *first* via
the install-packages script, then move user-config that needs them
into a later `run_once_after_*` step.

## .chezmoi.toml.tmpl

The single most important file in the repo. It captures per-machine
choices on first init and persists them.

```go-template
{{/* prompt the user once on first init, persist answers */}}
{{- $email := promptStringOnce . "email" "Email address" -}}
{{- $personal := promptBoolOnce . "personal" "Is this a personal machine?" -}}
{{- $work := promptBoolOnce . "work" "Is this a work machine?" -}}
{{- $headless := promptBoolOnce . "headless" "Is this a headless server?" -}}
{{- $use_secrets := promptBoolOnce . "use_secrets" "Pull secrets from 1Password?" -}}

[data]
email = {{ $email | quote }}
personal = {{ $personal }}
work = {{ $work }}
headless = {{ $headless }}
use_secrets = {{ $use_secrets }}

{{- /* age encryption — only set up if the key file exists */ -}}
{{- if stat (joinPath .chezmoi.homeDir ".config/chezmoi/key.txt") }}

encryption = "age"
[age]
identity = "~/.config/chezmoi/key.txt"
recipient = "age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
{{- end }}
```

## .chezmoiignore (templated)

Skip platform-specific files on the wrong platform, and
headless-incompatible files on servers:

```go-template
README.md
LICENSE
.editorconfig

{{- if ne .chezmoi.os "darwin" }}
Library/
private_dot_config/karabiner
{{- end }}

{{- if .headless }}
private_dot_config/alacritty
private_dot_config/wezterm
{{- end }}

{{- if not .work }}
private_dot_aws
{{- end }}
```

## run_once_before_install-packages.sh.tmpl

```sh
#!/bin/sh
set -eu

{{- if eq .chezmoi.os "darwin" }}

# install Homebrew if missing
if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

brew bundle --file=- <<EOF
brew "ripgrep"
brew "fd"
brew "fzf"
brew "git-delta"
brew "neovim"
{{- if .personal }}
cask "rectangle"
cask "raycast"
{{- end }}
{{- if .work }}
brew "awscli"
brew "kubectl"
{{- end }}
EOF

{{- else if eq .chezmoi.os "linux" }}

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ripgrep fd-find fzf neovim
fi

{{- end }}
```

## Per-machine config template

Example `private_dot_gitconfig.tmpl`:

```go-template
[user]
    name = Paul Sorensen
    email = {{ .email | quote }}

[core]
    editor = nvim
    pager = delta

{{- if .work }}
[user]
    signingkey = {{ onepasswordRead "op://Work/git-signing-key/public-key" }}
[commit]
    gpgsign = true
{{- end }}

{{- if eq .chezmoi.os "darwin" }}
[credential]
    helper = osxkeychain
{{- else if eq .chezmoi.os "linux" }}
[credential]
    helper = store
{{- end }}
```

## Repo layout

```text
~/.local/share/chezmoi/
├── .chezmoi.toml.tmpl              # config template — rendered first
├── .chezmoiignore                  # source-relative ignores, templated
├── .chezmoiscripts/
│   └── run_once_before_install-packages.sh.tmpl
├── .chezmoidata/
│   └── machines.yaml               # non-secret machine metadata
├── .chezmoitemplates/
│   └── ssh-prelude                 # reusable fragment
├── private_dot_ssh/
│   ├── encrypted_config.age        # decrypt-on-apply
│   └── encrypted_id_ed25519.age
├── private_dot_gitconfig.tmpl
├── dot_zshrc.tmpl
└── dot_config/
    ├── nvim/                       # exact_ optional, narrow-managed
    └── git/
        └── ignore
```

## Sync from another machine

```bash
chezmoi update                                              # = git pull --autostash --rebase + apply
chezmoi git pull -- --autostash --rebase && chezmoi diff    # preview only — no apply
```

If you've made local changes:

```bash
chezmoi cd            # subshell in source dir
git pull --rebase     # resolve conflicts as normal git
exit
chezmoi apply
```

For a long-lived multi-machine setup, prefer per-machine working
branches that get rebased onto `main` after merging — same pattern
as any normal repo.

## Sanity checks

After bootstrap, verify:

```bash
chezmoi doctor          # full health check (deps, paths, encryption, shell)
chezmoi data            # dump rendered template namespace
chezmoi managed | head  # list of managed targets
chezmoi unmanaged       # files in target dir that chezmoi could manage
chezmoi verify          # exit non-zero if state differs
```

`chezmoi doctor` is gold — it reports missing dependencies (`op`,
`age`, etc.), broken paths, encryption misconfigurations, and shell
integration issues in one pass. Run it as the last step of any
bootstrap script you commit, so a non-zero exit halts a broken setup
before it gets used.

## CI for dotfiles (optional)

If the dotfiles repo is shared or load-bearing, add a Bats test
harness that:

1. Spins up a clean container (Ubuntu / Debian / Alpine).
2. Runs the install one-liner non-interactively
   (`CHEZMOI_PERSONAL=true` etc. as env vars consumed by the
   `.chezmoi.toml.tmpl` via `env "CHEZMOI_PERSONAL"`).
3. Asserts `chezmoi doctor` exits clean and key files exist
   (`~/.zshrc`, `~/.gitconfig`).

This catches regressions before you bring up a new machine and find
out the install script broke six months ago.
