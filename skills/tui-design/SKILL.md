---
name: tui-design
model: sonnet
effort: medium
context: fork
allowed-tools: Read, Bash(mkdir:*), mcp__tilth__*, mcp__context7__resolve-library-id, mcp__context7__query-docs
description: >
  Create distinctive, production-grade terminal UIs and full-screen interactive
  CLI tools in Rust (ratatui/crossterm), Python (Textual/Rich), or Go
  (bubbletea/lipgloss). Use when the user says "build a dashboard", "terminal
  UI", "interactive CLI", "TUI app", "system monitor", "log viewer", "file
  manager", or invokes /tui-design. Do NOT use to screenshot or verify an
  already-built TUI (/tui-verify), record a VHS demo or regression tape
  (/tui-demo), or theme the shell prompt/tmux/terminal palette (/term-theme).
---

# tui-design

Design and build professional TUIs. Character grids, not canvases.

## Discipline

**Iron Law:** No TUI is done until tests pass and `/tui-verify` inspects its rendered states.

**Red Flags** — stop if you notice these:

- The layout relies on a single terminal size.
- Colors carry state without text or symbols.
- The test asserts only that rendering does not crash.

| Rationalization | Why it fails | Required action |
| --- | --- | --- |
| “The layout is obvious.” | Character grids expose clipping and density defects only at runtime. | Define sizes and inspect screenshots. |
| “Tests can wait until the end.” | Untested state changes hide regressions during design. | Write the test with the feature. |
| “Color communicates the state.” | Users may lack color or use `NO_COLOR`. | Add a text or symbol fallback. |

## Workflow — Route to the Right Tool

- **Library docs** (ratatui, crossterm, Textual, Rich, bubbletea, lipgloss):
  Context7 MCP (`mcp__context7__resolve-library-id` + `query-docs`) FIRST.
  These libraries evolve fast — don't rely on training data for API specifics.
- **Code navigation** in the target repo: tilth (search/read/grok), not grep/find.
- **Commit and PR**: `/plate`.
- **Adversarial test hardening**: `/press`, after the build loop below.
- **Visual verification** (does it look right, screenshot it): `/tui-verify`.
- **Demo GIF, regression tape, palette-true frame**: `/tui-demo`.
- **Shell prompt, tmux status line, terminal color scheme**: `/term-theme`.

---

## Design Thinking

Before coding, commit to a clear interaction model:

- **Purpose**: What state is the user exploring? What actions do they need? What would they otherwise do with raw CLI commands?
- **Layout pattern**: Choose one: sidebar+main, header+content+statusbar, dashboard grid, multi-pane with tabs, or miller columns. Match the pattern to the data shape.
- **Information density**: Terminals reward density done well. Show the most important data at a glance — but never sacrifice scannability. Use alignment, box-drawing, and whitespace to create visual lanes.
- **Interaction model**: Keyboard-first with optional mouse. Vim-style navigation for lists/panels, emacs-style for text inputs. Every action discoverable via status bar hints and `?` help.
- **Language**: Rust (ratatui + crossterm) for performance-critical, long-running, or systems-level TUIs. Python (Textual) for rapid prototyping, data exploration tools, or when CSS-like styling accelerates development. Go (bubbletea + lipgloss) for single-binary CLI tools that need a light interactive layer.

**CRITICAL**: The terminal is not a web browser. You have a fixed character grid, no fonts, no subpixel rendering, limited color in some environments, and keybinding conflicts with terminal emulators and multiplexers. Design within these constraints — don't fight them.

Then implement working code that is:

- Fully functional with proper terminal lifecycle management (raw mode, alternate screen, panic/signal cleanup)
- Immediately usable without reading documentation (discoverable keybindings, status bar hints)
- Resilient across terminal environments (color fallback, resize handling, multiplexer compatibility)
- Visually polished with intentional use of borders, alignment, color, and Unicode

---

## TUI Aesthetics

- **Borders**: Single-line (`+-+||+-+`) for standard panels, double-line sparingly for emphasis/focus. Round corners for softer feel. Consistent style across the app. 1 char internal padding minimum.
- **Color**: Cohesive palette. Bright/warm for primary, dim/cool for secondary. Bold for emphasis, dim for metadata, reverse-video for selections. Default to CVD-safe status colors: blue=success/info, orange/amber=warning, magenta=error. Classic green/yellow/red may be offered as an alternate theme. Always pair color with symbol/text (checkmark/X/warning). Support light AND dark backgrounds. Respect `NO_COLOR`.
- **Hierarchy**: Top-left = most important context, bottom = status/keybindings, center = primary workspace. Right-align numbers, left-align text. Truncate with ellipsis, never wrap in tables.
- **Status bar**: Bottom 1-2 lines. Structure: `[MODE] | context | metadata | position | keybinding hints`. Temporary messages overwrite 3-5 seconds, then restore. Use the CVD-safe palette above — always with text prefix (`[OK]`, `[ERR]`, `[WARN]`).

