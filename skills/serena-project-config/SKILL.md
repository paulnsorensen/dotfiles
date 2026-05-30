---
name: serena-project-config
model: haiku
description: >
  Tune per-repo Serena MCP config when auto-bootstrap is not enough. Use for
  monorepos, wrong language detection, generated-dir exclusions, review-only
  setups, or .serena/project.yml changes.
---

# serena-project-config

Tune `.serena/project.yml` when the auto-bootstrap is wrong.

Serena is registered globally with `--project-from-cwd`, so on first activation in any repo it writes a sensible `.serena/project.yml` (language auto-detected, gitignore respected). For most repos that's the end of it. This skill is for the 20% of repos where the auto-bootstrap picks the wrong defaults or leaves performance on the table.

## When to act (and when not to)

Trigger an edit only if one of these is true:

| Symptom | Root cause | Fix |
|---|---|---|
| LSP doesn't resolve symbols across package boundaries | Monorepo; serena only sees the active workspace folder | `additional_workspace_folders` |
| `find_symbol` returns wrong language results, or LSP errors at startup | Auto-detect picked the wrong primary language | Edit `languages:` |
| `find_symbol` is slow / floods results from `vendor/`, `node_modules/`, `dist/`, generated code | Those dirs aren't in `.gitignore` (or `ignore_all_files_in_gitignore` is off) | Add `ignored_paths:` |
| Wrong Python venv, wrong PHP intelephense version, etc. | LSP needs language-specific tuning | `ls_specific_settings:` |
| Repo is review-only and you don't want serena writing | — | `read_only: true` |
| Want to lock down which serena tools work here | — | `excluded_tools:` (additive to global) |

If none of these apply, leave `.serena/` alone. The bootstrap is fine.

## The `.serena/` directory contract

