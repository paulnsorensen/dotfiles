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
---

# lsp

LSP status and troubleshooting. All 7 LSP plugins are enabled globally in
`settings.json` — servers start lazily when the LSP tool is used on a matching file.

## How it works

LSP plugins provide Claude Code's built-in `LSP` tool with 9 operations:
`goToDefinition`, `findReferences`, `hover`, `documentSymbol`, `workspaceSymbol`,
`goToImplementation`, `prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`.

- **Zero cost when idle** — servers only start when the LSP tool is invoked
- **Per-session servers** — each Claude session spawns its own LSP server
- **Auto-diagnostics** — after file edits, the language server reports errors inline

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

Check binary availability:

```bash
for bin in bash-language-server vtsls yaml-language-server rust-analyzer pyright-langserver gopls solargraph; do
  command -v "$bin" &>/dev/null && echo "OK $bin" || echo "MISSING $bin"
done
```

Check plugin status:

```bash
claude plugin list 2>&1 | grep claude-code-lsps
```

## Troubleshooting

- **LSP tool not available**: Restart Claude Code — plugins load at session start
- **Server not starting**: Check binary exists with `command -v <binary>`
- **Plugin disabled**: `claude plugin enable <name>@claude-code-lsps`
- **Binary not found**: Run `dots sync` to install missing LSP servers from packages.yaml

## Gotchas

- Plugin enable/disable requires Claude Code restart to take effect
- LSP servers start lazily — a "not running" status is normal if no matching file has been opened yet