NEVER hard-code colors assuming dark background. NEVER rely on color alone. NEVER mix border styles. NEVER skip the status bar.

---

## Keybinding Standards

Universal conventions — users expect them:

| Key | Action | Notes |
|-----|--------|-------|
| `q` / `Ctrl-C` | Quit | `q` normal exit, `Ctrl-C` interrupt |
| `?` / `F1` | Help overlay | All keybindings for current context |
| `/` | Search/filter | Open search input |
| `Enter` | Confirm/select/open | Primary action key |
| `Esc` | Cancel/back/close | Return to previous state |
| `j/k` AND `up/down` | Navigate up/down | Always support BOTH |
| `h/l` AND `left/right` | Navigate left/right | Collapse/expand in trees |
| `Tab` / `Shift-Tab` | Next/previous panel | |
| `Space` | Toggle/multi-select | |
| `gg` / `G` | Jump to top/bottom | |
| `Ctrl-D` / `Ctrl-U` | Half-page down/up | |
| `n/N` | Next/prev search result | After `/` search |

### Keys to AVOID

- `Ctrl-S` (freezes terminal), `Ctrl-Q` (XON), `Ctrl-Z` (SIGTSTP), `Ctrl-\` (SIGQUIT)
- `Ctrl-Shift-*` (reserved by terminal emulators)
- Alt/Option (unreliable on macOS without terminal config)
- `Ctrl-I` = Tab, `Ctrl-M` = Enter, `Ctrl-H` = Backspace, `Ctrl-[` = Escape (physical collisions)

Discoverability is non-negotiable: status bar hints (3-5 most important
context-sensitive keybindings, always visible) plus a `?` help overlay (full
reference for the current view). Prefer **prefix keys** (`gg`, `dd`) over
modifier chords for terminal compatibility. Test inside tmux.

For apps with prefix keys or more than 15 actions, add a which-key popup (show
available completions after a prefix key), a command palette (`:`/`Ctrl-P`),
and make keybindings user-configurable. Smaller apps don't need any of these.

---

## Confirmation and Safety

| Risk | Pattern | Example |
|------|---------|---------|
| Reversible | Undo instead of confirm | `Done. Press u to undo (10s)` |
| Low | Force-flag | `:q` vs `:q!` |
| Moderate | Inline y/N | `Delete config.yaml? [y/N]:` (capitalize safe default) |
| High | Modal dialog | Centered overlay with OK/Cancel |
| Catastrophic | Type-to-confirm | `Type "production-db" to confirm:` |

### Confirmation guidance

Overusing confirmations causes habituation. Users auto-accept prompts without reading them.

## PTY Management

Always restore terminal state on every exit path: normal exit, panic, signals—a
TUI that corrupts the terminal on crash will be immediately uninstalled.
`ratatui::init()`, Textual's `App.run()`, and bubbletea's `tea.NewProgram(...).Run()`
handle this automatically. Full PTY handoff (shelling out mid-session) needs a manual
sequence — code and the shell-out/suspend snippets are in `references/patterns.md`.

---

## Color and Terminal Compatibility

### Three tiers with graceful fallback

| Tier | Detection | Use |
|------|-----------|-----|
| Truecolor (24-bit) | `COLORTERM=truecolor` | Default for modern terminals |
| 256-color | `TERM` contains `-256color` | Older emulators |
| 16-color ANSI | Everything else | Maximum compatibility |

Disable all color when `NO_COLOR` is set.

### Accessibility

- ~8% of men have color vision deficiency. Use **blue + orange** instead of red + green.
- Every colored indicator must also have a symbol or text label.
- Guarantee >= 4.5:1 contrast ratio. Test on light AND dark backgrounds.

### Theme architecture

Every color choice must answer "what does this color **mean**?" If the answer is "it
looked nice," it's wrong. Centralize color decisions:

- **Rust**: `Theme` struct with semantic slots (`primary`, `surface`, `error`, `muted`), passed `&theme` to render functions, `Color::Reset` for terminal-adaptive fg/bg. See `references/ratatui.md`.
- **Textual**: `.tcss` semantic variables (`$surface`, `$primary`, `$accent`), one file per theme for runtime switching. See `references/textual.md`.
- **Go**: `Styles` struct of `lipgloss.Style` values keyed by semantic role, built from `lipgloss.AdaptiveColor{Light: ..., Dark: ...}`. See `references/bubbletea.md`.

Designing theme-swappable shell/terminal chrome (prompt, tmux, base24 scheme) is
`/term-theme`'s job, not this skill's — route there.

### Resize handling

Handle `SIGWINCH` by recalculating layouts and full redraw. Collapse sidebars below 80 cols, hide metadata below 60. Design for **80x24 minimum**, optimize for 120x40+.

---

## Anti-Patterns and Benchmarks

AI assistants produce predictable mistakes: monolithic render functions,
hardcoded dark-background colors, ignored terminal size, blocked event loops,
no state/view separation, missing panic cleanup, undiscoverable keybindings,
excessive comments, over-abstracted widget hierarchies. Full list with fixes,
plus production TUIs worth studying (lazygit, bottom, posting, harlequin,
gitui, glow), in `references/patterns.md`.

---

## Language Guidance

### Rust: ratatui + crossterm

Default stack for most TUI projects. **TEA** for simple apps (< 5 interactive
elements), **Component trait** for multi-panel apps. `StatefulWidget` for
scroll/selection state, `Constraint::Fill(1)` for flexible layouts. Async via
tokio + crossterm `EventStream` + mpsc. See `references/ratatui.md`. Use
Context7 for API lookups — the surface is large.

### Python: Textual

Default for rapid prototyping and data exploration TUIs. `compose()` + `yield`
widget trees, `Screen` push/pop, `reactive` + `watch_*`, `@work(exclusive=True)`
for async I/O. Message passing between widgets, never reach across the tree.
See `references/textual.md`. Use Context7 for API lookups.

### Go: bubbletea + lipgloss

Default for single-binary CLI tools that need a light interactive layer.
Strict Elm pattern: `Init() tea.Cmd`, `Update(tea.Msg) (tea.Model, tea.Cmd)`,
`View() string`. `lipgloss.Style` per semantic role, `AdaptiveColor` for
light/dark. See `references/bubbletea.md`. Use Context7 for API lookups.

---

## Testing

Generate tests alongside the implementation — unit and snapshot tests are in
scope here; adversarial/hardening tests are `/press`'s job. A search test that
passes on zero results proves nothing — seed fixture data that guarantees at
least one match, and assert the result set is non-empty. Rust `TestBackend` +
`insta`, Python `Pilot` + `pytest-textual-snapshot`, Go `teatest` — concrete
examples in `references/patterns.md` and the per-language reference files.

Every TUI must be verified against: resize (80x24, 120x40, 40x15), `NO_COLOR=1`,
tmux compatibility, rapid input (100+ queued keystrokes), SIGINT mid-render.

---

## CLI vs TUI Decision

**Build a TUI when**: exploring unknown state, multiple data views needed simultaneously, user would chain CLI commands, real-time monitoring adds value.

**Build a CLI when**: output needs piping, runs in CI/automation, single command-to-result.

**Best practice**: Build the CLI core first, add TUI as interactive layer. Show what CLI commands the TUI executes — lazygit's command log is beloved for this.

## Done means

Implementation is not complete until `/tui-verify` has run against the built app
and every finding at blocker/major severity is fixed:

1. Unit/snapshot tests above pass.
2. `/tui-verify` in `build` mode has captured the state matrix (main view, help,
   search-with-results, empty, error, one destructive-confirm) at 80x24, 120x40,
   and 40x15, and every screenshot was opened and inspected.
3. No blocker or major finding remains open; residual minor/nit findings are named
   in the handoff.

## What You Don't Do

- Architecture review — use /xray for design verification
- Adversarial/hardening tests — use /press
- Screenshot capture and visual scoring — use /tui-verify
- VHS demo/regression tapes — use /tui-demo
- Shell prompt / tmux / terminal palette theming — use /term-theme
- Build web UIs — use /frontend-design for browser-based interfaces

## Gotchas

- Tends to generate monolithic render functions — split into composable widgets early
- Forgets `NO_COLOR` / `TERM=dumb` handling — always test with color disabled
- Skips resize event handling — terminal resize without handler causes layout corruption
- Ratatui's `Frame` lifetime constraints trip up async code — keep render logic synchronous
