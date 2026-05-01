# dotdrop foundation

This foundation keeps the current repository as the `dotpath`, then uses dotdrop profiles and actions to model the current sync flow.

## Profiles

- `base` — shared top-level dotfiles and shell modules
- `macos` — includes `base` and runs macOS-specific actions
- `linux-dev` — includes `base` and adds the `dev` package sync path

## Try it

```bash
cd <dotfiles-repo>
./.frameworks/dotdrop/install.sh files -p macos
./.frameworks/dotdrop/install.sh install -p macos -t
./.frameworks/dotdrop/install.sh compare -p macos
```

Swap `macos` for `linux-dev` to exercise the Linux/dev profile.

`dots sync` remains the fallback install path while this foundation is evaluated.
