# Cross-Harness Guards

Safety hooks that block dangerous tool calls. The design principle is **one classifier, many harness adapters** — the detection logic is written once and each harness wires a thin adapter that calls it, so behavior is identical everywhere and there's no duplicated logic to drift.

## git-guard

Blocks destructive git ops that silently discard uncommitted work — `git checkout -- <path>` / `git checkout .` / `git checkout -f`, `git restore <path>`, `git reset --hard`, `git clean -f` — but **only when the targeted paths actually have uncommitted changes**. A clean tree has nothing to lose, so the op is allowed and the guard never nags. This dirty-check is the whole reason a static command-pattern deny won't do: it would nag on a clean tree.

The classifier (`agents/lib/git-guard.js`, exporting `shouldBlock(command, cwd)` + `denyReason`) handles `sudo`/`env` prefixes, `-C` / `-c` global options, `--` pathspec separation, and `&&` / `||` / `;` / `|` / newline command segmentation. It is **fail-open everywhere**: a missing lib, absent `node`, malformed input, or a non-repo `cwd` always allows. The operator can opt out with `CLAUDE_GIT_GUARD=0`. Agents need explicit user approval before changing this control.

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

`agents/lib/tool-reroute.js` is the `PreToolUse` dispatcher that routes file operations through Tilth on Claude and Codex, with the bounded exemptions below. Its matcher is `Bash|Read|Write|Edit|MultiEdit|Grep|Glob|apply_patch|mcp__tilth__tilth_write`.[^reroute-wiring]

It denies each call below and names the Tilth MCP call to make instead:

- The built-in `Read` on a text file. Images, PDFs, and notebooks pass, because `Read` is Claude's only viewer for them.
- `Write`, `Edit`, `MultiEdit`, and the Codex `apply_patch` tool. Claude plan files (`~/.claude/plans/`) and auto-memory (`~/.claude/projects/*/memory/`) pass for `Read`, `Write`, and `Edit`.
- On Codex only, `tilth_write` targets outside the checkout. See Codex specifics.
- The `Grep` and `Glob` tools.
- Shell searches that read files: `grep`, `rg`, `ag`, and `ack` with a path, a `< file` redirect, or a recursive default.
- Shell reads: `cat`, `head`, `tail`, `sed`, `awk`, `nl`, `less`, `bat`, and `tac` with a file operand. `sed -i` names `tilth_write`.
- Shell write-redirects by `echo`, `printf`, or `cat` to any file, in the tree or outside it. Only stream devices, `/proc`, and `/sys` pass.

Shell routing applies outside the checkout too. Two bounded exemptions reduce friction without making an unresolved path look safe.[^reroute-exemptions]

- Claude scratch paths under `/tmp`, `/private/tmp`, or `$TMPDIR`, each followed by `claude-<uid>/`, pass after destination checks.
- Plain shell reads and searches pass when every target is a literal regular file of at most 16 KiB.

Scratch checks preserve raw `..` components, resolve symlinks through existing ancestors, reject dangling links, and reject multiply linked files.
New subdirectories can qualify when their existing ancestors resolve inside scratch.
The shared helpers live in `agents/lib/tool-reroute/exempt.js`; the hook registry deploys this runtime dependency.[^reroute-exemptions]

A relative-path exemption needs the command's actual working directory.
Unsupported compound commands make that directory unknown because their prefixes can hide `cd`.
Known absolute paths remain independently checkable.
An unknown directory produces a placeholder in recovery hints, not a path resolved against the original event directory.[^reroute-path-context]

Expansion markers must remain visible on concatenated path tokens.
A backtick substitution can append `..` components to an apparently safe scratch prefix.
Checking only that prefix grants an exemption to a different destination.[^reroute-path-context]

A small input file does not make its reader harmless.
Inline `sed` and `awk` programs must match known read-only forms before the small-file exemption applies.
Unknown script effects keep the deny; shell redirects alone cannot detect writes inside programs.[^reroute-script-effects]

Stream devices pass: `/dev/null`, `/dev/stdout`, `/dev/stderr`, `/dev/tty`, and `/dev/fd/N`.
Writes to `/proc` and `/sys` also pass because Tilth cannot write kernel interfaces.
The device match is exact; `..` components prevent escaping these interfaces.
A command that writes its own output, such as `just check > log`, still runs.
Read that log through `tilth_read`.
On Codex, ask before adding an allowed root to `DOTFILES_WRITE_GUARD_ALLOW`.[^reroute-wiring]

[^reroute-exemptions]: `agents/lib/tool-reroute/exempt.js` (`isScratchPath`, `allSmallFiles`); `agents/hooks/registry.yaml` (`tool-reroute.shared_assets`); `tests/tool-reroute-native.bats`.
[^reroute-path-context]: `agents/lib/tool-reroute/shell.js` (`parse`, `commandsWithCwd`); `agents/lib/tool-reroute/io.js` (`suggestPath`); `tests/tool-reroute.bats`.
[^reroute-script-effects]: `agents/lib/tool-reroute/io.js` (`readerScripts`, `scriptUnsafe`); `tests/tool-reroute.bats` (script writes and read-only controls).

_Source: PR #1190 review and approved guard fixes · Updated: 2026-10-06 · Supersedes: blanket scratch denial and event-cwd-only exemption checks._

