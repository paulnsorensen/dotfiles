# TUI design suite

Four skills and one profile cover terminal-UI work end to end: design, build, capture, and verify.

## Composition and routing

- `/tui-design` designs and builds app TUIs (Rust ratatui, Python Textual, Go bubbletea).
- `/tui-verify` runs the capture-and-inspect loop with agent-tty. Build mode fixes what it finds; audit mode reports findings without editing.
- `/tui-demo` produces VHS tapes for demos, regression frames, and palette-true evidence.
- `/term-theme` covers zsh prompt, tmux, base24 scheme, and contrast work.

The `tui` profile (`profiles/tui/profile.yaml`) is the isolated closed world that carries these four skills plus `de-slop` and `version-doctor`. It exists because none of the four skills needs the full default MCP surface, and an isolated profile keeps the terminal-focused loop free of unrelated tool noise.

## Decision: agent-tty for adaptive capture, VHS for scripted evidence

The suite uses two different capture tools for two different jobs, not one tool for both:

- **agent-tty** (`coder/agent-tty` 0.5.0, pinned in `packages/packages.yaml`) drives the adaptive loop in `/tui-verify`. It gives a persistent session, observable waits, resize, and both PNG and text snapshots — the primitives an agent needs to look, judge, and retry.
- **VHS** drives the scripted, reproducible captures in `/tui-demo`. A tape repeats a declared input sequence. VHS accepts an explicit terminal palette through `Set Theme`. This tests that palette, not the user's terminal configuration. Application data and startup state must also remain controlled.

## Gotchas found in the 2026-09-06 smoke trial

- `create -- <args>` treats everything after `--` as the command to run, not shell flags for the created session. A session created with `-- -il` exits immediately because `-il` is passed as the command.
- agent-tty bundles Playwright 1.60 and needs `chromium-headless-shell` build v1223. A bare `npx playwright install` fetches whatever build the ambient Playwright CLI resolves, which is a different build, and `agent-tty doctor` stays red. Install through the bundled CLI instead: `node "$(npm root -g)/agent-tty/node_modules/playwright/cli.js" install chromium-headless-shell`.
- agent-tty's render profiles are only `reference-dark` / `reference-light`, each with a fixed background/foreground pair. ANSI-256 colors paint in the renderer's own palette, not the terminal's configured scheme, so an agent-tty screenshot proves layout correctness, not palette correctness. VHS is the tool that proves palette.
- `run` returns no child exit status. A test invoked through `agent-tty run` cannot report pass/fail through its own exit code; run tests through the normal shell instead.
- `wait` takes a `--timeout <ms>` flag, and a screenshot response's artifact path is at the JSON key `result.artifactPath`.

## Upstream skills loaded at run time, not vendored

The `agent-tty` and `dogfood-tui` skills are not copied into this repo. `/tui-verify` fetches them at run time via `agent-tty skills get`, which keeps their content coupled to whichever agent-tty CLI version is actually installed, rather than drifting from a vendored snapshot.

## Evidence limit

Published workflows — Letta Code's capturing-tui-visual-proof and `coder/agent-tty`'s own dogfood loop — establish precedent for a capture-and-inspect loop as a verification technique. Neither measures whether the loop improves subjective design quality; that remains an open question. The 2026-09-06 smoke trial gives one data point in favor: the zsh prompt wrapped at 50 columns in the first screenshot, a concrete layout defect the loop caught that a type-check or unit test could not have.

## Recovery smoke trial

The recovery trial confirms capture operation, not complete application verification.
`agent-tty doctor --json` passes with CLI 0.5.0 and Node 24.18.1.
The Textual 8.2.8 built-in demo runs through `uv run --no-project --with textual python -m textual`.
Screenshots receive visual inspection at 80x24, 120x40, and 40x15.
The narrow footer clips key hints; the larger layout shows more content.
`Ctrl+p` opens the command palette at 40x15.
These observations concern the upstream demo, not changes to this repository.

A separate VHS tape renders an ANSI-red value with `Set Theme "Dracula"`.
The PNG receives visual inspection.
`Wait+Screen@10s` checks output; `Sleep 500ms` sets presentation duration after the check.
A tape that ends immediately after `Show` and `Screenshot` fails GIF generation with `no frames` in the recovery trial.
Parser validation alone does not detect this runtime failure.
The tape therefore needs visible recording duration after readiness, not a delay that substitutes for readiness.
A VHS theme proves the declared renderer palette, not a terminal emulator's live configuration.

Screen stability does not prove clean application exit.
The combined Escape/Ctrl+C trial leaves the palette visible in its snapshot.
The trial destroys the session explicitly and makes no terminal-restoration claim.
Future checks must observe a shell marker after exit instead of equating a stable screen with success.[^cleanup]

[^cleanup]: `agent-tty skills get dogfood-tui`, evidence checklist and alt-screen taxonomy; recovery runtime trial on 2026-09-06.

See also: [[agent-profile]], [[agents-dir]].

## Publication recovery

Update an old workspace before changing an unknown-key guard.
The permission-hook failure here comes from branch drift, not a new unregistered machine setting.
Main already supplies the hooks, their implementation, and tests in `8b8f3ff`.
Main also excludes generated OMP skill Markdown in `9eb9bcd`.
A fast-forward preserves these fixes without duplicating them or weakening the guard.
The added regression test checks that generated OMP skills are ignored while malformed canonical skill Markdown still fails.[^recovery]

See [tmux plugin gotchas](../operations/tmux-plugin-gotchas.md) for the tmux smoke trial and its capture limits.

[^recovery]: `8b8f3ff` (#878), `9eb9bcd` (#897), and `tests/just-check.bats:70-88`.
