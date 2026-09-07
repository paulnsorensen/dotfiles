---
name: tui-demo
model: sonnet
effort: medium
context: fork
allowed-tools: Read, Bash(vhs:*), Bash(mkdir:*), Bash(mktemp:*), Bash(cp:*)
description: >
  Record deterministic terminal-UI demos and palette-true regression evidence with VHS.
  Use when the user says "record a TUI demo", "make a terminal GIF", "create a VHS tape", "capture a regression frame", or "check terminal colors".
---

# tui-demo

Record terminal applications with VHS. Use this skill for presentation frames, GIFs,
regression tapes, and palette-true captures. Use `/tui-verify` for layout inspection
with agent-tty and `/term-theme` for shell or tmux theme work.

## Discipline

**Iron Law:** No demo artifact exists without a deterministic tape and an inspected output.

**Red Flags** — stop if you notice these:

- The tape relies on the current shell prompt or current directory.
- A blind `Sleep` hides a race.
- The output exists, but nobody opened it.
- A color claim uses an agent-tty screenshot.

| Rationalization | Why it fails | Required action |
| --- | --- | --- |
| “The demo only runs once.” | A one-shot artifact cannot detect regressions. | Seed inputs and record the tape. |
| “Sleep is harmless in a recording.” | Timing races create flaky frames. | Use VHS `Wait` or a visible prompt. |
| “The GIF looks fine from its filename.” | File presence does not prove visual quality. | Open every requested output. |
| “The terminal theme is close enough.” | Palette drift changes the product appearance. | Set the palette in the tape and inspect it. |

## Workflow

1. Check that `vhs` exists and create a temporary output directory.
2. Write a tape with a fixed working directory, command, dimensions, palette, and inputs.
3. Use `Set Theme` for palette-true output and `Wait` for observable application states.
4. Render with `vhs`; generate only the requested GIF, PNG, or text artifact.
5. Open each output with `Read` and record concrete findings.
6. Keep sensitive recordings out of git and remove temporary files after review.

## Tape requirements

Use `Output` paths under `.cheese/tui-demo/<slug>/` for requested artifacts.
Use a fixed `Set Width` and `Set Height` for repeatable frames.
Use `Hide` and `Show` to remove setup commands from presentation output.
Use `Type`, `Enter`, and `Wait` for reproducible interactions.
Use `Ctrl+c` or type `exit` followed by `Enter` to restore the shell after each tape.

Canonical example: `examples/status.tape`.

Use `Wait+Screen@<duration> /<pattern>/` for observable output.
Use `Screenshot <path>` when a palette-true PNG is required.

## Output contract

Report the tape path, output paths, dimensions, theme, command, and inspected findings.
State whether the artifact is for regression, review, or presentation.
Do not claim palette fidelity unless the tape sets a theme and the output was opened.
