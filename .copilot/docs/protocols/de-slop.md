# De-slop workflow

This is a human guide, not a Copilot skill.

## Use it for

- Cleaning up unsupported Copilot claims after AI-assisted edits
- Replacing vague wrappers with real repo commands

## Commands

- `git diff -- .copilot`
- `rg "dots lint|dots diff|dots lookup|dots de-slop|tilth plugin" .copilot`
- `shellcheck -x -e SC1091 .copilot/.sync`

## Prompt pattern

> Remove unsupported Copilot CLI claims from this draft. Keep only commands and surfaces we can verify in this repo.

## Review checklist

- Prefer `git diff`, `rg`, `shellcheck`, `copilot mcp list/get`, and `dots test` over invented wrappers.
- Treat `tilth` as a companion CLI, not a Copilot plugin.
- Reserve hooks, skills, and agents for real plugin source trees under `.copilot/plugins/`.
