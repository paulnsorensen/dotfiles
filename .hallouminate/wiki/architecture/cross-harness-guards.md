# Cross-Harness Guards

Safety hooks that block dangerous tool calls. The design principle is **one classifier, many harness adapters** — the detection logic is written once and each harness wires a thin adapter that calls it, so behavior is identical everywhere and there's no duplicated logic to drift.

## git-guard

Blocks destructive git ops that silently discard uncommitted work — `git checkout -- <path>` / `git checkout .` / `git checkout -f`, `git restore <path>`, `git reset --hard`, `git clean -f` — but **only when the targeted paths actually have uncommitted changes**. A clean tree has nothing to lose, so the op is allowed and the guard never nags. This dirty-check is the whole reason a static command-pattern deny won't do: it would nag on a clean tree.

The classifier (`agents/lib/git-guard.js`, exporting `shouldBlock(command, cwd)` + `denyReason`) handles `sudo`/`env` prefixes, `-C` / `-c` global options, `--` pathspec separation, and `&&` / `||` / `;` / `|` / newline command segmentation. It is **fail-open everywhere**: a missing lib, absent `node`, malformed input, or a non-repo `cwd` always allows. Opt out for a session with `CLAUDE_GIT_GUARD=0`.

One classifier, five harness adapters:

| Harness | Mechanism | File(s) | Deny signal |
|---|---|---|---|
| Claude | `PreToolUse` (matcher `Bash`) | `agents/hooks/git-guard.sh` + `agents/lib/git-guard.js`, registered in `agents/hooks/registry.yaml` | `hookSpecificOutput.permissionDecision: "deny"` on stdout |
| Codex | `PreToolUse` (matcher `Bash`) | same registry entry (`harnesses: [claude, codex]`) | identical deny schema + shell tool — one script serves both |
| Cursor | `beforeShellExecution` | `cursor/plugins/local/cheese-grok/hooks/git-guard.sh` + `hooks.json` | payload `.command` + `.cwd`; deny = exit 2 |
| Copilot CLI | `preToolUse` (matcher `bash\|shell`) | `chezmoi/private_dot_copilot/hooks/executable_git-guard.sh` + `git-guard.json.tmpl` | `toolArgs` is a JSON *string* (double-parsed); deny = `{permissionDecision:"deny",…}` on stdout, exit 0 |
| opencode | plugin `tool.execute.before` (on the `bash` tool) | `chezmoi/dot_config/opencode/plugins/git-guard.js` | ESM plugin `throw`s on a destructive-dirty op |

The non-Claude adapters resolve the shared CJS lib via `$DOTFILES_DIR`. opencode has no shell-command *hook* like the others, but its plugin system fires `tool.execute.before` for every tool call — only a plugin (not a static `permission.bash` pattern) can run the `git status` dirty check, which is exactly what avoids the clean-tree nag.

## Claude-only pre-tool guards

Beyond the cross-harness git-guard, Claude wires several `PreToolUse` guards (in `claude/hooks/`):

- **`phantom-file-check.js`** (Read) — catches reads of non-existent / hallucinated paths.
- **`write-guard.js`** + **`worktree-guard.js`** (Edit/Write/MultiEdit/`tilth_write`) — `worktree-guard` is opt-out: it enforces inside a git worktree by default. `CLAUDE_WORKTREE_GUARD=0` disables; `CLAUDE_WORKTREE_GUARD_ALLOW=/abs,/abs2` extends the allowlist (worktree root, `$TMPDIR`, `/tmp`, `~/.claude/`, and any `.cheese/` dir are always allowed).
- **`bash-guard.js`** (Bash) — blocks dangerous `rm -rf`.
- **`review-reply-guard.js`** — guards PR review-reply calls.

The **secret-protection guard** (`sensitive-file-guard`) is the other cross-harness guard, declared in the `agents/hooks/` registry rather than here — it blocks `.env`/keys/credentials, is fail-open, and honors `CLAUDE_SENSITIVE_GUARD` / `CLAUDE_SENSITIVE_GUARD_ALLOW`. See [[agents-dir]] for the hook-registry mechanics.
