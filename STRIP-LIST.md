# STRIP-LIST — dotplate extraction manifest

Decision record for everything extracted to `paulnsorensen/dotplate`.
Source of truth for what is in the template (and why), and what was left behind.

Distilled from `.cheese/notes/strip-log.md` + Phase D decisions.

---

## Legend

| Symbol | Meaning |
|---|---|
| COPY | Transferred verbatim |
| GENERICIZE | Transferred with personal content removed |
| STARTER | Transferred with personal entries stripped, keeping only minimal required content |
| EMPTY+SCHEMA | Transferred as empty schema (all entries moved to `onboard/catalog/`) |
| SKIP | Not transferred (personal or catalog-only) |
| NEW | Created fresh for the template |

---

## bin/

| File | Decision | Reason |
|---|---|---|
| `bin/dots` | GENERICIZE | Fixed hardcoded `$HOME/Dev/dotfiles` default; now derives path from `BASH_SOURCE` location |
| `bin/cc-env-exec` | COPY | Generic machinery |
| `bin/ccw-init` | COPY | Generic worktree init |
| `bin/ccw-check` | COPY | Generic worktree check |
| `bin/ccw-sweep` | COPY | Generic worktree sweep |
| `bin/colors` | COPY | Generic color utility |
| `bin/gh-issue-context` | COPY | Generic GH context tool |
| `bin/gh-pr-batch` | COPY | Generic GH PR batch tool |
| `bin/gh-pr-checks-batch` | COPY | Generic GH PR checks batch tool |
| `bin/gh-pr-prep` | COPY | Generic GH PR prep tool |
| `bin/gh-pr-review` | COPY | Generic GH PR review tool |
| `bin/git-file-risk` | COPY | Generic git file risk scorer |
| `bin/gopls` | COPY | Generic gopls wrapper |
| `bin/install-linux-server` | COPY | Generic Linux server installer |
| `bin/linux-install` | GENERICIZE | Relaxed root check for container environments; `_sudo` helper wraps all privilege calls |
| `bin/wt-git` | COPY | Generic worktree git helper |
| `bin/dotsclaude` | SKIP | Personal Claude launcher |
| `bin/cheatsheet` | SKIP | Personal cheatsheet |
| `bin/claude-json-prune` | SKIP | Personal session pruner |
| `bin/record-prompt` | SKIP | Personal prompt recorder |
| `bin/serena-sweep` | SKIP | Personal serena sweep |

---

## Root machinery

| File | Decision | Reason |
|---|---|---|
| `.sync-lib.sh` | COPY | Pure machinery |
| `.sync-with-rollback` | COPY | Pure machinery |
| `.vars` | COPY | Only `olddir` variable |
| `justfile` | COPY | Audited; no personal paths |
| `prek.toml` | COPY | Generic pre-commit config |
| `gitattributes` | COPY as `.gitattributes` | Generic git attributes |
| `.gitignore` | COPY (adapted) | Added `.cheese/`, cache patterns |
| `.markdownlint-cli2.yaml` | COPY | Generic linting config |
| `.ignore` | COPY | Generic search ignore patterns |
| `.env.example` | COPY | Placeholder values only |
| `zshrc` | GENERICIZE | Stripped `@paulnsorensen` header; made module loads glob-based with exists-check |

---

## packages/

| File | Decision | Reason |
|---|---|---|
| `packages/sync.sh` | GENERICIZE | Fixed `sync_apt` to actually install when root/sudo available (was advisory-only) |
| `packages/packages.yaml` | STARTER | Stripped personal/catalog entries; kept only machinery-required packages |

### Stripped from packages.yaml (personal)

- `rtk` — personal cargo tool (rtk-ai/rtk)
- `tilth` — paulnsorensen/tilth (personal repo; URL leaks identity)
- `hallouminate` — paulnsorensen/hallouminate (personal repo; URL leaks identity)
- `milknado` — paulnsorensen/milknado (personal project)

### Moved to onboard/catalog/packages.yaml (catalog)

All other packages (productivity tools, editors, optional CLIs). See catalog.

---

## chezmoi/

| File | Decision | Reason |
|---|---|---|
| `.chezmoi.toml.tmpl` | GENERICIZE | Removed `paulnsorensen@gmail.com` default; added `name` prompt |
| `private_dot_gitconfig.tmpl` | GENERICIZE | Removed `Paul Sorensen` hardcode; removed personal email alias; uses `{{ .name }}` |
| `.chezmoiroot` | COPY | Just contains `chezmoi/` |
| `.sync` | COPY | Chezmoi wiring script |
| `.chezmoiignore` | COPY | Standard ignores |
| `lib/install-cursor-plugin.sh` | GENERICIZE | Fixed comment referencing old `cheese-grok` plugin name |
| `lib/install-codex.sh` | COPY | Machinery lib |
| `lib/install-local-llm.sh` | COPY | Machinery lib |
| `lib/install-prompts.sh` | COPY | Machinery lib |

