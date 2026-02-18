# Tmux Upgrade Plans for Dotfiles

## Current State

### What exists today
- Hand-rolled `tmux.conf` (~109 lines) with vi-mode, `C-a` prefix, sensible defaults
- Chocolate Donut base24 color scheme with `theme/generate.sh` pipeline targeting: zsh, vim, iTerm2, bin/colors
- fzf + fd + ripgrep already installed via brew
- `trl` alias for tmux config reload
- No TPM (tmux plugin manager)
- No status bar theme
- No session persistence
- No workspace automation

### Current tmux.conf features
- Prefix: `C-a` (unbound `C-b`)
- Base index 1, renumber windows
- Mouse on, escape-time 0, history 50k
- True color support (`tmux-256color`)
- Splits: `|` and `-` (in current directory)
- Vim-style pane nav: `h/j/k/l`
- Pane resize: `H/J/K/L` (repeatable)
- Vi copy mode: `v` to select, `y` to yank
- Quiet (no bells/activity)
- `prefix + r` reload
- `prefix + ?` cheatsheet popup

### Theme pipeline (`theme/generate.sh`)
- Source of truth: `theme/schemes/chocolate-donut.yaml` (base24 format)
- Generates: `zsh/colors.zsh`, vimrc highlights, iTerm2 plist, `bin/colors` swatch
- Uses `__SDW_*` variable naming convention
- Includes hex-to-256 color conversion
- Includes FZF color string generation

---

## Plan 1: "The Minimal Spice" — Plugin Stack on Existing Config

**Philosophy:** Keep hand-rolled config. Bolt on essential plugins via TPM.

### Changes
- Install TPM (3 lines in tmux.conf)
- Add tmux-resurrect + tmux-continuum (session persistence, auto-save every 15 min)
- Add vim-tmux-navigator (seamless Ctrl+hjkl between vim splits and tmux panes)
- Add tmux-yank (clipboard integration: pbcopy on macOS, xclip on Linux)
- Extend theme pipeline to generate tmux status bar colors from Chocolate Donut

### Status bar
Hand-written using `__SDW_*` color variables. Simple custom powerline-style bar matching zsh prompt.

### Effort: ~1 hour

### Pros
- You understand every line of config
- Theme is 100% Chocolate Donut, generated from YAML
- Minimal dependencies
- YAGNI compliant

### Cons
- No fancy status bar modules (battery, CPU, etc.)
- You maintain everything yourself
- No session/workspace automation

---

## Plan 2: "The Catppuccin Citadel" — Modern Theme Plugin + Full Plugin Stack

**Philosophy:** Use Catppuccin for tmux as status bar framework plus full plugin stack.

### Changes
- TPM + all plugins from Plan 1
- catppuccin/tmux (~2,800 stars) — modular status bar widgets
- tmux-thumbs — Rust hint-based copying (URLs, paths, hashes)
- tmux-sessionx — fzf session picker with preview + zoxide
- tmux-floax — floating popup panes
- tmux-nerd-font-window-name — auto window icons by process

### Status bar
Catppuccin's modular system: session name, window tabs, git branch, directory, hostname, date/time. Configurable left/right segments.

### Theme trade-off
Catppuccin has its own palette (Mocha, Macchiato, Frappe, Latte). Does NOT match Chocolate Donut. Two color worlds: zsh/vim in Chocolate Donut, tmux bar in Catppuccin.

### Effort: ~2 hours

### Pros
- Gorgeous out-of-the-box status bar with battery, CPU, session modules
- Massive community, actively maintained
- tmux-thumbs is life-changing for copying
- tmux-sessionx makes session management delightful

### Cons
- Color mismatch with Chocolate Donut
- 7-8 plugins to manage
- Catppuccin config can be overwhelming
- Don't own the status bar logic

---

## Plan 3: "The Chocolate Foundry" — Custom Generated Theme + Full Plugin Stack ⭐ RECOMMENDED

**Philosophy:** Extend `theme/generate.sh` to produce tmux status bar config. Your colors, powered by plugins.

### Changes
- TPM + plugin stack (resurrect, continuum, vim-tmux-navigator, yank, thumbs, sessionx)
- New target in `theme/generate.sh`: `generate_tmux_theme()` outputs `tmux/theme.conf`
- tmux.conf sources the generated theme file
- Status bar built with tmux native format strings using Chocolate Donut hex colors
- Powerline separators matching zsh prompt style

