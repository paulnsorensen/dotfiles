# Lookup workflow

This is a human guide, not a Copilot skill.

## Use it for

- Finding repo strings or command references
- Inspecting the current MCP setup
- Reading a file or symbol with `tilth`

## Commands

- `rg "copilot mcp|code-review-graph|tilth" .copilot CLAUDE.md packages.yaml`
- `copilot mcp get --config-dir .copilot code-review-graph`
- `tilth .copilot/README.md --budget 800`
- `code-review-graph status`

## Prompt pattern

> Based on this repo context, explain what command or config I should touch next. Keep the answer grounded in the pasted output.

## Note

`tilth` is a companion CLI here, not a Copilot plugin packaged inside `.copilot`.
