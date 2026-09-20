# Dev Environment

The local developer-experience tooling that isn't agent config: git diff/merge tooling, pre-commit hooks, and Claude marketplace plugins.

## Git tooling

- **Default email** is templated via chezmoi (`{{ .email }}`); override per-repo with `git config user.email` (the `cpersonal` alias is a shortcut).
- **difftastic** — AST-aware structural diff (Tree-sitter, 700+ languages). The `gds` alias is `GIT_EXTERNAL_DIFF=difft git diff` (inline structural output, *not* `difftool`). For side-by-side, use `git difftool -t difftastic` (the registered `[difftool "difftastic"]` entry). Composes with delta (delta pages log/show/blame; difftastic outputs directly).
- **mergiraf** — AST-aware merge driver, registered globally via `gitattributes` for all supported languages. Auto-resolves structural conflicts (import reorders, independent additions) and falls back to standard merge otherwise. Works transparently with merge/rebase/cherry-pick.
- **Conflict-resolution chain:** mergiraf (auto-resolve structural) → rerere (replay remembered manual resolutions) → kdiff3 (manual). The `/melt` skill drives this cascade.
- `grb` rebases from `main` (not `master`).

### Host-wide command admission

`gate-slot` is the supported host-wide admission wrapper for heavy local commands.
It delegates scheduling to GNU `sem` and uses only the Python standard library.[^gate-slot-cli]

The wrapper uses a guardian because the visible wrapper cannot trap `SIGKILL`.
The guardian monitors wrapper liveness until exit, including after the `sem` leader exits.
A bounded relay keeps a blocked stderr sink from blocking supervision.
A failed sink disables forwarding without transferring workload ownership.
Normal completion drains stderr in order.[^gate-slot-guardian]
A launch barrier holds `sem` until its process-group identity is published.
Guardian loss closes the barrier, so an unpublished child cannot start queued or running work.[^gate-slot-barrier]

Command arguments travel through a private JSON file, not the `sem` command template.
A fixed helper reads that file and calls `os.execvp`.
Shell quoting alone cannot prevent GNU Parallel replacement expressions from evaluating command data.[^gate-slot-argv][^gate-slot-replacements]
GNU documents negative timeouts as an exit without execution; positive timeouts take a slot even when none is available.[^gate-slot-manual]
`--timeout` bounds each wait attempt, not command execution.
The wrapper makes three total attempts, with 0.1-second and 0.2-second backoff.
An expired wait returns exit 75 only after the final attempt.
It never retries a started command or a cancelled wait.
This bounded policy permits brief contention without an unbounded retry loop.[^gate-slot-timeout]

`just check` uses the named `dotfiles-check` pool with one host-wide slot.
This keeps separate worktrees from running the repository's full parallel gate together.[^gate-slot-just]
GNU Parallel remains the external runtime dependency and is installed through the package registry.[^gate-slot-package]

