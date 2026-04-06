---
name: tui-design
model: sonnet
context: fork
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(mkdir:*), mcp__context7__resolve-library-id, mcp__context7__query-docs
description: >
  Create distinctive, production-grade terminal user interfaces with high usability
  and professional polish. Use this skill when the user asks to build TUI applications,
  terminal dashboards, interactive CLI tools, or any full-screen terminal interface
  (system monitors, git clients, database explorers, log viewers, file managers, REPL
  wrappers). Supports Rust (ratatui/crossterm) and Python (Textual/Rich).
  Use when the user says "build a dashboard", "terminal UI", "interactive CLI",
  "TUI app", "system monitor", "log viewer", or invokes /tui-design.
---

# tui-design

Design and build professional TUIs. Character grids, not canvases.

## Workflow — Use Existing Skills

Delegate to the right skill for each phase of TUI development:

| Phase | Skill | Why |
|-------|-------|-----|
| Search codebase for patterns | `scout` | rg/fd for fast file and content search |
| Understand existing code structure | LSP | Symbol lookup, cross-references, type info |
| Look up ratatui/Textual/crossterm docs | `fetch` | Context7 for version-specific library docs |
| Find structural code patterns | `trace` | ast-grep for "what implements X?" questions |
| Edit existing files precisely | `chisel` | sd for multi-file replacements, Edit for precision |
| Pre-commit smoke test | `diff` | Catch secrets, debug statements, silent failures |
| Stage and commit | `commit` | Conventional commits, no force-push |
| GitHub operations (PR, push) | `gh` | gh CLI for all GitHub ops |

**Use `fetch` with Context7 FIRST** when working with ratatui, crossterm, Textual, Rich, or
cursive APIs. These libraries evolve fast — don't rely on training data for API specifics.

---

## Design Thinking

Before coding, commit to a clear interaction model:

- **Purpose**: What state is the user exploring? What actions do they need? What would they otherwise do with raw CLI commands?
- **Layout pattern**: Choose one: sidebar+main, header+content+statusbar, dashboard grid, multi-pane with tabs, or miller columns. Match the pattern to the data shape.
- **Information density**: Terminals reward density done well. Show the most important data at a glance — but never sacrifice scannability. Use alignment, box-drawing, and whitespace to create visual lanes.
- **Interaction model**: Keyboard-first with optional mouse. Vim-style navigation for lists/panels, emacs-style for text inputs. Every action discoverable via status bar hints and `?` help.
- **Language**: Rust (ratatui + crossterm) for performance-critical, long-running, or systems-level TUIs. Python (Textual) for rapid prototyping, data exploration tools, or when CSS-like styling accelerates development.

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

### Discoverability is non-negotiable

1. **Status bar hints**: 3-5 most important context-sensitive keybindings, always visible
2. **`?` help overlay**: Full keybinding reference for the current view
3. **Which-key popups**: After a prefix key, show available completions
4. **Command palette** (optional): `:` or `Ctrl-P` for searchable actions in complex apps

Use **prefix keys** (`gg`, `dd`) instead of modifier chords for maximum terminal compatibility. Make all keybindings user-configurable. Test inside tmux.

---

## Confirmation and Safety

| Risk | Pattern | Example |
|------|---------|---------|
| Reversible | Undo instead of confirm | `Done. Press u to undo (10s)` |
| Low | Force-flag | `:q` vs `:q!` |
| Moderate | Inline y/N | `Delete config.yaml? [y/N]:` (capitalize safe default) |
| High | Modal dialog | Centered overlay with OK/Cancel |
| Catastrophic | Type-to-confirm | `Type "production-db" to confirm:` |

**Overusing confirmations causes habituation** — users auto-click "yes", defeating the purpose.

---

## PTY Management

### Full PTY handoff (shelling out) — in this order

1. Leave alternate screen, 2. Disable mouse capture, 3. Disable raw mode, 4. Show cursor
2. Spawn child with inherited stdin/stdout/stderr, 6. waitpid()
3. Re-enable raw mode, 8. Re-enable mouse capture, 9. Re-enter alternate screen, 10. Full redraw

**Rust (ratatui + crossterm):**

Note: `ratatui::init()` handles startup/cleanup and panic hooks automatically. The
manual crossterm calls below are only needed for PTY handoff (shelling out mid-session):