---

## agents/

| File | Decision | Reason |
|---|---|---|
| `agents/hooks/git-guard.sh` | COPY | Generic security hook |
| `agents/hooks/sensitive-file-guard.sh` | COPY | Generic security hook |
| `agents/hooks/registry.yaml` | STARTER | Kept git-guard + sensitive-file-guard; stripped cheese-flair + moshi hooks |
| `agents/lib/git-guard.js` | COPY | Needed by git-guard |
| `agents/lib/sensitive-file-guard.js` | COPY | Needed by sensitive-file-guard |
| `agents/mcp/registry.yaml` | EMPTY+SCHEMA | All MCPs are catalog |
| `agents/registry.yaml` | EMPTY+SCHEMA | All sub-agents are catalog |
| `agents/lib/cheese-flair.sh` | SKIP | Personal flair library |
| `agents/hooks/session-start-cheese-flair.sh` | SKIP | Personal flair hook |
| `agents/RTK.md` | SKIP | Personal RTK config |
| `agents/AGENTS.md` | SKIP | Personal agent preferences |
| `agents/reference/cheese-flair.md` | SKIP | Personal flair bank |

---

## cursor/plugins/local/

| Path | Decision | Reason |
|---|---|---|
| `cursor/plugins/local/cheese-grok/` | RENAMED to `repo-hooks/` | `cheese-grok` is a personal flair name; hooks themselves are generic |
| `cursor/plugins/local/repo-hooks/hooks/` | GENERICIZE | Updated `cheese-grok:` prefixes in log output to `repo-hooks:` |
| `cursor/plugins/local/repo-hooks/hooks/git-guard.sh` | GENERICIZE | Fixed hardcoded `$HOME/Dev/dotfiles` fallback; derives from `BASH_SOURCE` |

---

## skills/

| File | Decision | Reason |
|---|---|---|
| `skills/_registry.yaml` | EMPTY+SCHEMA | All skill sources are catalog |
| `skills/` local skill dirs | SKIP | All personal skills |

---

## claude/plugins/

| File | Decision | Reason |
|---|---|---|
| `claude/plugins/registry.yaml` | EMPTY+SCHEMA | All plugins are catalog |
| `claude/reference/sliced-bread.md` | COPY | Generic architectural pattern reference |
| `claude/reference/cheese-flair.md` | SKIP | Personal flair reference |

---

## profiles/

| Directory | Decision | Reason |
|---|---|---|
| `profiles/base/` | COPY | Generic base profile |
| `profiles/global/` | COPY (audited) | No personal paths |
| `profiles/_permissions/` | COPY (audited) | No personal paths |
| `profiles/fe/` | SKIP | Catalog profile |
| `profiles/notion/` | SKIP | Catalog profile |
| `profiles/plugin/` | SKIP | Catalog profile |
| `profiles/review/` | SKIP | Catalog profile |
| `profiles/rtkonly/` | SKIP | Personal RTK profile |
| `profiles/spec/` | SKIP | Catalog profile |
| `profiles/todo/` | SKIP | Catalog profile |

---

## zsh/

| File | Decision | Reason |
|---|---|---|
| `zsh/core.zsh` | GENERICIZE | Derives DOTFILES_DIR from repo location, not hardcoded path |
| `zsh/completion.zsh` | COPY | Generic completion init |
| `zsh/tools.zsh` | COPY | Generic tool inits (zoxide, atuin, yazi) |
| `zsh/aliases.zsh` | SKIP | Catalog module |
| `zsh/fzf.zsh` | SKIP | Catalog module |
| `zsh/prompt.zsh` | SKIP | Personal catalog module |
| `zsh/colors.zsh` | SKIP | Catalog module |
| `zsh/claude.zsh` | SKIP | Personal Claude config module |
| `zsh/skhd.zsh` | SKIP | Mac-only catalog module |

---

## tests/