### Status bar modules (hand-crafted)
- Left: session name, window tabs with powerline separators
- Right: git branch (via script), directory, date/time
- Colors from base24 palette: base0D for blue segment, base0B for green, etc.
- Consistent powerline glyphs (`\uE0B0`) matching zsh prompt

### generate.sh addition would:
1. Read same `chocolate-donut.yaml` scheme
2. Emit tmux `set -g status-style`, `set -g window-status-*` using hex colors
3. Build powerline separators with `#[fg=...,bg=...]`
4. Output to `tmux/theme.conf` sourced by `tmux.conf`

### Effort: ~3-4 hours

### Pros
- Perfect color consistency across zsh + tmux + vim + iTerm2
- Extends existing architecture naturally
- Change scheme → `dots sync` → everything updates including tmux
- You own it, you understand it, YAGNI-compliant

### Cons
- More code to write/maintain in generate.sh
- No community-maintained widgets (battery, CPU)
- Status bar scripts for git branch etc. need writing

---

## Plan 4: "Oh-My-Tmux" — gpakosz/.tmux Framework

**Philosophy:** Let oh-my-tmux handle everything. Trade control for immediate beauty.

### Changes
- Clone gpakosz/.tmux to ~/.tmux
- Symlink .tmux.conf from repo (replaces hand-rolled config)
- Customize .tmux.conf.local (copied, not symlinked)

### Oh-my-tmux provides
- Two-file architecture: .tmux.conf (framework) + .tmux.conf.local (customizations)
- Built-in status bar: `#{battery_bar}`, `#{hostname_ssh}`, `#{loadavg}`, `#{pairing}`, `#{synchronized}`
- Vim-style keybindings, C-a secondary prefix, `-` and `_` for splits
- TPM support built-in
- Clipboard auto-detection (pbcopy, xclip, xsel, wl-copy)

### Color customization via .tmux.conf.local
```
tmux_conf_theme_colour_1="#2a1c12"    # base00
tmux_conf_theme_colour_2="#3c291c"    # base01
tmux_conf_theme_colour_3="#636363"    # base03
tmux_conf_theme_colour_4="#768da1"    # base0D
```

### Theme trade-off
CAN set 17 color variables to approximate Chocolate Donut, but it's manual (not generated). Status bar layout constrained to their variable system.

### Effort: ~1h install, ~2h customize

### Pros
- Beautiful immediately (30 seconds to gorgeous)
- SSH-aware hostname (hard to implement correctly)
- Battery, uptime, pairing mode built-in
- Active maintenance (24k+ stars)

### Cons
- Lose hand-rolled config entirely
- 800+ lines of framework you can't easily debug
- Customization limited to variable API (`#!important` for overrides)
- Changes n/p window navigation (muscle memory disruption)
- Colors manual, not generated from pipeline
- Breaks "understand every line" philosophy

---

## Plan 5: "The War Rig" — Maximum Power Configuration

**Philosophy:** All-in. Custom theme + full plugins + workspace automation + advanced features.

### Layer 1: Core (from Plan 3)
- TPM, resurrect, continuum, vim-tmux-navigator, yank
- Generated Chocolate Donut tmux theme

### Layer 2: Power Plugins
- tmux-thumbs — hint-based text grabbing (URLs, paths, git hashes, IPs)
- tmux-sessionx — fzf + zoxide session switcher
- tmux-floax — floating popup panes
- tmux-nerd-font-window-name — auto window icons
- extrakto — extract text from pane output via fzf

### Layer 3: Workspace Automation
- smug (Go, single binary, `brew install smug`) or tmuxinator (Ruby)
- YAML workspace definitions in dotfiles:
  ```yaml
  # tmux/workspaces/webapp.yaml
  session: webapp
  windows:
    - name: editor
      commands: [vim]
    - name: server
      commands: [npm run dev]
    - name: tests
      layout: even-horizontal
      panes:
        - npm test -- --watch
        - # empty shell
  ```
- Shell aliases: `mux webapp` to launch

### Layer 4: Advanced Tmux Features
- Popup windows: `prefix + g` opens lazygit in floating popup
  ```
  bind g display-popup -E -w 80% -h 80% "lazygit"
  ```