[^gate-slot-cli]: bin/gate-slot:1-24,368-470
[^gate-slot-guardian]: bin/gate-slot:128-147,205-321; tests/gate-slot.bats:485-609,765-912
[^gate-slot-barrier]: bin/gate-slot:173-203,284-297; tests/gate-slot.bats:611-685
[^gate-slot-argv]: bin/gate-slot:159-188; tests/gate-slot.bats:738-763
[^gate-slot-timeout]: bin/gate-slot:57-61,323-352; tests/gate-slot.bats:325-449,687-736
[^gate-slot-just]: justfile:73-83
[^gate-slot-package]: packages/packages.yaml:17-23
[^gate-slot-manual]: [GNU sem manual, DESCRIPTION and OPTIONS](https://www.gnu.org/software/parallel/sem.html), GNU Parallel 20260422; verified 2026-09-19.
[^gate-slot-replacements]: [GNU Parallel tutorial, Perl expression replacement string](https://www.gnu.org/software/parallel/parallel_tutorial.html); verified 2026-09-19.

*Source: gate-slot-cli Cure and focused regression tests · Updated: 2026-09-19 · Supersedes: shell-quoted argv and incomplete lifecycle notes.*

## Pre-commit hooks (prek)

Managed by [prek](https://prek.j178.dev/) via `prek.toml`. Hooks run on commit: trailing-whitespace, secret detection, shellcheck, large-file checks, and a **claude-config-sync check**.

**Always `dots sync` before committing** — the sync check blocks the commit if `~/.claude/` (settings, agents, commands, hooks, skills) is out of sync with the repo. `git commit --no-verify` overrides, but only for rare temporary cases; fix the underlying issue (e.g. a detected secret) instead. Run `prek install` after cloning to set up the hooks.

## rtk wiring (removed 2026-09)

`agents/lib/tool-reroute.js` delegated unmatched Bash commands to `rtk hook claude`; `claude.yaml` allowed `Bash(rtk:*)`; OMP ran a vendored `rtk.ts` extension; mise pinned `aqua:rtk-ai/rtk`. All of it is removed. The hook now lets an unmatched Bash command run unchanged.

**Measured value is near zero.** Two independent benchmarks (Quesma, Terminal-Bench 2.1, rtk 0.45.0, 2026-09; JetBrains SkillsBench, 2026-07) found rtk changes cost by -3% to +7.6% and lowers pass rate by 1-2 points. `rtk gain` reports bytes/4 against raw output the agent never receives, because Claude Code truncates long output and cached re-reads bill at 1/10. Filtered or broken rewrites add turns; Quesma saw one `rtk find` flag loop 339 times. This repo routes file reads through tilth, so rtk only touches git, test, gh, and build output. Full evidence: `.cheese/research/rtk-quesma/rtk-quesma.md`. Known local breakage: [[rtk-diff-false-drift]].

## Claude marketplace plugins

Distinct from the `agents/` registry system (see [[../architecture/agents-dir]]) and from the `global@local` plugin that `ap` wires (see [[../architecture/agent-profile]]): these are third-party plugins from external marketplaces, managed declaratively via `claude/plugins/registry.yaml`.

- Marketplaces must be added first: `claude plugin marketplace add <owner/repo>`.
- Workflow: `plugin-edit` → `plugin-sync` (apply) → restart Claude Code.
- An LSP server is just a plugin entry with `load: true` (servers start lazily).
- Unlike MCP, the plugins directory is **not** symlinked to `~/.claude` — Claude Code uses that location for plugin cache storage.
- If a plugin provides MCP tools, add `mcp__plugin_<name>__*` to `permissions.allow`.
- **A local/unpublished plugin's bundled MCP must run from its source, not PyPI.** When a `path:` entry points at an out-of-repo clone (e.g. `milknado@milknado` → `~/Dev/milknado`), the plugin's own `.mcp.json` cannot use a bare `uvx <pkg>` — that resolves against PyPI and fails to connect for an unpublished package (`× <pkg> was not found in the package registry`). Point it at the clone: `uvx --from <abs-path> <script>` (or `uv run --project <abs-path> <script>`). Verify with `claude mcp list` (look for `✗ Failed to connect`). Tradeoff: the absolute path is machine-specific, so the marketplace isn't portable until the package is published — then revert to bare `uvx <pkg>`.
- **A local marketplace must be registered with the CLI, not just jq-written into settings.** `claude/plugins/sync.sh`'s `sync_local_marketplaces` keeps `extraKnownMarketplaces` in the **live `~/.claude/settings.json`** (the committed `claude/settings.json` is retired — see `claude/.sync`; the `CLAUDE_SETTINGS_FILE` env var is the test seam for that hardcoded path). But writing that JSON entry is **not sufficient** — `claude plugin install <name>@<mp>` can only resolve a marketplace the CLI has actually fetched/registered. The entry won't show in `claude plugin marketplace list` and has no `~/.claude/plugins/marketplaces/<name>/` cache dir until you run `claude plugin marketplace add <abs-path>` (idempotent: fetches when missing, "already on disk" no-op when present). So sync runs `marketplace add` per auto-managed local marketplace (`mp_name == plugin_name`); without it a freshly-added local plugin like milknado fails to install on first sync, and the failure is swallowed by the install step's `2>/dev/null`. Symptom: sync prints `Installing <plugin>... failed` but the plugin never lands in `claude plugin list`.

## skhd (removed 2026-08)

skhd is removed from this repo and this machine. The `skhdrc` was an empty skeleton after the yabai removal, so nothing used it. A stray `asmvik/formulae` tap also shipped `skhd`, which made the bare name ambiguous and broke the `dots up` brew-upgrade leg. The removal deleted `skhd/`, `zsh/skhd.zsh`, the `packages.yaml` entry, and the `koekeishiya/formulae` tap entry. If skhd returns, install it with the fully-qualified name `koekeishiya/formulae/skhd` and grant Accessibility access manually.

## CodeRabbit configuration review

Use the local `coderabbit` skill for repository configuration audits and requested setup changes.
The official CodeRabbit skills cover CLI code reviews and bot-thread fixes, not this configuration-audit workflow.[^coderabbit-skills]
The local skill keeps audit mode read-only and checks current product documentation instead of copying one repository preset.[^coderabbit-local]

Claude deploys the selected local skill through `dots sync`.
Codex uses the Skills CLI copy under `~/.agents/skills`; chezmoi intentionally excludes that cache.[^coderabbit-deploy]
Refresh the Codex copy after changing this local source:

```sh
npx --yes skills add <checkout> --skill coderabbit --agent codex -g --copy -y
```

Retiring Copilot review does not establish that its instruction files are inactive.
CodeRabbit detects `.github/instructions/*.instructions.md` and `AGENTS.md`; actual application also depends on guideline scope and mappings.[^coderabbit-guidelines]
Verify effective scope before removing or duplicating those instructions.

A successful CodeRabbit status does not alone prove that a review completes.
PR 967 has a successful status while its bot comment reports a review-capacity limit.[^coderabbit-limit]
Check completed-review evidence for the exact commit before relying on a replacement reviewer.

[^coderabbit-skills]: <https://github.com/coderabbitai/skills/tree/main/skills>
[^coderabbit-local]: skills/coderabbit/SKILL.md
[^coderabbit-guidelines]: <https://docs.coderabbit.ai/knowledge-base/code-guidelines>
[^coderabbit-limit]: <https://github.com/paulnsorensen/dotfiles/pull/967#issuecomment-5644530712>
[^coderabbit-deploy]: chezmoi/.chezmoiignore:19-24; .sync-lib.sh:592-603; verified Skills CLI deployment and byte comparison on 2026-09-12.
