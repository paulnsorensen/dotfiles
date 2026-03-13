# Ratatui Architecture Reference

Patterns for production ratatui apps. Use `fetch` with Context7 for API specifics —
this covers architecture, not API surface.

## Bootstrap (v0.29+)

```rust
fn main() -> Result<()> {
    let mut terminal = ratatui::init(); // Panic hook + raw mode + alt screen
    let result = App::new().run(&mut terminal);
    ratatui::restore(); // Cleanup on normal exit
    result
}
```

`ratatui::init()` replaces manual `enable_raw_mode` + `execute!(EnterAlternateScreen)`.
It installs a panic hook that restores the terminal on crash. Always use it unless you
need custom panic behavior.

## TEA Pattern (simple apps)

For single-view apps with < 5 interactive elements. One struct, three concerns.

```rust
struct App {
    items: Vec<Item>,
    selected: usize,
    running: bool,
}

impl App {
    fn run(&mut self, terminal: &mut DefaultTerminal) -> Result<()> {
        while self.running {
            terminal.draw(|f| self.render(f))?;
            self.handle_event(event::read()?)?;
        }
        Ok(())
    }

    fn handle_event(&mut self, event: Event) -> Result<()> {
        if let Event::Key(key) = event {
            match key.code {
                KeyCode::Char('q') => self.running = false,
                KeyCode::Char('j') | KeyCode::Down => self.next(),
                KeyCode::Char('k') | KeyCode::Up => self.prev(),
                _ => {}
            }
        }
        Ok(())
    }

    fn render(&self, frame: &mut Frame) {
        let [header, body, footer] = Layout::vertical([
            Constraint::Length(1),
            Constraint::Fill(1), // Takes remaining space
            Constraint::Length(1),
        ]).areas(frame.area());

        render_header(frame, header);
        render_list(frame, body, &self.items, self.selected);
        render_status(frame, footer);
    }
}
```

## Component Pattern (complex apps)

For multi-panel apps where each panel manages its own state and events.

```rust
enum Action {
    Quit,
    FocusNext,
    Tick,
    DataLoaded(Vec<Record>),
}

trait Component {
    fn handle_event(&mut self, event: &Event) -> Option<Action>;
    fn render(&self, frame: &mut Frame, area: Rect);
    fn update(&mut self, action: &Action) {}
}
```

Each panel implements `Component`. The app struct holds a `Vec<Box<dyn Component>>`
and a focus index. Events route to the focused component; actions propagate to all.

## StatefulWidget

For widgets with scroll/selection state that persists across frames:

```rust
struct SelectableList {
    items: Vec<String>,
}

impl StatefulWidget for SelectableList {
    type State = ListState;

    fn render(self, area: Rect, buf: &mut Buffer, state: &mut Self::State) {
        // Render with state.selected() for highlight position
    }
}

// In render function:
frame.render_stateful_widget(list_widget, area, &mut app.list_state);
```

Use `StatefulWidget` instead of manually threading scroll position through function args.

## Layout Patterns

```rust
// Vertical split with flexible middle
let [header, body, footer] = Layout::vertical([
    Constraint::Length(3),
    Constraint::Fill(1),   // Fill remaining space
    Constraint::Length(1),
]).areas(area);

// Horizontal split — responsive
if area.width >= 80 {
    let [sidebar, main] = Layout::horizontal([
        Constraint::Length(20),
        Constraint::Fill(1),
    ]).areas(body);
    render_sidebar(frame, sidebar, app);
    render_main(frame, main, app);
} else {
    render_main(frame, body, app); // Sidebar hidden on narrow terminals
}
```

`Constraint::Fill(n)` distributes remaining space proportionally. Use it instead of
`Constraint::Percentage` or `Constraint::Min` when you want flexible layouts.

## Theme Struct

Never scatter `Color::Rgb(...)` across render functions. Define a theme:

```rust
struct Theme {
    primary: Color,
    secondary: Color,
    surface: Color,
    error: Color,
    warning: Color,
    success: Color,
    muted: Color,
}

impl Theme {
    fn default_dark() -> Self {
        Self {
            primary: Color::Cyan,
            secondary: Color::Blue,
            surface: Color::Reset,  // Let terminal decide
            error: Color::Magenta,  // CVD-safe, not red
            warning: Color::Yellow,
            success: Color::Blue,   // CVD-safe, not green
            muted: Color::DarkGray,
        }
    }
}
```

Pass `&theme` to every render function. This makes color decisions centralized and
swappable. Use `Color::Reset` for default foreground/background — it adapts to the
user's terminal theme (light or dark).

## Async Event Handling

For apps that fetch data in the background:

```rust
enum Event {
    Key(KeyEvent),
    Resize(u16, u16),
    Tick,
    DataReady(Vec<Record>),
}

fn spawn_event_handler(tx: mpsc::Sender<Event>) {
    tokio::spawn(async move {
        let mut reader = EventStream::new();
        let mut tick = tokio::time::interval(Duration::from_millis(250));
        loop {
            let event = tokio::select! {
                Some(Ok(evt)) = reader.next() => evt.into(),
                _ = tick.tick() => Event::Tick,
            };
            if tx.send(event).await.is_err() {
                break; // Receiver dropped, app is shutting down
            }
        }
    });
}
```

Data-fetching tasks send results through the same channel:

```rust
tokio::spawn(async move {
    let data = fetch_from_api().await;
    let _ = tx.send(Event::DataReady(data)).await;
});
```

The main loop only does `rx.recv()` + `terminal.draw()`. Never block the render loop.

## Snapshot Testing

```rust
#[cfg(test)]
mod tests {
    use ratatui::{backend::TestBackend, Terminal};

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
        let mut terminal = Terminal::new(backend).unwrap();
        let app = App::with_test_data();

        terminal.draw(|f| app.render(f)).unwrap();

        let output = terminal.backend().to_string();
        assert!(!output.contains("SIDEBAR"));
    }

    #[test]
    fn quit_key_exits() {
        let mut app = App::new();
        app.handle_event(Event::Key(KeyEvent::new(
            KeyCode::Char('q'), KeyModifiers::NONE,
        ))).unwrap();
        assert!(!app.running);
    }
}
```

Always test at multiple terminal sizes. Use `insta` for snapshot regression.
