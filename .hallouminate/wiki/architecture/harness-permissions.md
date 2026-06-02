# Harness Permission Models & How `ap` Maps Onto Them

The five harnesses — Claude Code, opencode, Cursor, Codex, Copilot — each have a *different* permission/tool-access model: different config surface, different allow/deny/ask vocabulary, different precedence. The trap is to picture "permissions" as one knob. It isn't. Permission control splits into **three orthogonal levers**, and each harness exposes a *different subset* of them through a *different surface*:

1. **Per-command / per-tool rules** — "allow `git status`, deny `rm`, allow this one MCP tool." Fine-grained allow/deny lists keyed on a command or tool name. This is what people usually mean by "the allowlist."
2. **Posture / mode** — the coarse stance: read-only vs. write, sandbox confinement, how aggressively the agent pauses to ask.
3. **MCP-tool scoping** — which tools a given MCP server even *exposes* to the model, upstream of any allow/deny rule.

`ap` declares permissions once (in a profile) and renders them per harness. The mapping is **lossy and uneven**: no single lever reaches all five harnesses with full vocabulary, and `ap` today renders only a slice of what the harnesses natively accept. This page is the per-lever reference behind the renderer decisions, plus the planned fixes.

For renderer mechanics see [[agent-profile]]; for each harness's wider config surface see [[../harnesses/index]].

## TL;DR

- **`ap` ships no default permissions.** No hardcoded default set anywhere in the package (verified: zero `DEFAULT_ALLOW`/`DEFAULT_DENY` constants). Permissions are *purely profile-declared*; if a `profile.yaml` declares nothing, nothing is written and the harness falls back to the user's own live config. `ap` only layers additively. The one exception is an **isolated** Claude launch, which cuts inheritance (`--setting-sources ""`) so its surface is exactly its declared `tools` + deny.
- **Three levers, not one.** Per-command rules reach **all five** harnesses — but through *heterogeneous surfaces* (config files for Claude/opencode/Cursor, a renderable execpolicy `.rules` file for Codex, launch-flag injection for Copilot), not one channel. Posture reaches Codex, Claude, opencode, and Cursor. MCP-tool scoping is statically renderable to all five. No single *channel* reaches every harness — a canonical permission set has to be lowered per-lever, per-harness, onto whatever surface each one offers.
- **Where `ap` is lossy today:** opencode full allow+deny render landed in #259 (in review); Cursor-CLI rendering, Codex per-command (`.rules`) + MCP scoping, and Copilot per-command (launch flags) + MCP exposure are still on the table (see [Planned fixes](#planned-fixes--remaining-gaps)).

## How `ap` declares permissions

Two channels in `profile.yaml`, both defaulting to empty:

| Channel | Profile key | Merges from `include:`? | Used by |
|---|---|---|---|
| Install (non-isolated) | `settings.permissions_allow` / `settings.permissions_deny` | yes — union + sorted (`parse.py`) | claude install, opencode |
| Launch overlay (isolated) | top-level `permissions_allow` / `permissions_deny` | **no** — outermost profile only | isolated claude launch only |

The isolated top-level fields are the launch-overlay (ccp parity); the nested `settings.*` fields feed non-isolated installs. The `settings.permissions_deny` union-merge in `parse.py` shipped with #259 — before that, deny existed only as the top-level isolated-Claude field, which is why deny rules couldn't reach opencode or Cursor. A separate, non-`ap` channel seeds the Claude baseline: `chezmoi/dot_claude/create_settings.json` (one-time user-owned seed) — any canonical permission model has to decide how it relates to that seed.

---

## Lever 1 — Per-command / per-tool rules

Fine-grained allow/deny keyed on a command (`Bash(git:*)`), a file path (`Read(...)`), or an MCP tool (`mcp__server__tool`). This is the lever with the widest *vocabulary* divergence and the one Codex/Copilot can't express in config at all.

### Claude Code — full allow / deny / ask, the richest surface `<certain>`

The only harness with a first-class deny path in config.