Calls that read no file run unchanged: pipe filters such as `git log | grep fix`, here-doc bodies sent to a non-interpreter, `tail -f`, reads of `/dev`, `/proc`, and `/sys`, `find`, and `rg --files`. A piped `sed -f rules.sed` also runs: the script file runs but does not print, and Tilth cannot run it. The lexer looks through wrappers (`xargs`, `command`, `time`, `nice`, `timeout`, `sudo`, `env`, `find -exec`, backticks, `bash -c`) and ignores `#` comments. The hook still rewrites `cd <path> && git …` to `wt-git`.[^reroute-tests]

The hook fails open. The operator can set `DOTFILES_TOOL_REROUTE=0` when Tilth cannot connect. Denial feedback names the compliant tool, not an override command. Agents ask for explicit user approval before changing guard controls.[^guard-feedback]

### Denial feedback and approval

Task approval does not approve disabling a guard or expanding its allowlist. The operator controls remain available for explicit exceptions.[^guard-policy]

Codex transcripts show five immediate override attempts after git or sensitive-file denials in July and August 2026. The preceding user messages approve tasks, but do not explicitly approve guard changes. The denial text itself advertises override commands. This feedback encourages retries that weaken policy, even when the hook blocks them again.[^guard-history]

Feedback therefore keeps safe recovery steps and asks for explicit approval when no compliant route exists. Git feedback preserves work first. Sensitive-file feedback uses templates or operator-run actions that return only non-secret results. This change improves guidance; it does not create a mechanical approval boundary.[^guard-feedback]

[^guard-feedback]: `agents/lib/git-guard.js` (`denyReason`); `agents/lib/sensitive-file-guard.js` (`denyReason`); `agents/lib/tool-reroute.js` (`denyText`); `agents/lib/tool-reroute/native.js` (`outOfTreeReason`); `agents/lib/tool-reroute/io.js` (`writeReason`).
[^guard-policy]: `agents/AGENTS.md` (`Scope`).
[^guard-history]: Native Codex transcripts: `rollout-2026-08-20T18-11-22-01a0205e-da69-76f0-b805-c278bef1af34.jsonl:166-170`; `rollout-2026-07-31T08-21-21-019fb743-7c74-7a93-89ca-216060ec40ae.jsonl:119-123`; `rollout-2026-08-01T07-28-18-019fbc39-4958-70a2-9764-6a6f9f4cedd0.jsonl:104-108`; `rollout-2026-07-26T08-53-38-019f9da1-3fe3-78a0-b3bd-efca459374a0.jsonl:98-106`. Verified 2026-10-05.

### Why deny, and why two layers on Claude

The earlier design rewrote shell searches to the `tilth` CLI, because a static deny made the model retry. That design depended on a Tilth CLI, and the Tilth fork now narrows to code intelligence and AST search through MCP. A hook cannot turn a Bash call into an MCP call, so the hook now denies with the exact MCP call instead.

Claude also lists `Glob` and `Grep` in `permissions.deny`. A bare tool name removes the tool from Claude's context, so the model cannot retry it; a fresh `claude -p` session confirmed this on 2026-10-02. `Write` and `Edit` are not listed. Plan mode writes its plan file with `Write`, and it refuses MCP writers such as `tilth_write`. A live plan-mode run with `Write` denied could not write its plan file. A deny rule cannot exempt a path, so the hook gates `Write` and `Edit` instead. `MultiEdit` is not listed: current Claude builds do not ship it, and a deny rule for it logs a "matches no known tool" warning. `Read` is not denied there, because a permission rule cannot exempt images. The hook is the only gate for `Read`, `Write`, and `Edit`, and the second layer for `ap` launches that do not carry the Claude deny list.[^reroute-claude]

The `ap` permissions profile carries no file-tool deny, because it also lowers onto Cursor and Copilot. Those harnesses keep their native file tools.

### Codex specifics

Codex reports shell calls as `Bash` and file edits as `apply_patch`, and a `PreToolUse` deny blocks both (developers.openai.com/codex/hooks). The Codex hooks renderer prefixes the command with `env DOTFILES_HARNESS=codex`. The new hook entry follows `git-guard` and `sensitive-file-guard`. Codex can ask once to trust the new `tool-reroute` entry, and again for the changed `sensitive-file-guard` matcher.

Codex rejects `updatedInput` without `permissionDecision` and reports `PreToolUse Failed`. The hook therefore emits nothing for a no-op `cd <cwd> &&` strip on Codex. The `cd <path> && git` rewrite carries `allow` and runs on Codex. `git-guard` reads the `wt-git <path>`, `cd <path> &&`, and `git -C` forms, so a destructive command in another repo still meets the dirty-tree check.

The `apply_patch` deny moves every Codex write to `tilth_write`. Codex sets `approval_mode: approve` for it, and `tilth_write` accepts absolute paths. A probe on 2026-10-02 wrote outside the checkout. Whether the Codex sandbox covers MCP servers is not verified, so the hook does not rely on it. The hook therefore denies a Codex `tilth_write` whose real path is outside the git toplevel, `/tmp`, `$TMPDIR`, a `.cheese/` directory, or the cheese data directory. `DOTFILES_WRITE_GUARD_ALLOW` adds roots. Claude leaves this check to `worktree-guard`. `sensitive-file-guard` also reads the `glob` and `scope` fields of `tilth_search`, because every search now goes there. It also checks each glob with its leading and trailing wildcards removed, because a wildcard can match nothing: `*.env` matches `.env`. A live probe on 2026-10-02 found `*.env` passed the guard; Tilth's own denylist still redacted the contents.

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
