# Dotbot foundation

This foundation mirrors the current repository shape: link the stable dotfiles directly and reuse the existing shell installers for packages and app-specific config.

## Try it

1. Install or vendor Dotbot.
2. Point `DOTBOT_BIN` at the real Dotbot entry point.
3. Run:

```bash
cd <dotfiles-repo>
DOTBOT_BIN=/path/to/dotbot ./.frameworks/dotbot/install.sh --dry-run
```

Apply for real with:

```bash
DOTBOT_BIN=/path/to/dotbot ./.frameworks/dotbot/install.sh
```

## dotbot-brew

`dotbot-brew` was evaluated but not adopted in this foundation yet. The current package surface spans Homebrew, cargo, npm, uv, and Linux apt checks, so `packages/sync.sh` remains the single integration point for now.

`dots sync` remains the fallback install path while this foundation is evaluated.
