---
name: lsp
description: >
  Check LSP plugin status and troubleshoot language server issues.
  All 7 LSP plugins are enabled globally — this skill shows what's running,
  verifies binaries, and diagnoses issues.
permissions:
  allow:
    - "Bash(lspmux:*)"
    - "Bash(which:*)"
    - "Bash(claude:*)"
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

### 1. Check lspmux status

```bash
lspmux status
```

Show active instances, their workspace roots, and connected clients.

### 2. Verify binaries

For each plugin, check the real binary exists (stripping dotfiles/bin wrappers):

```bash
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'dotfiles/bin' | tr '\n' ':' | sed 's/:$//')"
for bin in bash-language-server vtsls yaml-language-server rust-analyzer pyright-langserver gopls solargraph; do
  echo "$bin: $(command -v "$bin" 2>/dev/null || echo 'NOT FOUND')"
done
```

### 3. Check plugin enablement

```bash
claude plugin list 2>&1 | grep -E "claude-code-lsps" -A3
```

All should show `Status: ✔ enabled`. If any show disabled, run:
`claude plugin enable <name>@claude-code-lsps`

### 4. Report

```
LSP Status:
  lspmux: running | not running | not installed
  Active instances: N (list servers + workspace roots)

  Binaries:
    bash-language-server: /opt/homebrew/bin/bash-language-server
    vtsls: /opt/homebrew/bin/vtsls
    ...
    solargraph: NOT FOUND (install with: gem install solargraph)

  Plugins: 7/7 enabled | N/7 enabled (list disabled ones)
```

## Troubleshooting

- **LSP tool not available**: Restart Claude Code — plugins load at session start
- **Server not starting**: Check binary exists (step 2). lspmux-wrap requires `--` before server args (fixed in lspmux-wrap)
- **lspmux down**: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lspmux.server.plist`
- **Plugin disabled**: `claude plugin enable <name>@claude-code-lsps`
- **Wrong binary found**: Ensure `$DOTFILES_DIR/bin` is first on PATH (wrappers must shadow real binaries)