| File | Purpose | Git status (this dotfiles repo) |
|---|---|---|
| `project.yml` | Main config — committed in serena's intended workflow | gitignored by the top-level `.gitignore` |
| `project.local.yml` | Local overrides; same schema as `project.yml` | always gitignored (serena's own `.serena/.gitignore`) |
| `cache/` | Symbol cache; rebuilt on demand | always gitignored |
| `memories/` | Memory store | inert — memory tools are globally disabled |
| `.serena/.gitignore` | Excludes `cache/` + `project.local.yml` | committed by serena's intent |

`<certain>` The top-level `.gitignore` in this dotfiles repo blanket-excludes `.serena/`, so by default every repo's serena config is per-machine. That's deliberate for single-author exploratory work but wrong for monorepos and shared-team repos — see [Committing decision](#committing-decision) below.

## How to edit `project.yml`

**Never create the directory from scratch.** Activate serena once (`find_symbol` against any file does it), let the bootstrap write the defaults, then edit. The auto-generated file has serena's inline documentation as comments — keep them.

Key fields:

```yaml
# the project name shown in serena's UI / logs
project_name: "my-repo"

# LSP keys to start; choose from the 60-language enum in serena's docs.
# First entry is the default/fallback. Multi-language repos list each.
languages:
  - typescript
  - python

# additive to .gitignore — gitignore syntax (*, **)
ignored_paths:
  - "vendor/**"
  - "dist/**"
  - "**/*.generated.ts"

# TypeScript-only currently; cross-package symbol search in monorepos
additional_workspace_folders:
  - ../shared-lib
  - packages/utils

# per-language LSP knobs; keys vary per language server
ls_specific_settings:
  python:
    python_interpreter: ".venv/bin/python"
  php_phpactor:
    ignore_vendor: true

# disables all edit tools for this repo
read_only: false

# additive to ~/.serena/serena_config.yml excluded_tools
excluded_tools:
  - execute_shell_command  # example only — sandbox repos
```

`<speculative>` Exact `ls_specific_settings` keys are LSP-dependent. Check the [Configuration page](https://oraios.github.io/serena/02-usage/050_configuration.html) before guessing — Python and PHP are well-documented; others may have no knobs at all.

## Committing decision

| Repo shape | Recommendation |
|---|---|
| Single-author / exploratory | Leave gitignored — auto-bootstrap will recreate it on any machine |
| Monorepo with non-trivial `additional_workspace_folders` | `git add -f .serena/project.yml` — the config encodes architectural intent that other contributors need |
| Shared team repo with custom `ignored_paths` or `ls_specific_settings` | `git add -f .serena/project.yml` — saves every collaborator from re-discovering the same tuning |
| Review-only fork (`read_only: true`) | Commit it — the read-only stance is policy, not preference |

To commit selectively without un-gitignoring the whole dir, use the path-specific override pattern:

```bash
git add -f .serena/project.yml
```

This bypasses the blanket `.serena/` ignore for that one file. If many repos need this, consider editing the top-level `.gitignore` to unignore `.serena/project.yml` globally while keeping `cache/` and `project.local.yml` out:

```gitignore
.serena/
!.serena/project.yml
```

## Verification

After editing, confirm the config took effect:

1. **Render the rendered system prompt** — quickest sanity check that serena parsed the file:

   ```bash
   serena print-system-prompt "$(pwd)"
   ```

   Look for your project name, language list, and excluded tools in the output.

2. **Probe a symbol** — exercise the LSP layer:
   - Call `find_symbol` with a known name from the repo, `include_body=true`.
   - The result should be a clean symbol record, not an LSP startup error.

3. **Check diagnostics** — `get_diagnostics_for_file` on any source file should return either real diagnostics or an empty list. If it returns LSP setup errors, the `languages:` or `ls_specific_settings:` are wrong.

If verification fails, the fastest path forward is to delete `.serena/cache/` (forces a rebuild) and retry. If it still fails, your `languages:` entry probably doesn't match a key in [serena's Language enum](https://github.com/oraios/serena/blob/main/src/solidlsp/ls_config.py).

## What NOT to do

- **Don't enable memory tools or `onboarding`.** They're globally excluded in `~/.serena/serena_config.yml` because they collide with the user's `MEMORY.md` auto-memory system. Re-enabling them per-project via `included_optional_tools` will split-brain the memory model.
- **Don't hand-roll `.serena/` from scratch.** Let `--project-from-cwd` bootstrap, then edit. Manual creation skips serena's inline documentation comments and misses fields added by newer versions.
- **Don't put secrets, large blobs, or long instructions in `initial_prompt`.** It's prepended to every session in this repo and inflates context unnecessarily. Use `agents/AGENTS.md` (committed) or `CLAUDE.md` (repo-local) for stable instructions.
- **Don't toggle `ignore_all_files_in_gitignore: false` to "see more code".** It floods the symbol index with generated/vendor files and degrades every subsequent lookup. Use `included_optional_tools` or targeted `ignored_paths` overrides instead.

## Gotchas

- `<certain>` `additional_workspace_folders` is TypeScript-only at time of writing — Rust workspaces, Go modules, and Python monorepos won't benefit. For non-TS monorepos, the workaround is to start serena from the monorepo root and rely on the language server's own workspace detection.
- `<certain>` `excluded_tools` in `project.yml` is *additive* to the global list. You cannot un-exclude a tool that the global config disables. If you need the memory tools back in one repo (you don't), they have to be re-enabled globally first.
- `<speculative>` Some LSP servers (intelephense, rust-analyzer) cache aggressively. After editing `ls_specific_settings`, deleting `.serena/cache/` is sometimes not enough — restart the serena MCP server (in Claude Code: drop session, reopen) to fully reset.
- `<certain>` `read_only: true` disables *every* editing tool — including `replace_symbol_body` and `insert_*_symbol`. It does not just block `replace_content`. Confirm that's the intent before setting it.
- The auto-bootstrap picks `languages:` from the dominant file extension. In a polyglot repo where the dominant language is documentation (e.g. a docs-heavy monorepo with `.md` outnumbering `.ts`), it can pick `markdown` and leave you without a real LSP. Override explicitly.

## References

- Serena project config schema: [oraios.github.io/serena/02-usage/050_configuration.html](https://oraios.github.io/serena/02-usage/050_configuration.html)
- Language enum (full list of LSP keys): [github.com/oraios/serena/blob/main/src/solidlsp/ls_config.py](https://github.com/oraios/serena/blob/main/src/solidlsp/ls_config.py)
- Global serena config in this dotfiles repo: `chezmoi/dot_serena/modify_serena_config.yml`
- The "use serena" routing (separate concern): `agents/AGENTS.md` § Code-Intelligence Routing