| File | Decision | Reason |
|---|---|---|
| `tests/run-tests.sh` | COPY | Test runner machinery |
| `tests/install-bats.sh` | COPY | Bats installer |
| `tests/test_helper.bash` | COPY | Test helper |
| `tests/dots.bats` | COPY+GENERICIZE | Added BASH_SOURCE path-derivation regression test |
| `tests/sync-rollback.bats` | COPY | Tests sync machinery |
| `tests/packages.bats` | COPY | Tests packages machinery |
| `tests/chezmoi-wiring.bats` | COPY (adapted) | Removed tests for stripped personal content |
| `tests/install-base-profile.bats` | COPY | Tests base profile installer |
| `tests/git-guard.bats` | COPY (adapted) | Updated cursor plugin path from `cheese-grok` to `repo-hooks` |
| `tests/sensitive-file-guard.bats` | COPY (adapted) | Updated path reference from `cheese-grok` to `repo-hooks` |
| `tests/gh-pr-batch.bats` | COPY | Tests GH PR tools |
| `tests/git-file-risk.bats` | COPY | Tests git-file-risk |
| `tests/template-hygiene.bats` | NEW+EXTEND | Phase C: 17 tests; bans personal strings + `cheese-grok` directory name |
| `tests/catalog.bats` | NEW | Phase B: validates catalog YAML structure and coverage |
| `tests/onboarding.bats` | NEW | Phase C: 37 tests validating AGENTS.md contract, GUIDE.md passes, state machine |
| `tests/catalog-roundtrip.bats` | NEW | Phase D: validates every catalog entry round-trips into its target registry |
| `tests/linux-smoke.sh` | NEW | Phase D: ubuntu:24.04 container smoke test (skips gracefully when Docker absent) |
| `tests/e2e-onboarding-dry-run.sh` | NEW | Phase D: simulates all 8 onboarding passes; tests resumability and graduation |
| Personal test files | SKIP | Tests for stripped personal content |

---

## agent-profile/

| Decision | Reason |
|---|---|
| COPY entire dir (excluding `.venv/`, `.pytest_cache/`, `.cheese/`) | Vendored tool; pure machinery |

---

## iterm2/

| File | Decision | Reason |
|---|---|---|
| `iterm2/Selenized-Dark.itermcolors` | COPY | Generic color scheme |
| `iterm2/selenized-deutan-warm.itermcolors` | COPY | Generic color scheme variant |
| `iterm2/com.googlecode.iterm2.plist` | SKIP | Personal iTerm2 export |
| `iterm2/iterm2.base.plist` | SKIP | Personal base plist |
| `iterm2/dynamic.yaml` | SKIP | Personal background image reference |

---

## Directories not copied

| Directory | Reason |
|---|---|
| `macos/` | Mac extras; catalog/Phase B |
| `skhd/` | Mac-only catalog |
| `theme/` | Catalog |
| `tmux/` | Personal tmux config |
| `vim/` | Personal vim config |
| `fonts/` | Personal fonts |
| `ghostty/` | Personal terminal config |
| `vhs/` | Personal VHS recordings |
| `cargo/` | Personal cargo config |
| `codex/` | Personal codex config |
| `cursor/` (most) | Personal cursor config; only `repo-hooks/` plugin extracted |
| `iterm2/` (plists) | Personal iTerm2 |
| `.github/` | Personal GitHub config (includes rtk-rewrite.json) |

---

## onboard/catalog/ (new in Phase B+C)

All offerable items were created fresh in the template, not copied from source. Each
catalog file (`mcp.yaml`, `hooks.yaml`, `skills.yaml`, `plugins.yaml`,
`packages.yaml`, `zsh.yaml`, `mac-extras.yaml`) contains only items that can
be offered to any adopter without personal content.

Items excluded from catalog:

- `rtk` — personal tool
- `tilth` / `hallouminate` cargo packages — personal repo URLs leak identity (MCPs included by binary name)
- `milknado` — personal project
- `cheese-flow`, `vaudeville` plugins — personal flair
- `session-start-cheese-flair` hook — personal flair
- `git-guard`, `sensitive-file-guard` hooks — already in starter machinery

---

## Phase D fixes applied to dotplate

| Fix | File(s) | Why |
|---|---|---|
| `DOTFILES_DIR` derives from script location | `bin/dots:8` | Was hardcoded `$HOME/Dev/dotfiles`; breaks any non-standard clone path |
| Same fix for hook script fallback | `cursor/plugins/local/repo-hooks/hooks/git-guard.sh:33` | Same hardcoded path |
| `cheese-grok` → `repo-hooks` rename | `cursor/plugins/local/` dir + all references | `cheese-grok` is personal flair; banned by template-hygiene test |
| `sync_apt` actually installs | `packages/sync.sh:530-548` | Was advisory-only; containers and fresh Linux installs need it to run |
| `linux-install` root check relaxed | `bin/linux-install:37` | Container-as-root (no sudo) is valid; `_sudo` helper wraps all privilege calls |
| Catalog round-trip tests | `tests/catalog-roundtrip.bats` | Catches malformed catalog entries before adopter acceptance |
| Linux smoke test | `tests/linux-smoke.sh` | End-to-end validation in ubuntu:24.04 container |
| e2e onboarding dry-run | `tests/e2e-onboarding-dry-run.sh` | Validates state machine, resumability, graduation |
| GitHub template flag | `gh repo edit paulnsorensen/dotplate --template` | Required for "Use this template" button |
