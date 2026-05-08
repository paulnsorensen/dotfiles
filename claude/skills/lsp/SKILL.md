---
name: lsp
model: haiku
description: >
  Check LSP plugin status and troubleshoot language server issues.
  LSP plugins ship installed but disabled at the user level — this skill shows
  what's running, verifies binaries, diagnoses issues, and points at the
  per-project opt-in (`cc-lsp-local`). Use when the user says "LSP not
  working", "language server down", "hover not working", "no type info",
  "check LSP", "types missing", or invokes /lsp. Also trigger when LSP
  operations return errors or empty results.
---

# lsp

LSP status and troubleshooting. LSP plugins are installed at the user level but
**disabled by default** — opt in per project via `cc-lsp-local` (writes
`.claude/settings.local.json`) or per session via the `cc` / `ccc` / `ccr` /
`ccp` shell wrappers (ephemeral tokei-driven gate). Servers start lazily once
enabled and the LSP tool hits a matching file.

## How it works

LSP plugins provide Claude Code's built-in `LSP` tool with 9 operations:
`goToDefinition`, `findReferences`, `hover`, `documentSymbol`, `workspaceSymbol`,
`goToImplementation`, `prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`.

- **Zero cost when idle** — servers only start when the LSP tool is invoked
- **Per-session servers** — each Claude session spawns its own LSP server
- **Auto-diagnostics** — after file edits, the language server reports errors inline
- **gopls daemon mode** — `bin/gopls` wrapper adds `-remote=auto`, sharing one daemon across all sessions
- **lsp-probe agent** — short-lived sub-agent for batched LSP queries (keeps parent agents lightweight)

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
claude plugin list 2>&1 | rg claude-code-lsps
```

## Troubleshooting

- **LSP tool not available**: Restart Claude Code — plugins load at session start
- **Server not starting**: Check binary exists with `command -v <binary>`
- **Plugin disabled**: `claude plugin enable <name>@claude-code-lsps`
- **Binary not found**: Run `dots sync` to install missing LSP servers from packages.yaml (`solargraph` requires `gem install solargraph`)

## Parallel / Worktree LSP Strategy

**gopls**: All sessions share one daemon via `bin/gopls` wrapper (`-remote=auto`). Zero cold-start after the first session warms it up.

**Other servers** (rust-analyzer, pyright, vtsls): Each session spawns its own. No daemon mode available.

**lsp-probe agent**: For read-only LSP queries in parallel pipelines, spawn `lsp-probe` as a sub-agent with a batch of queries. The probe cold-starts, executes all queries, returns structured results, and exits. Parent agents stay lightweight — no LSP server held for the session lifetime.

When to use lsp-probe vs direct LSP:

| Scenario | Use |
|----------|-----|
| Interactive editing (cook, wire) | Direct LSP — need diagnostics after edits |
| Read-only analysis (culture, age, review) | lsp-probe — batch queries, release server |
| Parallel worktree agents | lsp-probe — avoid N concurrent servers |
| Single foreground session | Direct LSP — no benefit to indirection |

## Gotchas

- Plugin enable/disable requires Claude Code restart to take effect
- LSP servers start lazily — a "not running" status is normal if no matching file has been opened yet
- gopls daemon: if the shared daemon crashes, all attached sessions lose LSP until a new one starts
- lsp-probe: adds sub-agent spawn latency (~5s) — don't use for single-query lookups