- Popup session switcher: `prefix + f` opens fzf picker in popup
- Conditional config: `if-shell` for macOS vs Linux
- tmux hooks: `after-new-session` for auto-naming, layout setup
- Custom status bar scripts: git branch, directory, k8s context

### Layer 5: Theme Pipeline Extension
- `generate_tmux_theme()` in generate.sh
- `generate_tmux_popup_theme()` for floating pane borders
- `generate_lazygit_theme()` bonus
- All colors from one YAML file

### Effort: ~6-8 hours across multiple sessions

### Pros
- Maximum power, maximum consistency
- Everything flows from Chocolate Donut
- Workspace automation saves 2-5 min per project per day
- Floating popups for lazygit/fzf are transformative
- Session persistence means never lose state
- Hints + extraction make copying effortless

### Cons
- Lots of moving parts
- ~8 TPM plugins to keep updated
- Workspace YAML files need maintaining per project
- Some plugins may conflict
- Potentially exceeds YAGNI

---

## Comparison Matrix

| Dimension | Plan 1 Minimal | Plan 2 Catppuccin | Plan 3 Chocolate ⭐ | Plan 4 Oh-My-Tmux | Plan 5 War Rig |
|---|---|---|---|---|---|
| Color consistency | Perfect | Mixed | Perfect | Manual | Perfect |
| Setup time | 1h | 2h | 3-4h | 1-2h | 6-8h |
| Maintenance | Low | Medium | Medium | Low | High |
| Understanding | Full | Partial | Full | Low | Full |
| Beauty | Simple | Gorgeous | Custom gorgeous | Gorgeous | Custom gorgeous |
| Session persistence | Yes | Yes | Yes | Via plugin | Yes |
| Workspace automation | No | No | No | No | Yes |
| Plugin count | 4 | 8 | 6 | Framework+plugins | 8+ |
| YAGNI compliance | High | Medium | High | Medium | Low |
| Wow factor | Low | High | Medium-High | High | Maximum |

---

## Plugin Reference

### Essential (all plans)
| Plugin | Stars | Purpose |
|--------|-------|---------|
| TPM (tmux-plugins/tpm) | ~12k | Plugin manager |
| tmux-resurrect | ~12.4k | Save/restore sessions across restarts |
| tmux-continuum | ~3.8k | Auto-save every 15 min, auto-restore on start |
| vim-tmux-navigator | ~5k | Seamless Ctrl+hjkl between vim and tmux |
| tmux-yank | ~3k | Clipboard integration (macOS/Linux/WSL/Wayland) |

### Power (Plans 2, 3, 5)
| Plugin | Stars | Purpose |
|--------|-------|---------|
| tmux-thumbs | ~1k | Hint-based text copying (Rust) |
| tmux-sessionx | ~1.2k | fzf session manager with preview + zoxide |
| tmux-floax | ~500 | Floating popup panes |
| tmux-nerd-font-window-name | ~800 | Auto icon naming for windows |
| extrakto | ~900 | Text extraction from panes via fzf |

### Theme options
| Theme | Stars | Notes |
|-------|-------|-------|
| catppuccin/tmux | ~2.8k | Most popular modern theme, modular widgets |
| dracula/tmux | ~700 | Dark theme with status modules |
| nord-tmux | ~1k | Arctic color palette |
| tmux-power | ~500 | Powerline-style with single accent color |
| base16 (tinted-theming) | varies | Base16/24 compatible — could match Chocolate Donut |

### Workspace managers
| Tool | Language | Install | Notes |
|------|----------|---------|-------|
| tmuxinator | Ruby | `gem install tmuxinator` | Most popular, mature |
| tmuxp | Python | `pip install tmuxp` | Python ecosystem, JSON+YAML |
| smug | Go | `brew install smug` | Single binary, lightweight |

---

## Recommendation

**Plan 3 ("The Chocolate Foundry")** is the sweet spot:
1. Extends existing `theme/generate.sh` architecture
2. Maintains perfect color consistency
3. YAGNI-compliant
4. You understand every line
5. Naturally grows toward Plan 5 later

Start with Plan 3, then cherry-pick from Plan 5 (tmux-thumbs and lazygit popup are highest-ROI bolt-ons).
