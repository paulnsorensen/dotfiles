# Sync System + Chezmoi

How `dots sync` deploys this repo to a machine. Two mechanisms coexist: a custom **symlink + `.sync`** system (being retired) and **chezmoi pure-copy** deployment (the future), with `ap` driving the agent-config render on top (see [[../architecture/agent-profile]]).

## The symlink + `.sync` system

`.sync` walks the repo and symlinks dotfiles into `$HOME`, dispatching per-directory `.sync` scripts for custom setup (fonts, iterm2, chezmoi).

- **Skip list** — dirs never symlinked to `$HOME`. Canonical source is `SYNC_SKIP_LIST` in `.sync-lib.sh`: `.git`, `.local`, `.worktrees`, `reference`, `packages`, `brew`, `apt`, `agents`, `agent-profile`, `codex`, `cursor`. `cursor` was added because the generic `ln -s "$dir/$file" ~/.$file` made `~/.cursor` a **whole-dir symlink into the repo**, so every Cursor runtime write (extensions, projects, ai-tracking, even Cursor's own generated `.gitignore`) leaked back into `dotfiles/cursor/`. Skipped now: `~/.cursor` is a real dir owned by chezmoi's `install-cursor-plugin.sh` + the `ap` cursor renderer + `agents/mcp/lib.sh` (which jq-edits `~/.cursor/mcp.json`). Only `cursor/plugins/local/cheese-grok/` + `cursor/.gitignore` (an allowlist) stay tracked.
- **Hidden-directory dispatch** — visible dirs are iterated by `for file in *`; hidden dirs (leading `.`) by `sync_hidden_dirs`. Both share one rule: if `$dir/.sync` exists, run it. `chezmoi/` is a visible dir that owns its `.sync` and short-circuits before symlinking.
- **`bin/` is special** — it is **never** copied or symlinked into `$HOME`. It runs live from the clone via `export PATH="$DOTFILES_DIR/bin:$PATH"` in `zsh/core.zsh`. There is no `dot_bin` chezmoi source. This is deliberate (PATH-from-clone, not copy-and-apply): edits to `dots`/`gh-*` helpers are live immediately, preserving the in-repo dev loop for the repo's own tooling.

### Backup/rollback subsystem — retired

The custom backup/restore/rollback subsystem has been **deleted** (chezmoi-consolidation, Stage 1). `dots rollback` no longer snapshots — it prints the git-backed undo path (`git revert` + `dots sync`). `dots backups` / `dots clean` are gone (`tests/dots.bats` asserts the retirement). The manifest/backup scaffolding in `.sync` has been removed; only `last_sync` (timestamp) remains. The file has been renamed from `.sync-with-rollback` to `.sync`.

## Package installation (`packages/sync.sh`)

`.sync` forks to `packages/sync.sh`, which installs everything declared in `packages/packages.yaml` (SHA-256-cached to skip when the file is unchanged).

- **Homebrew is the installer on both macOS and Linux.** The old Linux path (`sync_apt`, advisory-only — it *reported* missing apt packages but never installed) is gone; Linux now runs `sync_brew` like macOS. On a fresh Linux box the install script bootstraps Homebrew to `/home/linuxbrew/.linuxbrew` and `sync_brew` evals `brew shellenv` to get it on PATH for the rest of the run; `zsh/core.zsh` does the same eval for new shells.
- **Build deps are front-loaded on Linux.** `bootstrap_brew_deps_linux` (first thing in `sync_brew`) installs Homebrew's prerequisite toolchain (`build-essential procps curl file git`, or the dnf/yum/pacman/zypper equivalent) via the system package manager *before* the brew install, so the one sudo password prompt lands at the very start of the sync. It no-ops when `gcc`/`make`/`git`/`curl`/`file` are all present (no prompt on a warm box) and runs without `sudo` when already root (containers).
- **Casks are macOS-only** — `brew install --cask` errors on Linux, so the cask passes (and the greedy-cask upgrade) are Darwin-guarded.
- **Package names are always the brew formula key** (`.key`) on both platforms. There is no per-OS name override anymore (the dropped `apt:` field). `platform: mac` / `platform: linux` still gate which entries install where.
- **Pre-brew bootstraps on Linux** (brew isn't on PATH yet when these run): yq is downloaded as the Mike Farah Go binary into `~/.local/bin` (Ubuntu's apt `yq` is the wrong kislyuk/yq), and `uv` via the astral installer.
- Other sources (`cargo`, `npm`, `uv`, `gh-extension`) run cross-platform unconditionally. On Linux, npm comes from the brew `node` formula (which bundles it).

## Chezmoi-managed subset

chezmoi renders the files that need per-machine templating (work vs. personal git email), per-OS branching, or secret injection — things plain symlinks can't do. Everything else stays on the symlink system.

**Source:** the `chezmoi/` subdir. Currently manages, among others:

- `~/.gitconfig` — `chezmoi/private_dot_gitconfig.tmpl` (templated `{{ .email }}`; includes an `[http "https://gopkg.in"] followRedirects = true` block — an HTTP-redirect setting, **not** a `[url] insteadOf` rewrite).
- `~/.zprofile` — `chezmoi/dot_zprofile` (plain, not templated). A **static** equivalent of `eval "$(brew shellenv zsh)"` (the eval costs ~40ms per login shell) guarded by `[[ -d /opt/homebrew ]]`, plus the multiplier-dots overlay block (markers must stay byte-identical — multiplier-dots greps for them). **nvm is deliberately NOT initialized here**: the overlay's `profile.sh` owns nvm entirely (it has a `MULTIPLIER_PROFILE_SOURCED` re-source guard; `nvm.sh` itself has none, so a standalone nvm block double-sources it, ~50ms wasted — that was the pre-chezmoi state). Regenerate the static block with `brew shellenv zsh` if Homebrew relocates.
- `~/.copilot/mcp-config.json` — env-rendered API keys (fails fast if unset).
- `~/.claude/settings.json` — `dot_claude/modify_settings.json` authors the file WHOLESALE on every apply from `chezmoi/lib/claude-settings-authoritative.json` (static keys) + `chezmoi/.chezmoidata/claude.yaml` (registry-authored `hooks`, `enabledPlugins`, `extraKnownMarketplaces`, `permissions.*`). Live drift on managed keys is wiped; an unknown live key-path HALTS apply (fold it into a source, then re-sync) — unless it prefix-matches `chezmoi/lib/claude-settings-ignore.txt` (newline dot-paths, seeded `tui` + `env.SSL_CERT_FILE`): ignored paths are a third disposition (issue #355) — exempt from the halt AND their live value is preserved through the merge, except where the desired doc already owns the leaf (repo intent wins). The convention is per-guard by file naming (`lib/<guard>-ignore.txt`), no shared loader. (An earlier revision of this page wrongly named the file `create_settings.json` — it has been `modify_settings.json` since the modify_ rewrite.)
- Harness-global settings files (`~/.codex/config.toml`, `~/.config/opencode/opencode.json`, `~/.cursor/mcp.json`, `~/.copilot/mcp-config.json`, `~/.config/crush/crush.json`) are no longer mutated by non-isolated `ap install global`; their durable defaults belong in chezmoi or the harness's own runtime state. `ap` still writes generated agents/hooks/skills/plugin artifacts.
- `~/.claude/{skills,agents,commands,hooks,lib,reference,workflows}` — deployed as chezmoi **`exact_` dirs** (`chezmoi/dot_claude/exact_*`), assembled at sync time by `sync_claude_chezmoi_sources` (`.sync-lib.sh`, called from `chezmoi/.sync` BEFORE apply): registry-selected local skills (`claude.yaml skills:`), vendored external skills (`skills/_registry.yaml` → offline-tolerant clone cache under `~/.cache/dotfiles/claude-skill-sources`), agents rendered with frontmatter from `agents/registry.yaml`, and the `claude/` + `agents/{hooks,lib,reference}` asset dirs. `exact_` semantics = **deletions propagate**: anything live not present in source is removed on apply. The assembled trees are DERIVED, gitignored state; repo dirs stay the source of truth. (There is no `run_onchange` skills script — an earlier revision of this page claimed one that never existed.) **Skills-cadence boundary (issue #442):** plain `dots sync` deliberately refreshes only the chezmoi-native harnesses (claude `exact_` trees, omp `dot_omp/private_agent/exact_skills`) and never touches `~/.agents/skills` (codex + other `skills`-CLI consumers) — that is `dots upgrade`'s npx leg (`chezmoi/lib/install-external.sh`, `SKILL_EXCLUDE_AGENTS=claude-code`), keeping sync offline-capable. Pinned by tests in `tests/dots.bats`.
- `~/.claude.json` user-scope `mcpServers` — reconciled against `claude.yaml mcps:` by `run_onchange_after_sync-claude-mcps.sh.tmpl` → `chezmoi/lib/claude-mcp-reconcile.sh` via the `claude mcp` CLI + a manifest at `~/.claude/.chezmoi-mcp-manifest`: registry adds/updates/removes its own entries, adopts matching live entries on first run, and never touches hand-added live MCPs (flagged in output instead).
- `~/.omp/agent/config.yml` — `dot_omp/private_agent/modify_config.yml` authors the file WHOLESALE on every apply from `chezmoi/.chezmoidata/omp.yaml` (`omp.config`), mirroring the [[architecture/adr-chezmoi-authoritative-claude]] recipe. Live drift on managed keys is wiped; an unknown live key-path HALTS apply. `setupVersion` is exempt (machine state — preserved from live, never authored). NOT an `exact_` tree: `~/.omp/agent/` holds live sqlite DBs (agent.db, history.db, models.db) that must survive apply. Payload: `disabledProviders: [claude]` stops omp reading `~/.claude`; note this array *replaces* (not merges) across omp config layers, so a project-level `.omp/config.yml` can silently re-enable `claude`.
- `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.codex/config.toml` — handled by `run_onchange_*` scripts under `chezmoi/.chezmoiscripts/` that fork to helpers in `chezmoi/lib/`.
- `~/.cursor` plugin contents (`cheese-grok`) — `install-cursor-plugin.sh` (via `run_onchange_after_install-cursor-plugins.sh.tmpl`) copies the plugin into a **real** `~/.cursor`; `cursor` is in `SYNC_SKIP_LIST` so the dir is never a symlink into the repo.

**First-init (interactive):** `dots sync` dispatches to `chezmoi/.sync`, which runs `chezmoi init --source $DOTFILES/chezmoi` if `~/.config/chezmoi/chezmoi.toml` is missing. `.chezmoi.toml.tmpl` prompts for `email` (and the `localLLM` flag); answers persist and aren't re-prompted. **Subsequent runs:** `chezmoi apply --force`, non-interactive. **Non-TTY fallback:** writes a `sourceDir`-only stub; a later apply fails loud on any template reading `[data]` (run from a TTY to populate it).

### Hard rules

1. Never commit plaintext secrets to `chezmoi/`. Use `encrypted_` or `{{ env }}` / `{{ onepasswordRead }}`.
2. Never edit a chezmoi-managed source via the target path. Use `chezmoi edit ~/.gitconfig` so templating round-trips.
3. Always `chezmoi --source $DOTFILES/chezmoi diff` before applying when you've changed templates.
4. `prompt*` template funcs (`promptStringOnce`, …) belong **only** in `.chezmoi.toml.tmpl`. A `prompt*` call in a regular dotfile template re-prompts on every `apply`/`diff`/`status`, breaking `dots sync`. Pull the value through `[data]` instead.

### Adding a chezmoi file

Drop a templated source under `chezmoi/` using the [source-state attributes](https://chezmoi.io/reference/source-state-attributes/) (`private_`, `dot_`, `executable_`, `encrypted_`, `create_`, `modify_`, `.tmpl`). Prefix order is rigid and target-type-dependent — check the reference before `encrypted_private_dot_…`-style names. Add a test to `tests/chezmoi-wiring.bats`.

**Inspect/debug:** `chezmoi --source $DOTFILES/chezmoi diff` (what would change) · `data` (rendered namespace) · `execute-template < FILE.tmpl` · `chezmoi doctor`.

### Gotcha: `case` inside `$(…)` breaks macOS `/bin/bash` (3.2.57)

A `run_onchange`/`.chezmoiscripts` shell script (or any repo `.sh`) that nests a `case … esac` **inside a `$(…)` command substitution** must parenthesize every pattern — `(git) … ;;`, not `git) … ;;`. macOS ships GNU bash 3.2.57 (the GPLv2 freeze), whose parser naively counts parens while scanning for the end of `$(…)` and treats the pattern's closing `)` as closing the substitution → `syntax error near unexpected token ';;'` **at parse time** (so it fails even on machines where the code path never executes). Linux/Homebrew bash 5.x parses both forms fine, which is why it survives CI/review and only bites on a real macOS `dots sync`.

Two safe forms: parenthesize the patterns (`(git)`), or define the `case` in a named function and call it via `$(fn)` — the `case` is then not textually inside the substitution. `chezmoi/dot_claude/modify_settings.json` uses the function form deliberately; `run_onchange_after_sync-claude-plugins.sh.tmpl` (added #378) hit the bug and was fixed to the parenthesized form.

### Gotcha: startup caches that never refresh

Two zsh-startup caching patterns in this repo looked correct but silently degraded; both are fixed, remember the *why*:

- **`compinit` never touches an unchanged `.zcompdump`** — a "-C when the dump is <24h old" gate therefore stops firing ~24h after the dump is first written (mtime goes stale forever, every shell pays the full compaudit sweep again). `zsh/completion.zsh` explicitly `touch`es the dump in the full-`compinit` branch to reset the window. Verified empirically: backdating the dump and running full `compinit` leaves the mtime unchanged.
- **Caching `eval "$(<tool> init zsh)"` output makes transient failures permanent** — the uncached eval self-heals next shell; a cache written with a bare `> $cache` persists partial output from a failed init and sources it forever. `_init_cache` in `zsh/tools.zsh` writes to a temp file, checks the exit code, and atomically swaps — a failed init leaves the old cache intact (or none), never a poisoned one. Caches live in `~/.cache/zsh-init/`, keyed on binary mtime via zsh's fork-free `$commands[tool]`.

## Shell functions need tests

Every shell function that does real work needs a bats test. `.sync` (and any orchestrator) forks to tested functions instead of nesting untestable logic inline — `.sync` runs on every `dots sync`, so a regression there breaks the whole environment, and inline logic can't be exercised without running the full destructive sync against a real `$HOME`.

- New shell logic goes into a named function in a sourced library (`.sync-lib.sh`, `chezmoi/lib/*.sh`, `claude/lib/sync-common.sh`), taking inputs as arguments (no hidden globals).
- A `tests/<area>.bats` file exercises every branch; mock externals (`gh`, `claude`, `yq`, `jq`, `chezmoi`) by putting fakes earlier on `$PATH` (see `tests/chezmoi-wiring.bats`, `tests/skills-external.bats`).
- `.sync` scripts stay thin: parse args, source lib, dispatch. Add new test files to `tests/run-tests.sh` so `dots test` runs them.
