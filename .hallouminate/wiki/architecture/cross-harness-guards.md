# Cross-Harness Guards

Safety hooks that block dangerous tool calls. The design principle is **one classifier, many harness adapters** — the detection logic is written once and each harness wires a thin adapter that calls it, so behavior is identical everywhere and there's no duplicated logic to drift.

## git-guard

Blocks destructive git ops that silently discard uncommitted work — `git checkout -- <path>` / `git checkout .` / `git checkout -f`, `git restore <path>`, `git reset --hard`, `git clean -f` — but **only when the targeted paths actually have uncommitted changes**. A clean tree has nothing to lose, so the op is allowed and the guard never nags. This dirty-check is the whole reason a static command-pattern deny won't do: it would nag on a clean tree.

The classifier (`agents/lib/git-guard.js`, exporting `shouldBlock(command, cwd)` + `denyReason`) handles `sudo`/`env` prefixes, `-C` / `-c` global options, `--` pathspec separation, and `&&` / `||` / `;` / `|` / newline command segmentation. It is **fail-open everywhere**: a missing lib, absent `node`, malformed input, or a non-repo `cwd` always allows. Opt out for a session with `CLAUDE_GIT_GUARD=0`.

One classifier, four harness adapters:

| Harness | Mechanism | File(s) | Deny signal |
|---|---|---|---|
| Claude | `PreToolUse` (`Bash`) | `agents/hooks/git-guard.sh` + `agents/lib/git-guard.js`, registered in `agents/hooks/registry.yaml` | `hookSpecificOutput.permissionDecision: "deny"` |
| Codex | `PreToolUse` (`Bash`) | same registry entry and script | identical deny schema |
| Cursor | `beforeShellExecution` | `cursor/plugins/local/cheese-grok/hooks/git-guard.sh` + `hooks.json` | exit 2 |
| Copilot CLI | `preToolUse` (`bash\|shell`) | `chezmoi/private_dot_copilot/hooks/executable_git-guard.sh` + `git-guard.json.tmpl` | `{permissionDecision:"deny",…}` on stdout, exit 0 |

The non-Claude adapters resolve the shared classifier through `$DOTFILES_DIR`.
OMP currently receives no git-guard adapter; its extension registry must not be
described as enforcing this classifier.

## Harness identity: the renderer sets it