- **Surface:** `settings.json` → `permissions: { allow: [], deny: [], ask: [] }`. CLI: `--allowedTools` / `--disallowedTools` (skip-the-prompt), `--tools` (availability — restricts the model's context).
- **Precedence:** evaluated **deny → ask → allow**, first matching rule wins. Rules **merge across all scopes** (managed > CLI > local > project > user) — a deny at *any* level cannot be cancelled by an allow at another.
- **Rule syntax:** `Bash(cmd:*)` (`:*` = trailing wildcard; space before `*` enforces a word boundary; compound commands split on `&&`/`||`/`;`/`|`/newline, matched per-subcommand; wrappers like `timeout`/`nice`/`xargs` stripped first). Bare `Bash` (≡ `Bash(*)`) removes the tool from context; scoped `Bash(rm *)` leaves it visible but blocks matches. Path tools anchor: `//abs`, `~/home`, `/project-root`, `./cwd`; `*` = one dir depth, `**` = recursive. Also `WebFetch(domain:example.com)`, `Agent(Explore)`.
- **Docs:** [settings](https://code.claude.com/docs/en/settings) · [permissions](https://code.claude.com/docs/en/permissions) · [cli-reference](https://docs.anthropic.com/en/docs/claude-code/cli-reference)

### opencode — full allow / ask / deny, last-match-wins `<certain>`

- **Surface:** the `permission` object in `~/.config/opencode/opencode.json` (`OPENCODE_CONFIG` overrides path; `OPENCODE_PERMISSION` env accepts inline JSON).
- **Model:** every key is a tool name or wildcard; value is shorthand `"allow"` | `"ask"` | `"deny"`, OR — for 8 tools (`read`, `edit`, `glob`, `grep`, `bash`, `task`, `external_directory`, `skill`) — a **pattern → action map**. The other keys (`lsp`, `webfetch`, `websearch`, `question`, `todowrite`) take shorthand only. **Default when unset = `allow`.**
- **Precedence: last matching rule wins** — put the catch-all `"*"` *first*, specifics after. `bash` matches the **parsed** command (`git status --porcelain`), not raw input; `~`/`$HOME` expand in patterns.
- **Gotchas:** `edit` covers `write`/`apply_patch` (no separate `write` key); `read` is its own key; MCP tools match as `<server>_<tool>` (`mymcp_*: deny`). Per-agent overrides via `agent.<name>.permission` or agent-markdown frontmatter.
- **Docs:** [permissions](https://opencode.ai/docs/permissions) · [tools](https://opencode.ai/docs/tools)

### Cursor CLI — declarative tokens, deny-wins `<certain>`

The IDE is UI-only (Run Mode + command/MCP allowlist live in Settings → Agents → Run Mode + Protection; no config file, denylist UI removed post-0.47). But the `cursor-agent` **CLI** is fully declarative — this corrects the long-standing "Cursor permissions are UI-only" assumption, which is only half true.

- **Files:** global `~/.cursor/cli-config.json` holds *all* settings (`version`, `editor.vimMode`, `permissions.allow` string[], `permissions.deny` string[]); project `<project>/.cursor/cli.json` holds **only** `permissions` and **takes precedence over global** for that key.
- **Token grammar (5 types):** `Shell(base)` matches the first command token — `Shell(curl:)` (colon) = curl with *any* args; `Shell(git)` allows **all** git subcommands (no subcommand-level filtering). `Read(glob)` / `Write(glob)` glob a path (relative = workspace-scoped, absolute = anywhere; in `-p`/`--print` headless mode `Write` also needs `--force`). `WebFetch(domain)` — `*.example.com` / `example.com` / `*`. `Mcp(server:tool)` — `Mcp(datadog:)` = all tools of a server, `Mcp(:search)` = any server's `search`, `Mcp(:)` = all MCP tools.
- **Precedence: deny wins** over allow (not first-match).
- **Headless flags:** `-p`/`--print`, `--force`/`-f` (allow all unless denied — deny list still enforced), `--approve-mcps`. **No `--allow`/`--deny` runtime flags** — permissions are config-file only.
- **Docs:** [cli permissions](https://cursor.com/docs/cli/reference/permissions) · [cli configuration](https://cursor.com/docs/cli/reference/configuration) · [terminal/run-mode](https://cursor.com/docs/agent/tools/terminal) · [mcp](https://cursor.com/docs/mcp)

### Codex — per-command rules via a renderable `.rules` file, not `config.toml` `<certain>`

There is **no `allowed_commands` / `trusted_commands` array** in `config.toml` (verified — `codex-config-reference.md:49`, exec-policy, agent-approvals-security). But per-command allow/deny *is* declarative and renderable — it lives in a **separate execpolicy `.rules` file**: `prefix_rule(pattern=[…argv tokens…], decision = "allow" | "prompt" | "forbidden")`, most-restrictive-wins (`forbidden > prompt > allow`). Codex scans `rules/` under every active config layer at startup, so `ap` can own its own file (`~/.codex/rules/ap-canonical.rules`) and lower the canonical `Bash(…)` rules into it without touching the TUI-owned `default.rules` — exactly parallel to Cursor's `cli-config.json`. `--ignore-rules` skips all rules for a run. Only the shell-command subset maps here; file access is posture and MCP rules use lever 3.

### Copilot CLI — per-command rules via launch flags, no config file `<certain>`

Per-tool allow/deny is **launch-flag only** — `--allow-tool` / `--deny-tool` (plus `--available-tools`, which removes everything not listed, and `--excluded-tools`); there is no `trustedTools`-style config key (feature request open, `copilot-cli-permissions-raw.md:105`). Flag syntax: `Kind(argument)` where kinds are `memory`, `read`, `shell`, `url`, `write`, and `SERVER-NAME` — e.g. `shell(git:)` (colon = prefix, all subcommands), `MyMCP(create_issue)`; comma-separate multiple per flag. **`--deny-tool` always beats allow, even under `--allow-all`.** Since `ap` also lowers to *launch flags* (not just config files — the isolated-Claude path does exactly this), the canonical rules can reach Copilot through a launch wrapper that injects `--allow-tool`/`--deny-tool` — but only when Copilot is launched through that wrapper; a bare `copilot` run gets nothing.

**Lever-1 reach: all five**, via heterogeneous surfaces — Claude (config + flags) · opencode (config map) · Cursor-CLI (config tokens) · Codex (renderable `.rules` execpolicy file) · Copilot (launch-flag injection). No *config-file* channel reaches Codex or Copilot, but both are reachable: Codex write-once (file scanned every run), Copilot launch-time (wrapper-injected flags).

---

## Lever 2 — Posture / mode

The coarse stance: read-only vs. write, sandbox confinement, gate aggressiveness. This is the lever **Codex renders most cleanly**, and the one that maps an isolated `review`-style profile to a genuinely read-only run.

- **Claude** `<certain>` — `defaultMode` / `--permission-mode`: `default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`. `--setting-sources ""` (or `settingSources: []`) disables the three filesystem sources (managed policy still loads). `permissions.additionalDirectories` grants file access only; `--add-dir` also loads skills/plugins.
- **Codex** `<certain>` — two static `config.toml` keys: `sandbox_mode` (`read-only` | `workspace-write` | `danger-full-access` — what the process *can* do) and `approval_policy` (`untrusted` | `on-request` | `never`; `on-failure` deprecated — when Codex *pauses to ask*), including the granular form `approval_policy = { granular = { sandbox_approval, rules, mcp_elicitations, request_permissions, skill_approval } }` (`codex-config-reference.md:10-29`). An isolated read-only profile maps directly to `sandbox_mode = read-only` + `approval_policy = untrusted`. CLI: `--sandbox`, `--ask-for-approval`/`-a`, `--dangerously-bypass-approvals-and-sandbox`/`--yolo`.
- **opencode** `<certain>` — the per-tool `"allow"|"ask"|"deny"` default action *is* its posture knob; setting `"*": "ask"` first yields an ask-everything stance, `"deny"` a read-only-ish one.
- **Cursor** `<certain>` — Run Mode (IDE UI) plus a **separate** `sandbox.json` (`~/.cursor/sandbox.json` or `<workspace>/.cursor/sandbox.json`): `type`, `additionalReadwritePaths`, `additionalReadonlyPaths`, `disableTmpWrite`, `networkPolicy.default: allow|deny`. Not part of `cli-config.json`; `.cursor/` is always sandbox-protected. ([sandbox.json](https://cursor.com/docs/reference/sandbox))
- **Copilot** `<certain>` — `--allow-all-tools` (env `COPILOT_ALLOW_ALL`), `--allow-all`/`--yolo`; `~/.copilot/config.json` `trustedFolders` (path trust, not tool perms); a `preToolUse` hook can return `permissionDecision: allow|deny`.
- **Docs:** Codex [config-reference](https://developers.openai.com/codex/config-reference) · [exec-policy](https://developers.openai.com/codex/exec-policy) · [cli/reference](https://developers.openai.com/codex/cli/reference)

**Lever-2 reach:** Codex (richest, static), Claude (`defaultMode`/`--permission-mode`), opencode (default action), Cursor (Run Mode + `sandbox.json`), Copilot (flags + `trustedFolders`).

---

## Lever 3 — MCP-tool scoping

Which tools a server *exposes* to the model — upstream of allow/deny. This is the **only lever statically renderable to all five harnesses**, which makes it the natural backbone of a cross-harness canonical model.

- **Claude** `<certain>` — `mcp__server__tool` / `mcp__server__*` rules in the same `permissions.allow`/`deny` surface as Lever 1.
- **opencode** `<certain>` — MCP tools match as `<server>_<tool>` in the `permission` map (`mymcp_*: deny`).
- **Cursor** `<certain>` — `Mcp(server:tool)` tokens in `permissions.allow`/`deny` (`Mcp(datadog:)`, `Mcp(:search)`, `Mcp(:)`).
- **Codex** `<certain>` — `[mcp_servers.<name>]` → `enabled_tools` (allowlist) / `disabled_tools` (denylist), plus `tools.<tool>.approval_mode` (`auto`|`prompt`|`approve`) and `default_tools_approval_mode` (`config-reference`).
- **Copilot** `<certain>` — per-MCP-server `tools` field in `~/.copilot/mcp-config.json` controls exposure (`["*"]` = all; a named list restricts) (`copilot-cli-permissions-raw.md:57-72`). Plus `~/.copilot/settings.json` `disabledMcpServers`/`enabledMcpServers`.

**Lever-3 reach:** all five — but `ap` renders MCP scoping for **none of them** as a dedicated channel today (Claude/opencode/Cursor would get it for free once their Lever-1 renderers carry MCP rules; Codex `enabled/disabled_tools` and Copilot `tools:[]` are net-new renderer work).

---

## What `ap` renders today

Native capability (above) is not the same as what `ap` lowers. Current render state per lever:

| Harness | Lever 1 (per-command rules) | Lever 2 (posture) | Lever 3 (MCP scoping) | File written |
|---|:---:|:---:|:---:|---|
| **Claude** (install) | ✅ allow only † | ✗ | via Lever 1 | `.claude/plugins/local/<profile>/settings.json` |
| **Claude** (isolated) | ✅ allow **+** deny | ✅ `--setting-sources ""` + `--tools` | via Lever 1 | ephemeral `settings.json` |
| **opencode** | ✅ allow **+** deny (#259) ‡ | partial (default action) | via Lever 1 | `opencode.json` `permission` |
| **Cursor** | ✗ warned + dropped | ✗ | ✗ | — |
| **Codex** | ✗ not rendered (`.rules` renderable) | ✗ not rendered | ✗ not rendered (`enabled/disabled_tools`) | — |
| **Copilot** | ✗ not rendered (launch-flag wrapper) | ✗ | ✗ not rendered (`tools:[]`) | — |

† Claude install writes plugin-scoped `permissions.allow` if non-empty (`claude.py:472-484`); the live root `settings.json` merge never touches permissions. Deny is written only on the isolated launch path (`overlay.py`).
‡ Pre-#259 the opencode renderer (`_translate_permission`, `opencode.py`) emitted bash-allow-only — it mapped `Bash(cmd:*)` → `cmd *` and passed everything else through into `permission.bash`. #259 adds the `settings.permissions_deny` parse channel and translates the full Claude vocabulary into opencode's per-tool `permission` map (last-match-wins, deny emitted last for deny-wins parity).

Net *today*: a profile's per-command rules reach **Claude** (full) and **opencode** (full, post-#259); Cursor drops them (renderer assumes UI-only, `cursor.py:117-124`). Codex and Copilot render nothing yet — not because the surface is missing (Codex's `.rules` file and Copilot's launch flags can both carry per-command rules) but because the renderers/wrapper aren't built. Posture and MCP-scoping are largely unrendered everywhere.

## Planned fixes & remaining gaps

1. **Cursor warn-and-drop → CLI render.** The renderer assumes UI-only — true for the *IDE*, but `cursor-agent` consumes declarative `permissions.allow`/`deny` from `~/.cursor/cli-config.json`. Spec: **`.cheese/specs/ap-cursor-cli-permissions.md`** — adds `_write_cli_config`, translates Claude rules → Cursor tokens (`Bash(cmd:*)`→`Shell(cmd:)`, `Edit`→`Write`, `mcp__s__t`→`Mcp(s:t)`). Harmless if only the IDE is used (the file is read solely by the CLI). Unblocked by #259's parse channel; not yet cooked.
2. **opencode full-fidelity render — shipped in #259** (in review). Adds the `settings.permissions_deny` union-merge in `parse.py` and the full per-tool translation. This is the shared dependency the other render specs lean on.
3. **Claude `settings.permissions_deny` not consumed (future).** With the parse channel live, the claude *install* renderer could also write `permissions.deny` (it only writes `allow` today). Out of scope of the two render specs; noted so it isn't forgotten.
4. **Codex posture renderer (net-new, Lever 2).** `sandbox_mode` + `approval_policy` (incl. the `granular` form) are static `config.toml` keys `ap` doesn't target. An isolated read-only profile should lower to `sandbox_mode = read-only` + `approval_policy = untrusted`.
5. **MCP-scoping renderers for Codex + Copilot (net-new, Lever 3).** Codex `enabled_tools`/`disabled_tools` and Copilot `mcp-config.json` `tools:[]`. `ap` emits neither.
6. **Codex per-command renderer (net-new, Lever 1).** Lower the canonical `Bash(…)` rules to `prefix_rule()` entries in `ap`'s own `~/.codex/rules/ap-canonical.rules` (decision `allow`/`forbidden`), leaving the TUI's `default.rules` untouched.
7. **Copilot per-command launch wrapper (net-new, Lever 1).** A `copilot` launch wrapper injecting `--allow-tool`/`--deny-tool` from the canonical lists — the only way to reach Copilot's flags-only per-command surface from a declared profile.

The through-line for a canonical permission model: **no single channel reaches all five harnesses, but every lever can reach every harness it applies to — through a different surface.** Declare once, *lower per-lever onto each harness's surface*: per-command rules → Claude/opencode/Cursor configs + Codex `.rules` + Copilot launch flags (all five); posture → Codex / Claude / opencode / Cursor; MCP scoping → all five. That per-surface lowering, plus reconciliation with the `create_settings.json` Claude seed, is the work the canonical allow/disallow-list spec has to design.

## Provenance

Native-model facts extracted via `/briesearch` (2026-06-02) from each vendor's official docs (URLs cited inline); the deep Cursor CLI grammar in `.cheese/research/harness-perms/cursor-cli-permissions.md`, other raw bodies under `.cheese/research/harness-perms/raw/`. `ap` mapping + the render specs grounded by reading `agent_profile/renderers/*.py` + `overlay.py` + `parse.py` (file:line in the specs). Codex correction (`478705f`) replaced the false "Codex has no static config permission surface" framing; a further correction (this session) establishes that per-command rules reach **all five** harnesses — Codex via its renderable execpolicy `.rules` file and Copilot via launch-flag injection — not just the three with config-file surfaces.

See also [[agent-profile]] · [[config-drift]] · [[../harnesses/claude]] · [[../harnesses/cursor]] · [[../harnesses/opencode]]
