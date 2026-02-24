---
name: tui-design
model: sonnet
fork: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(mkdir:*), mcp__context7__resolve-library-id, mcp__context7__query-docs
description: >
  Create distinctive, production-grade terminal user interfaces with high usability
  and professional polish. Use this skill when the user asks to build TUI applications,
  terminal dashboards, interactive CLI tools, or any full-screen terminal interface
  (system monitors, git clients, database explorers, log viewers, file managers, REPL
  wrappers). Supports Rust (ratatui/crossterm) and Python (Textual/Rich).
---

# tui-design

Design and build professional TUIs. Character grids, not canvases.

## Workflow — Use Existing Skills

Delegate to the right skill for each phase of TUI development:

| Phase | Skill | Why |
|-------|-------|-----|
| Search codebase for patterns | `scout` | rg/fd for fast file and content search |
| Understand existing code structure | `serena` | Symbol lookup, cross-references, AST navigation |
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

### Keys to AVOID:
- `Ctrl-S` (freezes terminal), `Ctrl-Q` (XON), `Ctrl-Z` (SIGTSTP), `Ctrl-\` (SIGQUIT)
- `Ctrl-Shift-*` (reserved by terminal emulators)
- Alt/Option (unreliable on macOS without terminal config)
- `Ctrl-I` = Tab, `Ctrl-M` = Enter, `Ctrl-H` = Backspace, `Ctrl-[` = Escape (physical collisions)

### Discoverability is non-negotiable:
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

### Full PTY handoff (shelling out) — in this order:
1. Leave alternate screen, 2. Disable mouse capture, 3. Disable raw mode, 4. Show cursor
5. Spawn child with inherited stdin/stdout/stderr, 6. waitpid()
7. Re-enable raw mode, 8. Re-enable mouse capture, 9. Re-enter alternate screen, 10. Full redraw

**Rust (ratatui + crossterm):**
```rust
fn shell_out<B: Backend>(terminal: &mut Terminal<B>, cmd: &str, args: &[&str]) -> io::Result<ExitStatus> {
    // Suspend TUI (steps 1-4)
    crossterm::execute!(io::stdout(), LeaveAlternateScreen, DisableMouseCapture)?;
    crossterm::terminal::disable_raw_mode()?;
    crossterm::execute!(io::stdout(), crossterm::cursor::Show)?;

    // Run child (steps 5-6)
    let result = std::process::Command::new(cmd).args(args).status();

    // Always restore TUI (steps 7-10), even if child failed
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

### Terminal state safety — THE CARDINAL RULE:
**Always restore terminal state on every exit path: normal exit, panic, signals.**
- Rust (ratatui >= v0.30): `ratatui::init()` handles panic hooks automatically
- Python (Textual): `App.run()` lifecycle handles cleanup
- A TUI that corrupts the terminal on crash will be immediately uninstalled

---

## Color and Terminal Compatibility

### Three tiers with graceful fallback:
| Tier | Detection | Use |
|------|-----------|-----|
| Truecolor (24-bit) | `COLORTERM=truecolor` | Default for modern terminals |
| 256-color | `TERM` contains `-256color` | Older emulators |
| 16-color ANSI | Everything else | Maximum compatibility |

Disable all color when `NO_COLOR` is set.

### Accessibility:
- ~8% of men have color vision deficiency. Use **blue + orange** instead of red + green.
- Every colored indicator must also have a symbol or text label.
- Guarantee >= 4.5:1 contrast ratio. Test on light AND dark backgrounds.

### Resize handling:
Handle `SIGWINCH` by recalculating layouts and full redraw. Collapse sidebars below 80 cols, hide metadata below 60. Design for **80x24 minimum**, optimize for 120x40+.

---

## Rendering Performance

- **Double-buffered diff rendering**: ratatui and Textual do this automatically
- **Synchronized Output** (`CSI ? 2026 h` / `l`): like VSync for terminals
- **BufWriter** for all terminal I/O
- **Virtual-scroll** large datasets (render only visible rows)
- Cap render rate at 30-60 FPS; 10-30 FPS sufficient for most UIs

---

## Language Guidance

### Rust: ratatui + crossterm
- Default stack for most TUI projects. Use `cargo generate ratatui/templates async` to bootstrap.
- Architecture: **Elm (TEA)** for simple apps (Model + Update + View), **Component** pattern for large apps (each component owns state + events + render).
- Async: tokio + crossterm `event-stream` + mpsc channels for background I/O.
- Use `fetch` skill with Context7 for ratatui API lookups — the API surface is large.

### Python: Textual
- Default for rapid prototyping and data exploration TUIs.
- Key concepts: DOM widget tree + CSS selectors, Screens for push/pop views, reactive attributes, `.tcss` stylesheets, Workers for background tasks.
- Use `app.suspend()` for PTY handoff (see PTY Management section).
- Use `fetch` skill with Context7 for Textual API lookups.

---

## Testing

- **Rust**: ratatui `TestBackend` + `insta` crate for snapshot testing. Fix terminal dimensions in tests.
- **Python**: Textual `Pilot` for async integration tests + `pytest-textual-snapshot` for SVG regression.
- Always test: resize behavior, `NO_COLOR` mode, keybindings inside tmux.

---

## CLI vs TUI Decision

**Build a TUI when**: exploring unknown state, multiple data views needed simultaneously, user would chain CLI commands, real-time monitoring adds value.

**Build a CLI when**: output needs piping, runs in CI/automation, single command-to-result.

**Best practice**: Build the CLI core first, add TUI as interactive layer. Show what CLI commands the TUI executes — lazygit's command log is beloved for this.
