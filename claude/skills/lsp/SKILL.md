---
name: lsp
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
- **lspmux deduplicates** — multiple sessions share one server per workspace root
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

Run the all-in-one health check:

```bash
lsp-status
```

This single script checks lspmux status, verifies all 7 binaries exist (behind
dotfiles/bin wrappers), and confirms plugin enablement. Report the output to the
user and flag anything that needs attention.

## Troubleshooting

- **LSP tool not available**: Restart Claude Code — plugins load at session start
- **Server not starting**: Check binary exists in `lsp-status` output. lspmux-wrap requires `--` before server args
- **lspmux down**: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lspmux.server.plist`
- **Plugin disabled**: `claude plugin enable <name>@claude-code-lsps`
- **Binary not found**: Run `dots sync` to install missing LSP servers from packages.yaml
- **Wrong binary found**: Ensure `$DOTFILES_DIR/bin` is first on PATH (wrappers must shadow real binaries)

## Gotchas

- `lsp-status` script may not be on PATH if `dots sync` hasn't run
- Plugin enable/disable requires Claude Code restart to take effect
- lspmux config path is hardcoded to macOS (`~/Library/Application Support/lspmux/`)
- LSP servers start lazily — a "not running" status is normal if no matching file has been opened yet