A shared hook script must not infer its harness from the deploy path (PR #840 removed the `*.codex*` path match from `agents/hooks/tool-reroute.sh`). Path matching breaks under `ap` isolated launches, custom config roots, and any new harness.

The contract:

- The `ap` renderers are the adapters; other deploy paths (the retired `agents/hooks/sync.sh`, hand-run scripts, bats) rely on the `claude` default rather than emitting the prefix. Adding `codex` to a hook's `harnesses` list outside an `ap` renderer requires wiring the prefix in too — see `agents/hooks/registry.yaml`'s `tool-reroute` comment.
- Both renderers prefix every rendered hook command with `env DOTFILES_HARNESS=<harness>` via the shared `renderers/base.hook_env_prefix` helper (`renderers/claude.py` emits `env DOTFILES_HARNESS=claude ${CLAUDE_PLUGIN_ROOT}/hooks/<script>`; `renderers/codex.py` emits `env DOTFILES_HARNESS=codex bash <root>/hooks/<script>`). The `env` form (not a bare assignment prefix) survives a harness that argv-splits the command instead of running it through a shell — see [[../harnesses/codex-hooks-schema]].
- The script accepts only `claude` or `codex` from `DOTFILES_HARNESS`; anything else, including unset, falls back to `claude` so a hand-run or non-`ap` invocation (bats, manual) fails open instead of crashing on an unset variable.
- `tests/test_helper.bash` unsets `DOTFILES_HARNESS` so the bats suite stays hermetic when an operator exports it.

The Claude self-heal matcher in `renderers/claude.py` extracts the hook basename from the text after `/hooks/`, so the prefix does not disturb it. Golden fixtures under `agent-profile/tests/fixtures/golden/` carry the prefix.

## Hallouminate commit reminder

The Stop hook uses `hallouminate wiki status --cwd "$cwd" --json` as its dirty-knowledge classifier. This command replaces the hard-coded `.hallouminate/` path check. It covers every configured wiki and corpus root inside the repository.[^hallouminate-status-hook]

The hook reminds only after a recent commit leaves unstaged or untracked knowledge files. Staged-only files remain silent because Hallouminate treats them as captured. A missing or failed Hallouminate command fails open.[^hallouminate-status-tests]

Claude receives `additionalContext`. Codex receives a one-shot block continuation. The OMP `session_stop` extension receives bare reminder text from the same script.[^hallouminate-status-adapters]

[^hallouminate-status-hook]: `agents/hooks/commit-hallouminate-reminder.sh:35-65`.
[^hallouminate-status-tests]: `tests/commit-hallouminate-reminder.bats:17-235`.
[^hallouminate-status-adapters]: `agents/hooks/registry.yaml:276-294`; `chezmoi/dot_omp/private_agent/extensions/commit-hallouminate-reminder.ts:1-40`.

## tool-reroute

`agents/lib/tool-reroute.js` is the `PreToolUse` dispatcher that makes Tilth the only file tool on Claude and Codex. Its matcher is `Bash|Read|Write|Edit|MultiEdit|Grep|Glob|apply_patch|mcp__tilth__tilth_write`.[^reroute-wiring]

It denies each call below and names the Tilth MCP call to make instead:

- The built-in `Read` on a text file. Images, PDFs, and notebooks pass, because `Read` is Claude's only viewer for them.
- `Write`, `Edit`, `MultiEdit`, and the Codex `apply_patch` tool. Claude plan files (`~/.claude/plans/`) and auto-memory (`~/.claude/projects/*/memory/`) pass for `Read`, `Write`, and `Edit`.
- On Codex only, `tilth_write` targets outside the checkout. See Codex specifics.
- The `Grep` and `Glob` tools.
- Shell searches that read files: `grep`, `rg`, `ag`, and `ack` with a path, a `< file` redirect, or a recursive default.
- Shell reads: `cat`, `head`, `tail`, `sed`, `awk`, `nl`, `less`, `bat`, and `tac` with a file operand. `sed -i` names `tilth_write`.
- Shell write-redirects into the working tree.

Calls that read no file run unchanged: pipe filters such as `git log | grep fix`, here-doc bodies sent to a non-interpreter, `tail -f`, reads of `/dev`, `/proc`, and `/sys`, `find`, and `rg --files`. A piped `sed -f rules.sed` also runs: the script file runs but does not print, and Tilth cannot run it. The lexer looks through wrappers (`xargs`, `command`, `time`, `nice`, `timeout`, `sudo`, `env`, `find -exec`, backticks, `bash -c`) and ignores `#` comments. The hook still rewrites `cd <path> && git …` to `wt-git`.[^reroute-tests]

The hook fails open. `DOTFILES_TOOL_REROUTE=0` turns it off, for example when the Tilth MCP server does not connect. Every deny reason names this switch when it fits.

### Why deny, and why two layers on Claude

The earlier design rewrote shell searches to the `tilth` CLI, because a static deny made the model retry. That design depended on a Tilth CLI, and the Tilth fork now narrows to code intelligence and AST search through MCP. A hook cannot turn a Bash call into an MCP call, so the hook now denies with the exact MCP call instead.

Claude also lists `Glob` and `Grep` in `permissions.deny`. A bare tool name removes the tool from Claude's context, so the model cannot retry it; a fresh `claude -p` session confirmed this on 2026-10-02. `Write` and `Edit` are not listed. Plan mode writes its plan file with `Write`, and it refuses MCP writers such as `tilth_write`. A live plan-mode run with `Write` denied could not write its plan file. A deny rule cannot exempt a path, so the hook gates `Write` and `Edit` instead. `MultiEdit` is not listed: current Claude builds do not ship it, and a deny rule for it logs a "matches no known tool" warning. `Read` is not denied there, because a permission rule cannot exempt images. The hook is the only gate for `Read`, `Write`, and `Edit`, and the second layer for `ap` launches that do not carry the Claude deny list.[^reroute-claude]

The `ap` permissions profile carries no file-tool deny, because it also lowers onto Cursor and Copilot. Those harnesses keep their native file tools.

### Codex specifics

Codex reports shell calls as `Bash` and file edits as `apply_patch`, and a `PreToolUse` deny blocks both (developers.openai.com/codex/hooks). The Codex hooks renderer prefixes the command with `env DOTFILES_HARNESS=codex`. The new hook entry follows `git-guard` and `sensitive-file-guard`. Codex can ask once to trust the new `tool-reroute` entry, and again for the changed `sensitive-file-guard` matcher.

Codex rejects `updatedInput` without `permissionDecision` and reports `PreToolUse Failed`. The hook therefore emits nothing for a no-op `cd <cwd> &&` strip on Codex. The `cd <path> && git` rewrite carries `allow` and runs on Codex. `git-guard` reads the `wt-git <path>`, `cd <path> &&`, and `git -C` forms, so a destructive command in another repo still meets the dirty-tree check.

The `apply_patch` deny moves every Codex write to `tilth_write`. Codex sets `approval_mode: approve` for it, and `tilth_write` accepts absolute paths. A probe on 2026-10-02 wrote outside the checkout. Whether the Codex sandbox covers MCP servers is not verified, so the hook does not rely on it. The hook therefore denies a Codex `tilth_write` whose real path is outside the git toplevel, `/tmp`, `$TMPDIR`, a `.cheese/` directory, or the cheese data directory. `DOTFILES_WRITE_GUARD_ALLOW` adds roots. Claude leaves this check to `worktree-guard`. `sensitive-file-guard` also reads the `glob` and `scope` fields of `tilth_search`, because every search now goes there.

Agents that only read files grant `mcp__tilth__tilth_read` instead of `Read`. `roquefort-wrecker` grants `mcp__tilth__tilth_write` by exact name, so the Codex read-only derivation does not sandbox it.[^reroute-agents]

[^reroute-wiring]: `agents/hooks/registry.yaml` (`tool-reroute`); `agents/lib/tool-reroute/{native,search,io,shell}.js`.
[^reroute-tests]: `tests/tool-reroute.bats` (passthrough contract, here-doc, and lexer tests); `tests/tool-reroute-native.bats` (plan files, Codex out-of-tree writes, kill switch).
[^reroute-claude]: `chezmoi/.chezmoidata/claude.yaml` (`permissions.deny`, `PreToolUse` matcher).
[^reroute-agents]: `agents/registry.yaml`; `.sync-lib.sh` (`_cz_render_codex_agent`).

## Claude-only pre-tool guards

Beyond the cross-harness git-guard, Claude wires a `PreToolUse` guard (in `claude/hooks/`):

- **`worktree-guard.js`** (Edit/Write/MultiEdit/`tilth_write`) — opt-out: it enforces inside a git worktree by default. `CLAUDE_WORKTREE_GUARD=0` disables; `CLAUDE_WORKTREE_GUARD_ALLOW=/abs,/abs2` extends the allowlist (worktree root, `$TMPDIR`, `/tmp`, `~/.claude/`, and any `.cheese/` dir are always allowed).

The **secret-protection guard** (`sensitive-file-guard`) is the other cross-harness guard, declared in the `agents/hooks/` registry rather than here — it blocks `.env`/keys/credentials, is fail-open, and honors `CLAUDE_SENSITIVE_GUARD` / `CLAUDE_SENSITIVE_GUARD_ALLOW`. See [[agents-dir]] for the hook-registry mechanics.

### Tilth payload coverage (PR #891, merged)

An audit at base `f5d1e1d` found that both guards missed current `edits[].path` requests: historical `files[].path` fixtures passed without checking the active MCP contract.[^tilth-payload]

PR #891 (`fix/harness-guard-payloads`, commit `5b8bb72`) fixed both guards on `main`. Each guard now extracts every edit path and every `move_file` destination, and resolves a relative edit path against the tool request's `cwd`. The sensitive-file guard also strips selectors from tilth read paths, but preserves literal `#` characters in write paths.[^tilth-correction]

This distinction prevents a read selector from hiding a sensitive filename, and prevents a read-selector rule from changing a literal write target. Regression fixtures cover mixed batches, move destinations, selectors, and worktree escapes.[^tilth-fixture]

Status: merged and deployed on `main`. Keep parser fixtures aligned with the active MCP schema as it evolves, rather than a historical approximation.

[^tilth-payload]: Audit at `f5d1e1d`; `agents/lib/sensitive-file-guard.js:122-137`; `claude/hooks/worktree-guard.js:73-90` (pre-fix line numbers).
[^tilth-correction]: `agents/lib/sensitive-file-guard.js` (`editTargets`, `resolveTilthReadPath`); `claude/hooks/worktree-guard.js` (`editTargets`, `resolveEditPath`).
[^tilth-fixture]: `tests/sensitive-file-guard.bats`; `tests/hooks-blockers.bats`.

_Source: harness audit + PR #891 + worktree-git passthrough (session analytics 2026-09-09/10) · Updated: 2026-09-10 · Supersedes: unresolved-gap-only description._