```rust
fn shell_out<B: Backend>(terminal: &mut Terminal<B>, cmd: &str, args: &[&str]) -> io::Result<ExitStatus> {
    crossterm::execute!(io::stdout(), LeaveAlternateScreen, DisableMouseCapture)?;
    crossterm::terminal::disable_raw_mode()?;
    crossterm::execute!(io::stdout(), crossterm::cursor::Show)?;

    let result = std::process::Command::new(cmd).args(args).status();

    crossterm::terminal::enable_raw_mode()?;
    crossterm::execute!(io::stdout(), EnterAlternateScreen, EnableMouseCapture)?;
    terminal.clear()?;
    result
}
```

**Python (Textual):**

```python
with self.app.suspend():
    os.system("vim file.txt")  # Terminal fully restored during this block
```

### Terminal state safety — THE CARDINAL RULE

**Always restore terminal state on every exit path: normal exit, panic, signals.**

- Rust (ratatui >= v0.29): `ratatui::init()` handles panic hooks automatically
- Python (Textual): `App.run()` lifecycle handles cleanup
- A TUI that corrupts the terminal on crash will be immediately uninstalled

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

- **Rust**: Define a `Theme` struct with semantic slots (`primary`, `surface`, `error`, `muted`). Pass `&theme` to render functions. Use `Color::Reset` for terminal-adaptive fg/bg. See `references/ratatui.md`.
- **Textual**: Use `.tcss` semantic variables (`$surface`, `$primary`, `$accent`). One `.tcss` file per theme for runtime switching. See `references/textual.md`.

### Resize handling

Handle `SIGWINCH` by recalculating layouts and full redraw. Collapse sidebars below 80 cols, hide metadata below 60. Design for **80x24 minimum**, optimize for 120x40+.

---

## Rendering Performance

- **Double-buffered diff rendering**: ratatui and Textual do this automatically
- **Synchronized Output** (`CSI ? 2026 h` / `l`): like VSync for terminals
- **BufWriter** for all terminal I/O
- **Virtual-scroll** large datasets (render only visible rows)
- Cap render rate at 30-60 FPS; 10-30 FPS sufficient for most UIs

---

## TUI Anti-Patterns

AI assistants produce these predictable mistakes in TUI code. Check every one before
presenting output. These are the TUI-specific equivalents of the `de-slop` patterns.

### 1. Monolithic render function

A 100+ line `ui()` / `render()` with nested layout math and inline styling.
**Fix:** Delegate to per-panel render functions. Each panel is one function, < 40 lines.

### 2. Hardcoded colors assuming dark background

`Color::White` on `Color::Black`, or `fg="white"` in Textual — invisible on light terminals.
**Fix:** Use `Color::Reset` (Rust) or `$surface`/`$text` (Textual). Define a `Theme`, never scatter RGB at use sites.

### 3. Ignoring terminal size

Renders sidebar at any width, truncates to garbage below 60 cols.
**Fix:** Check `area.width` and collapse panels responsively. Test at 40, 80, and 200 cols.

### 4. Blocking the event loop

Network fetch or file I/O inline in the render loop — drops frames, freezes UI.
**Fix:** Background task via `tokio::spawn` + mpsc (Rust) or `@work` (Textual). Main loop only does recv + draw.

### 5. No state/view separation

Business logic inside the render closure. Mutations during draw.
**Fix:** TEA split — `App` struct owns state, `handle_event` mutates, `render` is pure read-only.

### 6. Missing panic cleanup

Manual `enable_raw_mode()` without panic hook — crash leaves terminal trashed.
**Fix:** Use `ratatui::init()` (installs panic hook automatically). Textual's `App.run()` handles this.

### 7. Undiscoverable keybindings

Actions wired to keys but never shown in status bar or `?` help.
**Fix:** Central keybinding table that feeds BOTH the action handler AND the help display.

### 8. Excessive comments

`// Create the layout`, `// Handle quit key`, `// Render the list` — narrating every line.
**Fix:** Delete comments that restate code. TUI code is visual — the structure speaks for itself.

### 9. Over-abstracted widget hierarchies

`WidgetFactory`, `RenderManager`, `LayoutBuilder` for a 3-panel app.
**Fix:** Functions, not abstractions. Extract a trait only when 3+ components genuinely share behavior.

---

## Real-World Benchmarks

Study these production TUIs for patterns worth stealing:

