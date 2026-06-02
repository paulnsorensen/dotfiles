# Harness Permission Models & How `ap` Maps Onto Them

The five harnesses each have a *different* permission/tool-access model — different config surface, different allow/deny/ask vocabulary, different precedence. `ap` declares permissions once (in a profile) and renders them per harness, but the mapping is **lossy and uneven**: only Claude gets a full allow+deny surface, opencode gets allow-only-bash-only, and two harnesses get nothing. This page is the cross-harness reference behind those renderer decisions, plus the planned fixes.

For the renderer mechanics see [[agent-profile]]; for each harness's wider config surface see [[../harnesses/index]].

## TL;DR — `ap` has no default permissions

There is **no hardcoded default permission set** anywhere in `ap` (verified: zero `DEFAULT_ALLOW`/`DEFAULT_DENY` constants across the package). Permissions are *purely profile-declared*. If a `profile.yaml` declares nothing, nothing is written, and the harness falls back to whatever the user's own live config already grants. The "default perms" for every non-isolated profile is therefore **the user's existing harness config** — `ap` only layers additively on top. The single exception is an **isolated** Claude launch, which cuts off inheritance (`--setting-sources ""`) so its surface is exactly its declared `tools` + `permissions_deny`.

## Two permission channels in `profile.yaml`

| Channel | Profile key | Merges from `include:`? | Used by |
|---|---|---|---|
| Install (non-isolated) | `settings.permissions_allow` | yes — union + sorted (`parse.py`) | claude install, opencode |
| Launch overlay (isolated) | top-level `permissions_allow` / `permissions_deny` | **no** — outermost profile only | isolated claude launch only |

Both default to empty list. The isolated fields are launch-overlay fields (the ccp parity); the `settings.permissions_allow` nested field is the only one that feeds non-isolated installs. **There is no `settings.permissions_deny` channel today** — that gap blocks rendering deny rules to opencode/cursor (the planned-fix specs add it).

## Native model per harness

### Claude Code — full allow / deny / ask, the richest surface

The only harness with a first-class deny path in config.

