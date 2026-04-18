---
name: lsp
model: haiku
description: >
  Check LSP plugin status and troubleshoot language server issues.
  All 7 LSP plugins are enabled globally — this skill shows what's running,
  verifies binaries, and diagnoses issues. Use when the user says "LSP not
  working", "language server down", "hover not working", "no type info",
  "check LSP", "types missing", or invokes /lsp. Also trigger when LSP
  operations return errors or empty results.
permissions:
  allow:
    - "Bash(lsp-status:*)"
---

# lsp

LSP status and troubleshooting. All 7 LSP plugins are enabled globally in
`settings.json` — servers start lazily when the LSP tool is used on a matching file.

## How it works

LSP plugins provide Claude Code's built-in `LSP` tool with 9 operations:
`goToDefinition`, `findReferences`, `hover`, `documentSymbol`, `workspaceSymbol`,
`goToImplementation`, `prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`.

- **Zero cost when idle** — servers only start when the LSP tool is invoked
- **Auto-diagnostics** — after file edits, the language server reports errors inline
- **Lifecycle** — servers start per-session and die when the session exits

## LSP in agents

LSP is available in **named sub-agents** (spawned via the Agent tool) but NOT in
**forked skills** (`context: fork`). Three agents are designed to use LSP directly:

| Agent | LSP usage |
|-------|-----------|
| **culture-lsp** | Primary tool — documentSymbol, findReferences, goToDefinition |
| **fromage-cook** | Post-edit verification — hover, documentSymbol, auto-diagnostics |
| **fromage-age** | Review verification — hover, findReferences |

All other agents use **lsp-probe** — a short-lived sub-agent that cold-starts LSP,
executes a batch of queries, returns results, and exits. This keeps LSP servers
scoped to the probe's lifecycle instead of accumulating RAM in long-running agents.

## Enabled plugins

| Plugin | Binary | Languages |
|--------|--------|-----------|
| `bash-language-server@claude-code-lsps` | `bash-language-server` | .sh, .bash, .zsh |
| `vtsls@claude-code-lsps` | `vtsls` | .ts, .tsx, .js, .jsx |
| `yaml-language-server@claude-code-lsps` | `yaml-language-server` | .yaml, .yml |
| `rust-analyzer@claude-code-lsps` | `rust-analyzer` | .rs |
| `pyright@claude-code-lsps` | `pyright-langserver` | .py, .pyi |
| `gopls@claude-code-lsps` | `gopls` | .go |
| `solargraph@claude-code-lsps` | `solargraph` | .rb, .rake |

## Protocol

Run the all-in-one health check:

```bash
lsp-status
```

This script verifies all 7 binaries exist and confirms plugin enablement.
Report the output to the user and flag anything that needs attention.

## Troubleshooting

- **LSP tool not available**: Restart Claude Code — plugins load at session start
- **Server not starting**: Check binary exists in `lsp-status` output
- **Plugin disabled**: `claude plugin enable <name>@claude-code-lsps`
- **Binary not found**: Run `dots sync` to install missing LSP servers from packages.yaml

## Gotchas

- `lsp-status` script may not be on PATH if `dots sync` hasn't run
- Plugin enable/disable requires Claude Code restart to take effect
- LSP servers start lazily — a "not running" status is normal if no matching file has been opened yet
