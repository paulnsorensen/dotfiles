# chezmoi docs index

Read this file when a question goes deeper than the skill and its references.
The chezmoi docs change every few releases: new template functions, config keys, and prefixes.
Fetch the live page instead of guessing from training data.

## How to fetch

1. Pick the exact page from the table below. Do not crawl or map the site; the URLs are stable.
2. Fetch that single URL. Prefer a web-extract tool (for example Tavily `tavily_extract` with `extract_depth: "advanced"`, `format: "markdown"`).
3. Fall back to Context7, then to `chezmoi help <command>`.

All paths are relative to `https://www.chezmoi.io`.

| Topic | Path |
|---|---|
| Concepts (source / target / destination / working tree) | `/reference/concepts/` |
| Source-state attribute order per target type | `/reference/source-state-attributes/` |
| Target types (file / dir / symlink / script / modify / create / remove) | `/reference/target-types/` |
| Application order on `chezmoi apply` | `/reference/application-order/` |
| All command-line flags (global / common / developer) | `/reference/command-line-flags/` |
| Per-command reference (`chezmoi <name>`) | `/reference/commands/<name>/` |
| Configuration file structure | `/reference/configuration-file/` |
| Hooks (read-source-state / apply / etc.) | `/reference/configuration-file/hooks/` |
| Interpreters for scripts by extension | `/reference/configuration-file/interpreters/` |
| Special files (`.chezmoiignore` etc.) | `/reference/special-files/<name>/` |
| Special directories (`.chezmoidata/` etc.) | `/reference/special-directories/<name>/` |
| Template variables (`.chezmoi.os` etc.) | `/reference/templates/variables/` |
| Template directives (`chezmoi:template:`, etc.) | `/reference/templates/directives/` |
| Built-in template functions | `/reference/templates/functions/<name>/` |
| `init` template functions (`promptBoolOnce` etc.) | `/reference/templates/init-functions/<name>/` |
| Password-manager template functions | `/reference/templates/<vendor>-functions/<name>/` (1password, bitwarden, dashlane, doppler, ejson, gopass, keepassxc, keeper, keyring, lastpass, pass, passhole, protonpass, vault, aws-secrets-manager, azure-key-vault, secret) |
| GitHub template functions | `/reference/templates/github-functions/<name>/` |
| Plugins | `/reference/plugins/` |

## Pick a page

- "What does prefix X do" → `source-state-attributes`.
- "What does `chezmoi <cmd>` do" → `commands/<cmd>`.
- "Which template variable holds Y" → `templates/variables`.
- "How do I read a secret from Z" → `templates/<vendor>-functions`.
