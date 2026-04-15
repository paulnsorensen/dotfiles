# Lint workflow

This is a human guide, not a Copilot skill.

## Use it for

- Shell script validation
- Quick doc and config sanity checks before a commit

## Commands

- `shellcheck -x -e SC1091 .copilot/.sync`
- `markdownlint-cli2 '.copilot/**/*.md'`
- `copilot mcp list --config-dir .copilot`

## Prompt pattern

> Here are the lint findings from `.copilot`. Fix only the real issues and keep the docs concise.

## Verify

- Re-run the failing lint command
- Use `dots test` when the change might affect repo-wide behavior
