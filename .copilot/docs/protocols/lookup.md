# Lookup workflow

This is a human guide, not a Copilot skill.

## Use it for

- Finding repo strings or command references
- Inspecting the current MCP setup
- Reading a file or symbol with `tilth`

## Commands

- `rg "copilot mcp|code-review-graph|context7|tavily|tilth" .copilot CLAUDE.md packages.yaml`
- `copilot --config-dir ~/.copilot mcp get code-review-graph`
- `copilot --config-dir ~/.copilot mcp get context7`
- `copilot --config-dir ~/.copilot mcp get tavily`
- `tilth .copilot/README.md --budget 800`
- `code-review-graph status`

## Prompt pattern

> Based on this repo context, explain what command or config I should touch next. Keep the answer grounded in the pasted output.

## Note

`context7` and `tavily` are Copilot MCPs here. `tilth` stays a companion CLI, not a Copilot plugin packaged inside `.copilot`.
