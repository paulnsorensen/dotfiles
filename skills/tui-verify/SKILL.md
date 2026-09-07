---
name: tui-verify
model: sonnet
effort: medium
context: fork
allowed-tools: Read, Bash(agent-tty:*), Bash(node:*), Bash(npm:*), Bash(jq:*), Bash(mktemp:*), Bash(mkdir:*), Bash(cp:*)
description: >
  Capture and inspect screenshots of a terminal UI with agent-tty to verify
  layout, wrapping, focus, hierarchy, and key hints. Use when the user asks
  "does it look right", "screenshot the TUI", "verify the TUI", "review this
  TUI", "audit this terminal app", or invokes /tui-verify. Do NOT use to
  build/implement a TUI (/tui-design), record a VHS demo/regression tape or
  check palette fidelity (/tui-demo), or verify shell prompt/tmux theming
  (/term-theme).
---

# tui-verify

The capture-and-inspect loop for terminal UIs, built on `agent-tty`.
agent-tty screenshots are valid for layout, wrapping, clipping, focus, and
hierarchy — NOT for palette fidelity (its renderer only supports
`reference-dark`/`reference-light`, not the user's real terminal theme). For
palette-true frames, route to `/tui-demo`.

## Discipline

**Iron Law:** No verification report exists without opened screenshots and recorded findings.

**Red Flags** — stop if you notice these:

- A capture was not opened.
- A blind `sleep` replaces an observable wait.
- Audit mode edits application code.

| Rationalization | Why it fails | Required action |
| --- | --- | --- |
| “The PNG exists, so it passed.” | File presence says nothing about layout quality. | Open the PNG and record findings. |
| “Sleep is simpler.” | Fixed delays race with slow or fast apps. | Wait for screen state. |
| “This audit needs a quick fix.” | Audit output must remain independent evidence. | Report the defect and use build mode. |

Two modes:

- **build** (default): verify the app you just built or changed, fix app issues,
  and recapture. Use after `/tui-design`.
- **audit**: review an existing TUI and emit a severity report without edits.

## Step 0 — Load agent-tty and check prerequisites

```bash
agent-tty skills get agent-tty
agent-tty skills get dogfood-tui
```

These fetch the upstream skill texts at run time — they are not vendored here.
Then check the environment:

```bash
agent-tty --home "$(mktemp -d)" doctor --json
```

If the browser check fails:

```bash
node "$(npm root -g)/agent-tty/node_modules/playwright/cli.js" install chromium-headless-shell
```

A bare `npx playwright install` installs the wrong playwright version —
agent-tty bundles its own.

## Step 1 — Pick reproducible test data

Use a seeded fixture, an env var, or a `--demo` flag so every capture shows
the same content run to run. Screenshots of nondeterministic data cannot be
compared across rounds.

## Step 2 — Build the state matrix

States × sizes, all six states at all three sizes unless the app documents a
minimum width above 40 columns:

| State | 80x24 | 120x40 | 40x15 |
|---|---|---|---|
| Main view | required | required | required unless documented minimum > 40 |
| Help overlay | required | required | " |
| Search/filter with results | required | required | " |
| Empty state | required | required | " |
| Error state | required | required | " |
| One destructive-confirm | required | required | " |

Drive each cell with `batch` (input + `wait` steps) — never a blind `sleep`.
See `references/agent-tty-cookbook.md` for the exact command shapes.

## Step 3 — Capture

Per cell: `snapshot --format text --json` (searchable text) and
`screenshot --json` (PNG). Copy PNGs to
`.cheese/tui-verify/<slug>/<state>-<cols>x<rows>.png`.

## Step 4 — Inspect

Open EACH PNG with the Read tool — a capture without inspection is not
verification. Score it against `references/critique-rubric.md`. Record every
finding as `state, size, axis, what you see, expected, severity
(blocker/major/minor/nit)`.

## Step 5 — Act on findings

- **build mode**: fix, recapture only the affected cells, re-inspect. Loop up
  to 3 rounds, then report any residual findings instead of looping forever.
- **audit mode**: write the report only; do not edit the app.

## Step 6 — Interaction checks screenshots cannot show

- Rapid input: `type` 100 chars, confirm no dropped input.
- `Ctrl+C` mid-session, then inspect the snapshot and terminal prompt to confirm
  alt-screen cleanup; screen stability alone is not proof.
- `NO_COLOR=1` launch shows text indicators, not just color.
- Resize mid-session redraws correctly.

## Step 7 — Clean up

`destroy` the session. Note artifact paths in the report. Recordings may
contain secrets — keep the agent-tty home under `mktemp -d` and do not commit
PNGs unless the user asks.

## What text snapshots cannot prove

- Wide-glyph/CJK alignment — trust source and layout tests over
  `snapshot --format text`; corroborate with a screenshot, not the reverse.
- Palette fidelity — agent-tty's renderer profiles are bg+fg only; route
  palette questions to `/term-theme` + `/tui-demo`'s VHS `Set Theme`.

## Report template

Use the upstream dogfood-tui report structure (title, environment,
reproduction steps, evidence bundle, expected/actual behavior, impact,
workaround, regression suspicion) plus a rubric findings table:

```
| State | Size | Axis | Observed | Expected | Severity |
```

## Scope boundary

Audit mode does not edit application logic. Build mode may fix application findings.
Use /tui-design for new TUI implementation.

- Record GIF/MP4 demos or CI regression tapes — use /tui-demo
- Verify the shell prompt, tmux, or terminal color scheme — use /term-theme
