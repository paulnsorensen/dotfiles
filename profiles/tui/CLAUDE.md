# TUI Profile

A closed-world terminal-UI session: build ratatui/Textual/bubbletea apps, and shape zsh/tmux/theme chrome, with a visual feedback loop.

## Why this profile exists

Terminal apps and shell chrome have no DOM to query. Type-check and unit tests do not prove "it looks right." This profile adds a capture-and-inspect loop so a session can see its own terminal output before claiming done.

## MCPs in scope

Defined in `profile.yaml` (closed world — `--strict-mcp-config`):

- **context7** — `mcp__context7__*` — ratatui, Textual, bubbletea, and other lib docs.
- **tilth** — `mcp__tilth__*` — AST-aware search/read/edit.
- **tavily** — `mcp__tavily__*` — pattern research ("how do people lay out a ratatui dashboard?").
- **hallouminate** — `mcp__hallouminate__*` — repo-wiki grounding; check for TUI/theme conventions before writing.

## Skills in scope

- **`/tui-design`** — design and build app TUIs: Rust (ratatui), Python (Textual), Go (bubbletea).
- **`/tui-verify`** — capture-and-inspect loop with agent-tty; build mode fixes defects, audit mode reports them.
- **`/tui-demo`** — VHS tapes for demos, regression frames, and palette-true evidence.
- **`/term-theme`** — zsh prompt, tmux, base24 scheme, and contrast work.

## Working standards

- Read before you write. Check existing components and conventions before adding new ones.
- Make the smallest change that satisfies the ask.
- Use Context7 before writing ratatui, Textual, or bubbletea API calls — the API surface moves fast.
- Never use a blind `sleep` to wait for terminal output. Wait on observable state (`wait --timeout`, a rendered frame, an exit code).
- Open every screenshot with Read and cite concrete findings. Do not describe a screenshot you did not open.
- `agent-tty run` returns no child exit status. Run tests through the normal shell, not through `agent-tty run`.

## Defaults

- After any TUI change, run `/tui-verify` before claiming done.
- After any prompt/tmux/scheme change, run `/term-theme`'s verify loop.
- Test at three sizes: 80x24, 120x40, 40x15.
- Run once with `NO_COLOR=1` to catch color-only signaling.
- Put verification artifacts under `.cheese/tui-verify/`. Do not commit them unless asked.
- Create agent-tty homes under `mktemp`. Destroy them at the end of the session.
- Recordings may hold secrets visible on screen. Treat them as sensitive until reviewed.

## Verify-before-done checklist

- [ ] Screenshot opened and inspected at each tested size
- [ ] Layout holds at 80x24, 120x40, and 40x15
- [ ] `NO_COLOR=1` run checked for color-only signaling
- [ ] No blind `sleep`; waits are on observable state
- [ ] Verification artifacts land under `.cheese/tui-verify/`, not committed unless asked
- [ ] agent-tty home cleaned up at session end
