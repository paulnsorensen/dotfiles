---
name: term-theme
model: sonnet
effort: medium
context: fork
allowed-tools: Read, Bash(mkdir:*), Bash(tmux:*), Bash(vhs:*), Bash(jq:*), Bash(yq:*), mcp__tilth__*
description: >
  Design and verify semantic terminal themes for zsh prompts, tmux status lines, and terminal palettes.
  Use when the user says "theme my prompt", "change tmux colors", "create a terminal theme", "fix contrast", or "make the shell theme accessible".
---

# term-theme

Design terminal chrome as one semantic palette. Cover the zsh prompt, tmux status line,
and terminal emulator when the request includes them. Use `/tui-design` for app widgets,
`/tui-verify` for app layout, and `/tui-demo` for palette-true VHS evidence.

## Discipline

**Iron Law:** No terminal theme is complete without semantic contrast checks on light and dark backgrounds.

**Red Flags** — stop if you notice these:

- A color name describes hue instead of meaning.
- Red and green carry different states without text or symbols.
- A screenshot proves layout but not the real palette.
- A theme changes generated targets instead of source files.

| Rationalization | Why it fails | Required action |
| --- | --- | --- |
| “The hex values look readable.” | Readability changes with terminal background and contrast. | Check both background modes. |
| “Color alone is enough.” | Color-vision deficiency and monochrome terminals hide meaning. | Add labels, symbols, or weight. |
| “I can edit the rendered config.” | The next sync overwrites that change. | Edit the source and deploy. |
| “tmux and zsh can use different names.” | Inconsistent semantics make state recognition unreliable. | Share semantic roles. |

## Workflow

1. Ground the repository theme architecture before changing source.
2. Locate source palette definitions and generated consumers with tilth.
3. Define semantic roles such as `surface`, `text`, `muted`, `accent`, `info`, `warning`, and `error`.
4. Map each role to zsh, tmux, and terminal settings without changing role meaning.
5. Pair every status color with text, symbols, or emphasis.
6. Check contrast on light and dark backgrounds, including `NO_COLOR` behavior where applicable.
7. Run the project theme tests and inspect a real tmux or VHS frame.
8. Report changed source paths, checks, and any residual contrast risk.

## Accessibility rules

Use blue and orange for success and warning when the palette permits.
Use magenta or a text prefix for errors instead of relying on red.
Keep focus visible with reverse video, underline, or a border change.
Preserve readable text at 16-color, 256-color, and truecolor tiers.
Respect `NO_COLOR` and `TERM=dumb` without hiding state labels.

## Source-of-truth rule

Edit the repository's declared palette source, such as `theme/config.yaml`, `theme/schemes/`, `zsh/`, or `tmux/`; never edit generated targets.
Run the relevant generator after source edits.
Use `chezmoi diff` before template changes and `dots sync` before handoff.

## Isolated tmux check

Use a unique socket and an empty config for checks so the user's tmux server stays unchanged.

```bash
TMUX_SOCKET="tui-theme-$RANDOM"
tmux -L "$TMUX_SOCKET" -f /dev/null new-session -d -s check
trap 'tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true' EXIT
tmux -L "$TMUX_SOCKET" set-option -t check status-keys vi
tmux -L "$TMUX_SOCKET" capture-pane -t check -p
# Pane capture excludes the tmux status line.
tmux -L "$TMUX_SOCKET" display-message -p '#{status-left} | #{status-right}'
```

Treat pane output as content evidence, not status-line evidence. Use `/tui-demo` with VHS for a status-line screenshot. Let the trap remove the isolated server.

## Example semantic map

| Role | Meaning | Fallback |
| --- | --- | --- |
| `surface` | panel or status background | terminal default |
| `text` | primary content | terminal default |
| `muted` | metadata or inactive content | dim attribute |
| `accent` | current focus or action | underline or reverse |
| `warning` | recoverable risk | `[WARN]` prefix |
| `error` | failed action | `[ERR]` prefix |

## Output contract

Report the semantic map, source files, contrast checks, fallback behavior, and test command.
Name any role that lacks a non-color fallback.
