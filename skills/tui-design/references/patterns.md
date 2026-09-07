# TUI Patterns Reference

PTY handoff code, testing snippets, anti-patterns, and benchmarks extracted
from `SKILL.md` to keep the top-level file scannable.

## Full PTY handoff (shelling out mid-session)

Order: 1) leave alternate screen, 2) disable mouse capture, 3) disable raw
mode, 4) show cursor, 5) spawn child with inherited stdio, 6) waitpid, 7)
re-enable raw mode, 8) re-enable mouse capture, 9) re-enter alternate screen,
10) full redraw.

**Rust (ratatui + crossterm)** — `ratatui::init()` handles startup/cleanup and
panic hooks automatically; the manual calls below are only for PTY handoff:

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

**Python (Textual)**:

```python
with self.app.suspend():
    os.system("vim file.txt")  # Terminal fully restored during this block
```

## Rendering performance

- Double-buffered diff rendering: ratatui, Textual, and bubbletea do this automatically.
- Synchronized Output (`CSI ? 2026 h` / `l`): like VSync for terminals.
- `BufWriter` for all terminal I/O.
- Virtual-scroll large datasets (render only visible rows).
- Cap render rate at 30-60 FPS; 10-30 FPS is sufficient for most UIs.

## TUI anti-patterns

AI assistants produce these predictable mistakes in TUI code. Check every one
before presenting output.

1. **Monolithic render function** — a 100+ line `ui()`/`render()` with nested
   layout math and inline styling. Fix: delegate to per-panel render
   functions, each < 40 lines.
2. **Hardcoded colors assuming dark background** — `Color::White` on
   `Color::Black`, or `fg="white"` in Textual. Fix: `Color::Reset` (Rust) or
   `$surface`/`$text` (Textual); define a `Theme`, never scatter RGB at use sites.
3. **Ignoring terminal size** — renders sidebar at any width, truncates to
   garbage below 60 cols. Fix: check `area.width`, collapse panels
   responsively, test at 40/80/200 cols.
4. **Blocking the event loop** — network fetch or file I/O inline in the
   render loop. Fix: background task via `tokio::spawn` + mpsc (Rust),
   `@work` (Textual), or a `tea.Cmd` (Go); main loop only does recv + draw.
5. **No state/view separation** — business logic inside the render closure.
   Fix: TEA split — state struct owns state, `handle_event` mutates, `render`
   is pure read-only.
6. **Missing panic cleanup** — manual `enable_raw_mode()` without a panic
   hook. Fix: `ratatui::init()` installs the hook automatically; Textual's
   `App.run()` and bubbletea's `Run()` handle this too.
7. **Undiscoverable keybindings** — actions wired to keys but never shown in
   the status bar or `?` help. Fix: one keybinding table feeds both the
   action handler and the help display.
8. **Excessive comments** — `// Create the layout`, `// Handle quit key`.
   Fix: delete comments that restate code.
9. **Over-abstracted widget hierarchies** — `WidgetFactory`, `RenderManager`,
   `LayoutBuilder` for a 3-panel app. Fix: functions, not abstractions;
   extract a trait only when 3+ components genuinely share behavior.

## Real-world benchmarks

Study these production TUIs for patterns worth stealing:

- **lazygit** — command log panel showing exact git commands; builds user trust and teaches.
- **bottom (btm)** — widget trait per panel, mpsc channels for async data, extensive snapshot test suite.
- **posting** — Textual Screen-per-view pattern, Worker for HTTP, CommandPalette integration.
- **harlequin** — reactive DataTable, multiple `.tcss` theme files, runtime theme switching.
- **gitui** — clean TEA pattern, async git notifications, per-tab Component trait.
- **glow / gh dash** — bubbletea + lipgloss, minimal Elm-style Update/View split.

The bar: would your code look at home in these codebases?

## Testing snippets

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
        assert results, "search must return a non-empty filtered set for this fixture"
        assert all("query" in r.label.plain for r in results)

async def test_main_view(snap_compare):
    assert await snap_compare("myapp/app.py", terminal_size=(80, 24))
```

### Go: teatest

```go
func TestQuitKey(t *testing.T) {
    tm := teatest.NewTestModel(t, initialModel())
    tm.Send(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("q")})
    tm.WaitFinished(t, teatest.WithFinalTimeout(time.Second))
}
```
