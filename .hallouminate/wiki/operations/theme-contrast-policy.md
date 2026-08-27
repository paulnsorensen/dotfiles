# Theme contrast policy and palette mirror surfaces

## Contrast policy (2026-08-26)

Every text role in `theme/schemes/*.yaml` must meet WCAG AA against the
scheme's dark surfaces: **≥4.5:1 on base00 and base01, ≥3:1 on base02**
(selection keeps the foreground while the background lightens). Verify with
relative-luminance math (WCAG formula), not by eye; when a role fails, apply
the minimal HLS lightness bump that clears all three bars, preserving hue.

Applied to Chocolate Donut: base03 `636363→939393`, base08/base0F
`e8575b→eb6b6f`, base0D `768da1→8196a8`. Trade-off accepted: comments
(base03) now sit near base04's lightness — the comment/dim-fg distinction
rests on hue (neutral vs warm), not brightness.

## Palette mirror surfaces (gotcha)

`theme/generate.sh` renders zsh, vimrc, iterm2, bin/colors, tmux, ghostty,
and Zed from the scheme — but four surfaces hand-mirror palette hexes and
must be updated together with any palette change:

- `theme/cursor/chocolate-donut-color-theme.json` (Cursor, frozen pending migration)
- `chezmoi/dot_omp/private_agent/themes/chocolate-donut.json` (OMP)
- `chezmoi/private_dot_gitconfig.tmpl` (delta + git 256-color section; recompute
  nearest xterm-256 indexes when hexes move — e.g. dim 241→246 at `939393`)
- `tests/theme-palette.bats` (exact-color assertions)

Zed's checked-in dark default is the generated "Chocolate Donut"
(`chezmoi/dot_config/zed/settings.json.tmpl`), superseding the earlier
Modus-default decision: the live machine had been switched to Chocolate Donut
in Zed's UI, and a Modus template default would revert that on every apply.
