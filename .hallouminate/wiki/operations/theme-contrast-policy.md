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
and Zed from the scheme. The following surfaces hand-mirror palette hexes and
must be updated together with any palette change:

- `theme/cursor/chocolate-donut-color-theme.json` (Cursor, frozen pending migration)
- `chezmoi/dot_omp/private_agent/themes/chocolate-donut.json` (OMP)
- `chezmoi/dot_pi/private_agent/themes/chocolate-donut.json` (Pi)
- `chezmoi/private_dot_gitconfig.tmpl` (delta + git 256-color section; recompute
  nearest xterm-256 indexes when hexes move — e.g. dim 241→246 at `939393`)
- `tests/theme-palette.bats` (exact-color assertions)

## Brownfield activation (2026-10-11)

The active scheme keeps the `brownfield-warm` identifier and uses the user’s exact Brownfield base24 palette.[^1]
The scheme metadata names Brownfield as both name and author.
Zed selects Brownfield for dark mode. Its light-mode selection remains unchanged.[^2]

The final user-provided palette supersedes both the initial solve and the earlier rose-cocoa selection.
Its background is `#211a16` and foreground is `#e6dcd6`.
Do not rerun the solver or adjust the chosen colors.
Measured minimum text contrast is 5.036, 4.762, and 4.522 on base00, base01, and base02.
These values exceed the repository floors.
The palette’s CVD provenance is not established.
Keep existing OMP, Pi, and delta identifiers where callers depend on them; their palette values follow the active scheme.[^3]

[^1]: theme/config.yaml:1; theme/schemes/brownfield-warm.yaml
[^2]: chezmoi/dot_config/zed/settings.json.tmpl:17-21
[^3]: chezmoi/dot_omp/private_agent/themes/chocolate-donut.json; chezmoi/private_dot_gitconfig.tmpl:93-116
