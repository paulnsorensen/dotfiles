# dotfiles

Welcome to my dotfiles.

I stole a lot of this from this guy --> [natebosch/dotfiles](https://github.com/natebosch/dotfiles)

And I made my own theme, but I'm pretty sure I ripped that off too:
<img width="697" alt="Screen Shot 2022-07-22 at 10 07 35 AM" src="https://user-images.githubusercontent.com/429793/180489758-d177dee9-3639-46f5-90e9-1a7692322ea8.png">

## Current sync path

The default install path is still `dots sync`, backed by `/home/runner/work/dotfiles/dotfiles/.sync-with-rollback` with the legacy `/home/runner/work/dotfiles/dotfiles/.sync` kept as a fallback.

## Framework comparison foundations

Comparison foundations now live under `/home/runner/work/dotfiles/dotfiles/.frameworks/`:

- `chezmoi/` — preferred long-term candidate for templating, multi-machine setup, and secrets
- `dotbot/` — minimal-migration candidate that mirrors the current link + shell flow
- `dotdrop/` — profile-oriented candidate for macOS/Linux split installs and action-driven setup

See `/home/runner/work/dotfiles/dotfiles/.frameworks/README.md` for commands and tradeoffs.
