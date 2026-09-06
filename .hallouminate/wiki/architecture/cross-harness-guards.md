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

## Claude-only pre-tool guards

Beyond the cross-harness git-guard, Claude wires a `PreToolUse` guard (in `claude/hooks/`):

- **`worktree-guard.js`** (Edit/Write/MultiEdit/`tilth_write`) — opt-out: it enforces inside a git worktree by default. `CLAUDE_WORKTREE_GUARD=0` disables; `CLAUDE_WORKTREE_GUARD_ALLOW=/abs,/abs2` extends the allowlist (worktree root, `$TMPDIR`, `/tmp`, `~/.claude/`, and any `.cheese/` dir are always allowed).

The **secret-protection guard** (`sensitive-file-guard`) is the other cross-harness guard, declared in the `agents/hooks/` registry rather than here — it blocks `.env`/keys/credentials, is fail-open, and honors `CLAUDE_SENSITIVE_GUARD` / `CLAUDE_SENSITIVE_GUARD_ALLOW`. See [[agents-dir]] for the hook-registry mechanics.

### Tilth payload coverage from the harness audit

The audit at base `f5d1e1d` finds that both guards miss current `edits[].path` requests.
Historical `files[].path` fixtures pass without checking the active MCP contract.[^tilth-payload]

The prepared `fix/harness-guard-payloads` branch extracts each edit path and every `move_file` destination.
It resolves relative edit paths against the tool request's `cwd`.
The sensitive-file guard also removes selectors from tilth read paths, but preserves literal `#` characters in write paths.[^tilth-correction]

This distinction prevents a read selector from hiding a sensitive filename.
It also prevents read-selector rules from changing a literal write target.
Current-schema fixtures cover mixed batches, move destinations, selectors, and worktree escapes.[^tilth-fixture]

Status: proposed in `fix/harness-guard-payloads`; not merged or deployed.
Do not treat the main checkout as protected before this branch lands and deploys.
Keep parser fixtures aligned with the active MCP schema rather than a historical approximation.

[^tilth-payload]: Audit at `f5d1e1d`; `agents/lib/sensitive-file-guard.js:122-137`; `claude/hooks/worktree-guard.js:73-90`.
[^tilth-correction]: Prepared branch `fix/harness-guard-payloads`; `agents/lib/sensitive-file-guard.js:124-155`; `claude/hooks/worktree-guard.js:73-92`.
[^tilth-fixture]: Prepared branch `fix/harness-guard-payloads`; `tests/sensitive-file-guard.bats`; `tests/hooks-blockers.bats`.

_Source: harness audit and prepared branch · Updated: 2026-09-05 · Supersedes: unresolved-gap-only description._
