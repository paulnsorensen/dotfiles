# bubbletea Architecture Reference

Patterns for production bubbletea/lipgloss apps. Use Context7 for API
specifics — this covers architecture, not API surface.

## The Elm pattern

bubbletea has no escape hatch from the Elm architecture — embrace it rather
than fighting it with mutable globals.

```go
type model struct {
    items    []string
    selected int
    width    int
    height   int
}

func (m model) Init() tea.Cmd {
    return nil // or an initial tea.Cmd, e.g. loadDataCmd()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.WindowSizeMsg:
        m.width, m.height = msg.Width, msg.Height
        return m, nil
    case tea.KeyMsg:
        switch msg.String() {
        case "q", "ctrl+c":
            return m, tea.Quit
        case "j", "down":
            m.selected = min(m.selected+1, len(m.items)-1)
        case "k", "up":
            m.selected = max(m.selected-1, 0)
        }
    }
    return m, nil
}

func (m model) View() string {
    return renderList(m.items, m.selected, m.width)
}
```

`Init` returns the first `tea.Cmd` (or nil). `Update` is a pure state
transition — never perform I/O inline; return a `tea.Cmd` (a `func() tea.Msg`)
for anything that blocks, and let bubbletea run it off the main loop. `View`
is pure read-only rendering — no mutation, no I/O.

## Commands for I/O

```go
func fetchCmd(url string) tea.Cmd {
    return func() tea.Msg {
        resp, err := http.Get(url)
        if err != nil {
            return errMsg{err}
        }
        return dataMsg{resp}
    }
}
```

Dispatch from `Update` (`return m, fetchCmd(url)`); the result arrives later
as a `tea.Msg` back into `Update`. Never call `fetchCmd` synchronously.

## tea.WindowSizeMsg

bubbletea sends `tea.WindowSizeMsg` on startup and every resize. Store
`width`/`height` in the model and recompute layout in `View` from those
fields — never assume a fixed terminal size.

## lipgloss styles

Centralize styles as a struct, keyed by semantic role, not scattered
`lipgloss.NewStyle()` calls at each render site:

```go
type Styles struct {
    Title    lipgloss.Style
    Selected lipgloss.Style
    Error    lipgloss.Style
}

func NewStyles() Styles {
    return Styles{
        Title: lipgloss.NewStyle().Bold(true).
            Foreground(lipgloss.AdaptiveColor{Light: "235", Dark: "252"}),
        Selected: lipgloss.NewStyle().Reverse(true),
        Error: lipgloss.NewStyle().
            Foreground(lipgloss.AdaptiveColor{Light: "#cc0000", Dark: "#ff6b6b"}),
    }
}
```

`AdaptiveColor` picks light/dark variants automatically — use it instead of a
hardcoded hex so the TUI survives both terminal backgrounds.

## Snapshot testing with teatest

```go
func TestInitialView(t *testing.T) {
    tm := teatest.NewTestModel(t, initialModel(), teatest.WithInitialTermSize(80, 24))
    teatest.WaitFor(t, tm.Output(), func(b []byte) bool {
        return bytes.Contains(b, []byte("Select an item"))
    })
    tm.Send(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("q")})
    tm.WaitFinished(t, teatest.WithFinalTimeout(time.Second))
}
```

`teatest.WithInitialTermSize` sets the terminal dimensions for the test run —
use it to cover 80x24, 120x40, and 40x15 the same way ratatui's `TestBackend`
and Textual's `Pilot` do.
