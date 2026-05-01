# Chezmoi foundation

This source state keeps the current repository layout intact while letting Chezmoi manage the top-level entry points.

## Managed files

- `~/.zshrc`
- `~/.gitconfig`
- `~/.gitattributes`
- `~/.vimrc`

## Mapped scripts

- `run_once_before_10-packages.sh.tmpl` → `packages/sync.sh`
- `run_once_after_20-custom-sync.sh.tmpl` → existing per-directory `.sync` installers

## Try it

```bash
cd <dotfiles-repo>
chezmoi --source "$PWD/.frameworks/chezmoi/source-state" diff
chezmoi --source "$PWD/.frameworks/chezmoi/source-state" apply --dry-run
```

Apply for real with:

```bash
chezmoi --source "$PWD/.frameworks/chezmoi/source-state" apply
```

`dots sync` remains the fallback install path while this foundation is evaluated.
