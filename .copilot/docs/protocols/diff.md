# Diff workflow

This is a human guide, not a Copilot skill.

## Use it for

- Reviewing staged or unstaged changes
- Checking whether a Copilot suggestion changed the right files

## Commands

- `git diff --stat`
- `git diff -- .copilot`
- `git diff --cached`

## Prompt pattern

> Review this diff for risky shell or Copilot config changes. Ignore style unless it could break sync or tooling.

## Verify

- Re-run `git diff`
- If `.sync` changed, run `shellcheck -x -e SC1091 .copilot/.sync`
- If the change may affect repo behavior, run `dots test`
