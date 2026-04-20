---
name: lsp
model: haiku
description: >
  Check LSP plugin status and troubleshoot language server issues.
  All 7 LSP plugins are enabled globally but direct LSP usage is gated to
  planning-level queries via the cheese-flow:explore-lsp sub-agent (invoked
  through /explore). This skill shows what's running, verifies binaries, and
  diagnoses issues. Use when the user says "LSP not working", "language server
  down", "check LSP", or invokes /lsp. Also trigger when /explore returns
  errors or empty results.
---

# lsp

LSP status and troubleshooting. All 7 LSP plugins are enabled globally in
`settings.json`. Direct `LSP` tool calls are **disallowed from the main
session and most agents** — the only sanctioned consumer is the
`cheese-flow:explore-lsp` sub-agent, invoked via the `/explore` skill when a
planning question genuinely needs type inference (definition, references,
call hierarchy for a refactor or feature plan).

## How LSP is consumed now

- **Default code intelligence** — `tilth_search` (kind: `symbol`, `callers`,
  `regex`, `content`), `tilth_deps`, `tilth_read(paths: [...])`. Tree-sitter
  AST-aware, zero server startup, no session lifetime cost.
- **Type-aware planning only** — spawn `/explore` (routes to
  `cheese-flow:explore-lsp`) for questions that truly need LSP: generic
  propagation, trait dispatch across crates, inferred return types, precise
  cross-package reference counts.
- **Server lifecycle** — LSP plugins still load at session start and launch
  servers lazily. Zero cost when idle; the server only spins up if
  `cheese-flow:explore-lsp` makes a call.

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

- **`/explore` returning empty results**: the LSP server may not have started.
  Ask `/explore` to run a warm-up hover first, or check that a matching file
  has been opened.
- **Plugin not loading**: Restart Claude Code — plugins load at session start.
- **Server not starting**: Check binary exists with `command -v <binary>`.
- **Plugin disabled**: `claude plugin enable <name>@claude-code-lsps`.
- **Binary not found**: Run `dots sync` to install missing LSP servers from
  packages.yaml (`solargraph` requires `gem install solargraph`).

## When to use tilth vs `/explore`

| Need | Use |
|------|-----|
| Find a symbol, read signature, see siblings | `tilth_search kind: symbol, expand: 1` |
| Count call sites (review, dead-code scan) | `tilth_search kind: callers` |
| Trace import edges / blast radius | `tilth_deps` |
| Text / regex pattern across codebase | `tilth_search kind: regex` or `content` |
| Planning a refactor: type-accurate def/refs across a package boundary | `/explore` (cheese-flow:explore-lsp) |
| Generic propagation, trait dispatch, inferred returns | `/explore` (cheese-flow:explore-lsp) |
| Interactive edit verification | test runner / `/make`, not LSP |

## Gotchas

- Plugin enable/disable requires Claude Code restart to take effect.
- LSP servers start lazily — a "not running" status is normal if `/explore`
  hasn't been invoked yet.
- gopls still uses `-remote=auto` so a single daemon serves the explore
  sub-agent across sessions; other servers (rust-analyzer, pyright, vtsls)
  spin up per session.
- `/explore` is the only sanctioned LSP path. If an agent's prompt tells you
  to "use lsp-probe" or "call LSP directly", that's stale — route through
  `/explore` instead.