- **Surface:** `settings.json` → `permissions: { allow: [], deny: [], ask: [] }`. CLI: `--allowedTools` / `--disallowedTools` (permission-rule syntax, skip-the-prompt), `--tools` (availability — restricts the model's context), `--setting-sources`, `--permission-mode`, `--append-system-prompt[-file]`.
- **Model:** evaluated **deny → ask → allow**, first matching rule wins. Rules **merge across all scopes** (managed > CLI > local > project > user) — a deny at *any* level cannot be cancelled by an allow at another. Bare `Bash` (≡ `Bash(*)`) removes the tool from context; scoped `Bash(rm *)` leaves it visible but blocks matches.
- **Rule syntax:** `Bash(cmd:*)` (`:*` = trailing wildcard; space before `*` enforces a word boundary; compound commands split on `&&`/`||`/`;`/`|`/newline and matched per-subcommand; wrappers like `timeout`/`nice`/`xargs` stripped first). Path tools anchor: `//abs`, `~/home`, `/project-root`, `./cwd`; `*` = one dir depth, `**` = recursive. `WebFetch(domain:example.com)`, `mcp__server__tool` / `mcp__server__*`, `Agent(Explore)`.
- **Modes (`defaultMode` / `--permission-mode`):** `default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`. `--setting-sources ""` (or `settingSources: []`) disables the three filesystem sources; **managed policy still loads**. `permissions.additionalDirectories` grants file access only (no `.claude/` config load); `--add-dir` additionally loads skills/plugins.
- **Docs:** [settings](https://code.claude.com/docs/en/settings) · [permissions](https://code.claude.com/docs/en/permissions) · [cli-reference](https://docs.anthropic.com/en/docs/claude-code/cli-reference)

### Codex CLI — sandbox + approval, **no per-command allow/deny in `config.toml`**

The key surprise: there is **no `allowed_commands` / `trusted_commands` array** in `config.toml`. Per-command allow/deny lives in a *separate* file with a DSL.

- **Primary model = two layers:** `sandbox_mode` (`read-only` | `workspace-write` | `danger-full-access`) — what the process *can* do; and `approval_policy` (`untrusted` | `on-request` | `never`; `on-failure` deprecated) — when Codex *pauses to ask*.
- **Per-command allow/deny = execpolicy `.rules` DSL**, not config.toml. Lives at `~/.codex/rules/default.rules`; Starlark-like `prefix_rule()` / `exact_rule()` with `decision = allow | prompt | forbidden`. The TUI "always allow" writes here automatically. `--ignore-rules` skips it for a run.
- **MCP per-tool filtering exists** (unlike codex's shell side): `[mcp_servers.<name>]` → `enabled_tools` (allowlist) / `disabled_tools` (denylist), plus `tools.<tool>.approval_mode` (`auto`|`prompt`|`approve`) and `default_tools_approval_mode`.
- **CLI:** `--sandbox`, `--ask-for-approval`/`-a`, `--full-auto` (deprecated alias), `--dangerously-bypass-approvals-and-sandbox`/`--yolo`, `-c key=value`. File: `~/.codex/config.toml`.
- **Docs:** [config-reference](https://developers.openai.com/codex/config-reference) · [exec-policy](https://developers.openai.com/codex/exec-policy) · [cli/reference](https://developers.openai.com/codex/cli/reference)

### opencode — `permission` object, allow / ask / **deny** supported

- **Surface:** `permission` object in `~/.config/opencode/opencode.json` (`OPENCODE_CONFIG` overrides path; `OPENCODE_PERMISSION` env accepts inline JSON).
- **Model:** every key is a tool name or wildcard; value is a string shorthand `"allow"` | `"ask"` | `"deny"`, OR (for 8 tools — `read`, `edit`, `glob`, `grep`, `bash`, `task`, `external_directory`, `skill`) a **pattern → action map**. The remaining keys (`lsp`, `webfetch`, `websearch`, `question`, `todowrite`) accept shorthand only. **Default when unset = `allow`** (all tools run without approval).
- **Precedence: last matching rule wins** — so put the catch-all `"*"` *first*, specifics after. `bash` matches the **parsed** command (`git status --porcelain`), not raw input. `~`/`$HOME` expand in patterns.
- **Key gotchas:** `edit` covers `write`/`apply_patch` (no separate `write` key); `read` is its own key; MCP tools match as `<server>_<tool>` (`mymcp_*: deny`). Per-agent overrides via `agent.<name>.permission` or agent markdown frontmatter.
- **Docs:** [permissions](https://opencode.ai/docs/permissions) · [tools](https://opencode.ai/docs/tools)

### Cursor — **split**: IDE allowlist is UI-only, but the CLI is fully declarative

This corrects the long-standing "Cursor permissions are UI-only" assumption. It is only half true — the IDE is UI-only, the `cursor-agent` CLI is a declarative JSON file with a Claude-like token grammar.

- **IDE (Cursor editor):** UI-only. Run Mode + command/MCP allowlist live in Settings → Agents → Run Mode + Protection. No config file for the IDE allowlist (the denylist UI was removed post-0.47).
- **CLI (`cursor-agent`) config files:**
  - **Global** `~/.cursor/cli-config.json` — holds *all* settings: `version` (int, current `1`), `editor.vimMode` (bool), `permissions.allow` (string[]), `permissions.deny` (string[]).
  - **Project** `<project>/.cursor/cli.json` — holds **only** `permissions`, and **takes precedence over global** for that key.
- **Token grammar (5 types):**
  - `Shell(base)` — matches the first command token; `Shell(curl:)` (colon) = curl with *any* args; `Shell(git)` allows **all** git subcommands (no subcommand-level filtering).
  - `Read(glob)` / `Write(glob)` — glob path; relative = workspace-scoped, absolute = anywhere. In `-p`/`--print` headless mode, `Write` also needs `--force` to actually write.
  - `WebFetch(domain)` — `*.example.com` (subdomains), `example.com` (exact), `*` (all).
  - `Mcp(server:tool)` — `Mcp(datadog:)` = all tools of a server; `Mcp(:search)` = any server's `search`; `Mcp(:)` = all MCP tools.
- **Precedence: deny wins** over allow (not first-match).
- **`sandbox.json`** is a **separate file** (`~/.cursor/sandbox.json` or `<workspace>/.cursor/sandbox.json`) — sandbox network + filesystem policy (`type`, `additionalReadwritePaths`, `additionalReadonlyPaths`, `disableTmpWrite`, `networkPolicy.default: allow|deny`). Not part of `cli-config.json`. `.cursor/` is always sandbox-protected.
- **Headless flags:** `-p`/`--print` (non-interactive), `--force`/`-f` (allow all unless denied — deny list still enforced), `--approve-mcps` (+ `--force` for reliable headless MCP). No `--allow`/`--deny` runtime flags — permissions are config-file only.
- **Docs:** [cli permissions](https://cursor.com/docs/cli/reference/permissions) · [cli configuration](https://cursor.com/docs/cli/reference/configuration) · [sandbox.json](https://cursor.com/docs/reference/sandbox) · [terminal/run-mode](https://cursor.com/docs/agent/tools/terminal) · [mcp](https://cursor.com/docs/mcp)

### Copilot CLI — layered: MCP `tools` exposure vs runtime approval flags

- **Two layers:** (1) per-MCP-server `tools` field in `~/.copilot/mcp-config.json` controls which tools are *exposed* (`["*"]` = all; a named list restricts); (2) `--allow-tool` / `--deny-tool` runtime flags control whether the agent must *prompt* before using an exposed tool.
- **Flag syntax:** `Kind(argument)`; kinds are `memory`, `read`, `shell`, `url`, `write`, and `SERVER-NAME`. `shell(git:)` (colon = prefix, all subcommands), MCP as `MyMCP(create_issue)`. Comma-separate multiple in one flag. **`--deny-tool` always beats allow, even under `--allow-all`.** `--available-tools` removes tools from the set entirely (stronger than deny). `--allow-all-tools` (env `COPILOT_ALLOW_ALL`), `--allow-all`/`--yolo`.
- **Persistent approvals:** `~/.copilot/permissions-config.json` (auto-managed per project — *not* for hand-editing). `~/.copilot/config.json` holds `trustedFolders` (path trust, not tool perms); `~/.copilot/settings.json` holds `allowedUrls`/`deniedUrls`/`disabledMcpServers`/`enabledMcpServers`. `preToolUse` hook can return `permissionDecision: allow|deny`.
- **Docs:** [cli-command-reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference) · [allowing-tools](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools) · [add-mcp-servers](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers) · [config-dir-reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)

## How `ap` renders a declared permission per harness (today)

| Harness | Renderer behavior | Allow | Deny | File written |
|---|---|:---:|:---:|---|
| **Claude** (install) | `_write_settings` (`claude.py:472-484`) writes plugin-scoped `settings.json` `permissions.allow` if non-empty; live root `settings.json` merge never touches permissions | ✅ | ✗ | `.claude/plugins/local/<profile>/settings.json` |
| **Claude** (isolated) | `overlay.py` ephemeral `settings.json` with `permissions.allow` **and** `permissions.deny`, paired with `--setting-sources ""` + `--tools` whitelist | ✅ | ✅ | ephemeral `settings.json` |
| **opencode** | `_translate_permission` (`opencode.py:38-47`) maps only `Bash(cmd:*)` → `cmd *`; everything else passes through verbatim into `permission.bash` | ✅ (bash only) | ✗ | `opencode.json` `permission.bash` |
| **Codex** | renderer writes agents/skills/hooks/mcps only — **no per-command rule rendered**. But Codex is *not* surface-less: it has a static `config.toml` permission surface `ap` doesn't yet target (see Planned fixes #5) | ✗ † | ✗ † | — |
| **Cursor** | declared perms **warned and dropped** (`cursor.py:117-124`, assumes "UI-only") | ✗ | ✗ | — |
| **Copilot** | **silently skipped** (uses runtime `--deny-tool`, not config) | ✗ | ✗ | — |

† Codex's `✗` is for the **per-command rule-list** dimension only — there is no `allowed_commands`-style config key. It is *not* "no permission surface": `sandbox_mode` + `approval_policy` (posture) and MCP `enabled_tools`/`disabled_tools` are static `config.toml` keys `ap` could render and currently doesn't.

So a profile's per-command `permissions_allow` rules only reach **Claude** (full, both channels) and **opencode** (allow-only, bash-only). Cursor and Copilot drop them; Codex drops the *rules* but exposes a separate static posture surface (below) that `ap` leaves on the table.

## Planned fixes & remaining gaps

1. **Cursor warn-and-drop → CLI render.** The renderer assumes UI-only — true for the *IDE*, but `cursor-agent` consumes declarative `permissions.allow`/`permissions.deny` from `~/.cursor/cli-config.json` with a token grammar near-identical to Claude's. Spec: **`.cheese/specs/ap-cursor-cli-permissions.md`** — adds `_write_cli_config`, translates Claude rules → Cursor tokens (`Bash(cmd:*)`→`Shell(cmd:)`, `Edit`→`Write`, `mcp__s__t`→`Mcp(s:t)`), merges like `.cursor/mcp.json`. Harmless if only the IDE is used (the file is read solely by the CLI), so safe to ship now.
2. **opencode loses deny + non-bash perms.** `_translate_permission` only emits `permission.bash` allow entries, yet opencode natively supports `deny` and per-tool (`edit`/`read`/`webfetch`/MCP) permissions with last-match-wins. Spec: **`.cheese/specs/ap-opencode-permission-fidelity.md`** — adds a `settings.permissions_deny` parse channel and translates the full Claude vocabulary into opencode's per-tool `permission` map.
3. **Shared dependency:** both specs need the new `settings.permissions_deny` union-merge in `parse.py` (today deny is top-level / isolated-claude-only). Land it once.
4. **Claude `settings.permissions_deny` not consumed (future).** Once the parse channel exists, the claude install renderer could also write `permissions.deny` (it only writes `allow` today) — explicitly out of scope of the two specs, noted here so it isn't forgotten.
5. **Permissions are two orthogonal dimensions, not one — and Codex covers the second.** Earlier framing ("Codex/Copilot have no static config permission surface by design") was wrong: it conflated *per-command rule-lists* with *permission surface in general*. Split them:
   - **Per-command rule-list** (`Bash(git:*)`, `Read(...)`, `mcp__s__t`). Renderable to Claude / opencode / Cursor-CLI. **Codex has no config key for this** (verified: no `allowed_commands`/`trusted_commands`/`permissions.allow` in `config.toml` — `developers.openai.com/codex/agent-approvals-security` and `config-reference`, `codex-config-reference.md:49`; per-command allow/deny is the TUI-written `.rules` execpolicy DSL at `~/.codex/rules/default.rules`, not declarative profile config). **Copilot has none either** (runtime `--allow-tool`/`--deny-tool` only; "No trustedTools in config.json yet" — feature request, `copilot-cli-permissions-raw.md:105`).
   - **Posture / mode** (read-only vs write, how aggressively to gate). **Codex renders cleanly here:** `sandbox_mode` (`read-only`|`workspace-write`|`danger-full-access`) + `approval_policy` (`untrusted`|`on-request`|`never`|`{ granular = { sandbox_approval, rules, mcp_elicitations, request_permissions, skill_approval } }`) — both static `config.toml` keys (`codex-config-reference.md:10-29`). An isolated read-only profile (e.g. `review`) maps directly to `sandbox_mode = read-only` + `approval_policy = untrusted`. `ap` doesn't render this today; it should.
   - **MCP tool scoping** is statically renderable for *both* Codex (`enabled_tools`/`disabled_tools`, `config-reference`) and Copilot (`mcp-config.json` `tools: [...]` exposure list, `copilot-cli-permissions-raw.md:57-72`). `ap` emits neither.

   Net: a "generic permission setting scoped for all harnesses" is achievable only when split by dimension — per-command rules reach Claude/opencode/Cursor; posture reaches Codex (+Claude `defaultMode`/`permission-mode`, opencode default action); MCP scoping reaches all five. No single channel reaches all five with the full vocabulary.

## Provenance

Native-model facts extracted via `/briesearch` (2026-06-02) from each vendor's official docs (URLs cited inline); the deep Cursor CLI grammar in `.cheese/research/harness-perms/cursor-cli-permissions.md`, other raw bodies under `.cheese/research/harness-perms/raw/`. `ap` mapping + the two specs grounded by reading `agent_profile/renderers/*.py` + `overlay.py` + `parse.py` (file:line in the specs).

See also [[agent-profile]] · [[config-drift]] · [[../harnesses/claude]] · [[../harnesses/cursor]] · [[../harnesses/opencode]]
