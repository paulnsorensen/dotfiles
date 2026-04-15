# Manual Copilot workflow

Use this repo-local workflow when docs plus MCPs are enough and no custom Copilot plugin is needed.

## 1. Check what Copilot can see

- Repo copy: `copilot mcp list --config-dir .copilot`
- Repo copy details: `copilot mcp get --config-dir .copilot code-review-graph`
- Live user config after sync: `copilot mcp list`

## 2. Gather local context yourself

- Changes: `git diff --stat` or `git diff -- .copilot`
- Text search: `rg "pattern" .`
- Tree-sitter read: `tilth bin/dots --budget 1200`
- Graph status: `code-review-graph status`

`tilth` is a companion CLI in this environment. Run it directly when you want a budgeted file or symbol view.

## 3. Ask Copilot with concrete input

Paste the command output you just gathered and ask for one focused task, such as:

> Review this `.copilot` diff for unsupported Copilot CLI claims. Focus on incorrect commands and invalid plugin assumptions.

## 4. Verify with real repo commands

- Shell changes: `shellcheck -x -e SC1091 .copilot/.sync`
- Broader repo regression check: `dots test`

If this repo ever needs reusable Copilot-native hooks, skills, or agents, add a real plugin under `.copilot/plugins/` instead of creating repo-level pseudo-skills.
