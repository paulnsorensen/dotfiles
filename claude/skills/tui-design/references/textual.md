# Textual Architecture Reference

Patterns for production Textual apps. Use `fetch` with Context7 for API specifics —
this covers architecture, not API surface.

## App Skeleton

```python
from textual.app import App, ComposeResult
from textual.widgets import Header, Footer, Static

class MyApp(App):
    CSS_PATH = "app.tcss"
    BINDINGS = [
        ("q", "quit", "Quit"),
        ("?", "help", "Help"),
        ("slash", "search", "Search"),
    ]

    def compose(self) -> ComposeResult:
        yield Header()
        yield MainContent()
        yield Footer()
```

Always use `compose()` + `yield` to declare the widget tree. Never construct widgets
imperatively in `on_mount`.

## Reactive Attributes

The core state management pattern. Changes cascade automatically:

```python
class Dashboard(Widget):
    selected_id: reactive[int | None] = reactive(None)
    filter_text: reactive[str] = reactive("")

    def watch_selected_id(self, value: int | None) -> None:
        """Called automatically when selected_id changes."""
        if value is not None:
            self.query_one(DetailPanel).load(value)

    def watch_filter_text(self, value: str) -> None:
        self.query_one(ItemList).filter(value)
```

Use `reactive` instead of manually updating multiple widgets when state changes.
The `watch_*` methods fire automatically — no event wiring needed.

## Workers for Async Operations

Never block the event loop. Use `@work` for I/O:

```python
from textual.worker import work

class ApiExplorer(Screen):
    @work(exclusive=True)  # Cancels previous run on re-invoke
    async def fetch_endpoint(self, url: str) -> None:
        self.query_one(StatusBar).update("Loading...")
        response = await self.app.http.get(url)
        self.response_data = response.json()
        self.query_one(StatusBar).update("Done")
```

`exclusive=True` means only one instance of this worker runs at a time — the previous
is cancelled. Use this for search-as-you-type, API calls, file loading.

## Screen Navigation

For multi-view apps, use Screens instead of hiding/showing widgets:

```python
class CollectionScreen(Screen):
    """Browse saved items."""

    def compose(self) -> ComposeResult:
        yield ItemList()
        yield Footer()

    def on_item_list_selected(self, event: ItemList.Selected) -> None:
        self.app.push_screen(DetailScreen(event.item_id))


class DetailScreen(Screen):
    """View/edit a single item."""

    BINDINGS = [("escape", "pop_screen", "Back")]

    def __init__(self, item_id: int) -> None:
        super().__init__()
        self.item_id = item_id
```

`push_screen` overlays; `switch_screen` replaces. `pop_screen` returns to previous.

## CommandPalette

For apps with many actions, add searchable command discovery:

```python
from textual.command import Provider, Hit

class EndpointProvider(Provider):
    async def search(self, query: str) -> Hit:
        for endpoint in self.app.endpoints:
            if query.lower() in endpoint.path.lower():
                yield Hit(
                    score=1,
                    match_display=endpoint.path,
                    command=lambda e=endpoint: self.app.open_endpoint(e),
                )

class MyApp(App):
    COMMANDS = {EndpointProvider}  # Ctrl-P opens palette
```

## CSS Theming

Semantic variables make themes swappable:

```css
/* app.tcss */
Screen {
    background: $surface;
}

#sidebar {
    width: 25;
    border-right: solid $primary;
    background: $surface-darken-1;
}

#sidebar:focus-within {
    border-right: solid $accent;
}

ItemRow {
    height: 3;
    padding: 0 1;
}

ItemRow.-selected {
    background: $primary 20%;  /* Alpha tinting */
    color: $text;
}

ItemRow.-error {
    color: $error;
}
```

Textual provides `$surface`, `$primary`, `$secondary`, `$accent`, `$error`,
`$warning`, `$success`, `$text`, `$text-muted` out of the box.

### Runtime Theme Switching

```python
class MyApp(App):
    CSS_PATH = "themes/dark.tcss"
    THEMES = {"dark": "themes/dark.tcss", "light": "themes/light.tcss"}

    def action_toggle_theme(self) -> None:
        current = "dark" if "dark" in str(self.CSS_PATH) else "light"
        new_theme = "light" if current == "dark" else "dark"
        self.CSS_PATH = self.THEMES[new_theme]
```

## Message Passing

Widgets communicate up via messages, not by reaching into siblings:

```python
class SearchBox(Input):
    class Changed(Message):
        def __init__(self, query: str) -> None:
            super().__init__()
            self.query = query

    def on_input_changed(self, event: Input.Changed) -> None:
        self.post_message(self.Changed(event.value))

# Parent handles the message
class MainScreen(Screen):
    def on_search_box_changed(self, event: SearchBox.Changed) -> None:
        self.query_one(ResultsList).filter(event.query)
```

Never reach across the widget tree (`self.app.query_one(SiblingWidget).do_thing()`).
Post a message and let the parent coordinate.

## Testing with Pilot

```python
import pytest
from myapp import MyApp

@pytest.mark.asyncio
async def test_search_filters_results():
    app = MyApp()
    async with app.run_test() as pilot:
        await pilot.press("slash")       # Open search
        await pilot.type("foo")          # Type query
        await pilot.press("enter")       # Confirm
        await pilot.pause()              # Wait for workers

        results = app.query(ResultItem)
        assert all("foo" in r.label.plain for r in results)

@pytest.mark.asyncio
async def test_detail_screen_navigation():
    app = MyApp()
    async with app.run_test() as pilot:
        await pilot.press("enter")       # Open detail
        assert isinstance(app.screen, DetailScreen)
        await pilot.press("escape")      # Back
        assert isinstance(app.screen, MainScreen)
```

### Snapshot Testing

```python
# Uses pytest-textual-snapshot
async def test_main_view(snap_compare):
    assert await snap_compare("myapp/app.py")

async def test_narrow_view(snap_compare):
    assert await snap_compare("myapp/app.py", terminal_size=(40, 24))
```

Install: `uv pip install pytest-textual-snapshot`
