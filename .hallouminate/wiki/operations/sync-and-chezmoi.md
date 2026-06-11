# Sync System + Chezmoi

How `dots sync` deploys this repo to a machine. Two mechanisms coexist: a custom **symlink + `.sync`** system (being retired) and **chezmoi pure-copy** deployment (the future), with `ap` driving the agent-config render on top (see [[../architecture/agent-profile]]).

## The symlink + `.sync` system

`.sync` walks the repo and symlinks dotfiles into `$HOME`, dispatching per-directory `.sync` scripts for custom setup (fonts, iterm2, chezmoi).

- **Skip list** — dirs never symlinked to `$HOME`. Canonical source is `SYNC_SKIP_LIST` in `.sync-lib.sh`: `.git`, `.local`, `.worktrees`, `reference`, `packages`, `brew`, `apt`, `agents`, `agent-profile`, `codex`.
- **Hidden-directory dispatch** — visible dirs are iterated by `for file in *`; hidden dirs (leading `.`) by `sync_hidden_dirs`. Both share one rule: if `$dir/.sync` exists, run it. `chezmoi/` is a visible dir that owns its `.sync` and short-circuits before symlinking.
- **`bin/` is special** — it is **never** copied or symlinked into `$HOME`. It runs live from the clone via `export PATH="$DOTFILES_DIR/bin:$PATH"` in `zsh/core.zsh`. There is no `dot_bin` chezmoi source. This is deliberate (PATH-from-clone, not copy-and-apply): edits to `dots`/`gh-*` helpers are live immediately, preserving the in-repo dev loop for the repo's own tooling.

### Backup/rollback subsystem — retired

The custom backup/restore/rollback subsystem has been **deleted** (chezmoi-consolidation, Stage 1). `dots rollback` no longer snapshots — it prints the git-backed undo path (`git revert` + `dots sync`). `dots backups` / `dots clean` are gone (`tests/dots.bats` asserts the retirement). The manifest/backup scaffolding in `.sync` has been removed; only `last_sync` (timestamp) remains. The file has been renamed from `.sync-with-rollback` to `.sync`.

## Chezmoi-managed subset

chezmoi renders the files that need per-machine templating (work vs. personal git email), per-OS branching, or secret injection — things plain symlinks can't do. Everything else stays on the symlink system.

**Source:** the `chezmoi/` subdir. Currently manages, among others:

- `~/.gitconfig` — `chezmoi/private_dot_gitconfig.tmpl` (templated `{{ .email }}`; includes an `[http "https://gopkg.in"] followRedirects = true` block — an HTTP-redirect setting, **not** a `[url] insteadOf` rewrite).
- `~/.copilot/mcp-config.json` — env-rendered API keys (fails fast if unset).
- `~/.claude/settings.json` — `dot_claude/create_settings.json` seeds the user-owned baseline once; `ap install global` then jq-merges `enabledPlugins["global@local"]` + `extraKnownMarketplaces.local` on every run, preserving user siblings.
- `~/.config/opencode/opencode.json` — seeded once (`create_opencode.json`), then the opencode renderer mutates the `mcp` block.
- `~/.claude/skills/`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.codex/config.toml`, MCP entries — handled by `run_onchange_*` scripts under `chezmoi/.chezmoiscripts/` that fork to helpers in `chezmoi/lib/`.

**First-init (interactive):** `dots sync` dispatches to `chezmoi/.sync`, which runs `chezmoi init --source $DOTFILES/chezmoi` if `~/.config/chezmoi/chezmoi.toml` is missing. `.chezmoi.toml.tmpl` prompts for `email` (and the `localLLM` flag); answers persist and aren't re-prompted. **Subsequent runs:** `chezmoi apply --force`, non-interactive. **Non-TTY fallback:** writes a `sourceDir`-only stub; a later apply fails loud on any template reading `[data]` (run from a TTY to populate it).

### Hard rules

1. Never commit plaintext secrets to `chezmoi/`. Use `encrypted_` or `{{ env }}` / `{{ onepasswordRead }}`.
2. Never edit a chezmoi-managed source via the target path. Use `chezmoi edit ~/.gitconfig` so templating round-trips.
3. Always `chezmoi --source $DOTFILES/chezmoi diff` before applying when you've changed templates.
4. `prompt*` template funcs (`promptStringOnce`, …) belong **only** in `.chezmoi.toml.tmpl`. A `prompt*` call in a regular dotfile template re-prompts on every `apply`/`diff`/`status`, breaking `dots sync`. Pull the value through `[data]` instead.

### Adding a chezmoi file

Drop a templated source under `chezmoi/` using the [source-state attributes](https://chezmoi.io/reference/source-state-attributes/) (`private_`, `dot_`, `executable_`, `encrypted_`, `create_`, `modify_`, `.tmpl`). Prefix order is rigid and target-type-dependent — check the reference before `encrypted_private_dot_…`-style names. Add a test to `tests/chezmoi-wiring.bats`.

**Inspect/debug:** `chezmoi --source $DOTFILES/chezmoi diff` (what would change) · `data` (rendered namespace) · `execute-template < FILE.tmpl` · `chezmoi doctor`.

## Shell functions need tests

Every shell function that does real work needs a bats test. `.sync` (and any orchestrator) forks to tested functions instead of nesting untestable logic inline — `.sync` runs on every `dots sync`, so a regression there breaks the whole environment, and inline logic can't be exercised without running the full destructive sync against a real `$HOME`.

- New shell logic goes into a named function in a sourced library (`.sync-lib.sh`, `chezmoi/lib/*.sh`, `claude/lib/sync-common.sh`), taking inputs as arguments (no hidden globals).
- A `tests/<area>.bats` file exercises every branch; mock externals (`gh`, `claude`, `yq`, `jq`, `chezmoi`) by putting fakes earlier on `$PATH` (see `tests/chezmoi-wiring.bats`, `tests/skills-external.bats`).
- `.sync` scripts stay thin: parse args, source lib, dispatch. Add new test files to `tests/run-tests.sh` so `dots test` runs them.