- **lazygit**: Command log panel showing exact git commands — builds user trust and teaches
- **bottom (btm)**: Widget trait per panel, mpsc channels for async data, extensive snapshot test suite
- **posting**: Textual Screen-per-view pattern, Worker for HTTP, CommandPalette integration
- **harlequin**: Reactive DataTable, multiple `.tcss` theme files, runtime theme switching
- **gitui**: Clean TEA pattern, async git notifications, per-tab Component trait

The bar is: would your code look at home in these codebases?

---

## Language Guidance

### Rust: ratatui + crossterm

- Default stack for most TUI projects. Bootstrap: `ratatui::init()` / `ratatui::restore()`.
- Architecture: **TEA** for simple apps (< 5 interactive elements), **Component trait** for multi-panel apps. See `references/ratatui.md` for concrete skeletons.
- Key patterns: `StatefulWidget` for scroll/selection state, `Constraint::Fill(1)` for flexible layouts, `Layout::vertical/horizontal` builder style.
- Async: tokio + crossterm `EventStream` + mpsc channels. Never block the render loop.
- Theme: define a `Theme` struct with semantic color slots — pass `&theme` to every render function.
- Use `fetch` skill with Context7 for ratatui API lookups — the API surface is large.

### Python: Textual

- Default for rapid prototyping and data exploration TUIs.
- Architecture: `compose()` + `yield` widget trees, `Screen` push/pop for navigation, `reactive` attributes with `watch_*` callbacks, `Worker` with `@work(exclusive=True)` for async I/O. See `references/textual.md` for patterns.
- Theming: `.tcss` files with semantic variables (`$surface`, `$primary`, `$accent`). Multiple `.tcss` files for runtime theme switching.
- `CommandPalette` for apps with many actions (Ctrl-P searchable commands).
- Message passing for widget communication — never reach across the widget tree.
- Use `fetch` skill with Context7 for Textual API lookups.

---

## Testing

Generate tests alongside the implementation — a TUI without tests is incomplete.

### Rust: snapshot + event + resize

```rust
#[test]
fn renders_main_view() {
    let backend = TestBackend::new(80, 24);
    let mut terminal = Terminal::new(backend).unwrap();
    let app = App::with_test_data();
    terminal.draw(|f| app.render(f)).unwrap();
    insta::assert_snapshot!(terminal.backend().to_string());
}

#[test]
fn narrow_terminal_hides_sidebar() {
    let backend = TestBackend::new(40, 24);
    // ... render and assert sidebar content absent
}

#[test]
fn quit_key_exits() {
    let mut app = App::new();
    app.handle_event(key_event('q')).unwrap();
    assert!(!app.running);
}
```

### Python: Pilot + snapshot

```python
async def test_search_filters(snap_compare):
    app = MyApp()
    async with app.run_test() as pilot:
        await pilot.press("slash")
        await pilot.type("query")
        await pilot.press("enter")
        await pilot.pause()
        results = app.query(ResultItem)
        assert all("query" in r.label.plain for r in results)

async def test_main_view(snap_compare):
    assert await snap_compare("myapp/app.py", terminal_size=(80, 24))
```

### Integration checklist

Every TUI must be verified against these scenarios:

- **Resize**: 80x24, 120x40, 40x15 — layout adapts, no panics, no overflow
- **NO_COLOR=1**: text-only indicators still present, no ANSI escapes
- **tmux**: keybindings work, no conflicts, mouse events pass through
- **Rapid input**: 100+ keystrokes queued — no event loss or stale renders
- **SIGINT mid-render**: terminal restored cleanly

See `references/ratatui.md` and `references/textual.md` for full test examples.

---

## CLI vs TUI Decision

**Build a TUI when**: exploring unknown state, multiple data views needed simultaneously, user would chain CLI commands, real-time monitoring adds value.

**Build a CLI when**: output needs piping, runs in CI/automation, single command-to-result.

**Best practice**: Build the CLI core first, add TUI as interactive layer. Show what CLI commands the TUI executes — lazygit's command log is beloved for this.

## What You Don't Do

- Architecture review — use /xray for design verification
- Write tests — use /wreck for adversarial testing
- Build web UIs — use /frontend-design for browser-based interfaces

## Gotchas

- Tends to generate monolithic render functions — split into composable widgets early
- Forgets `NO_COLOR` / `TERM=dumb` handling — always test with color disabled
- Skips resize event handling — terminal resize without handler causes layout corruption
- Ratatui's `Frame` lifetime constraints trip up async code — keep render logic synchronous
