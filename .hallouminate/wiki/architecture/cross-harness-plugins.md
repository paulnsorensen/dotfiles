# Cross-harness plugin support

A **plugin** in `ap` is a meta-item: at ingest time `ap` decomposes it into
its bundled primitives (MCP server(s), skills, agents, commands, hooks) and
feeds each into the **existing** per-harness renderers. No new renderer is
introduced; a decomposed plugin item is indistinguishable from a
registry-native item downstream.

This is distinct from the `global@local` profile-as-plugin track (where a
profile dir IS a Claude plugin dir). Cross-harness plugins add a 5th registry
(`agents/plugins/registry.yaml`) that any harness can consume.

---

## The decomposer seam: `ingest._expand_plugins`

`expand_registries()` in `agent-profile/agent_profile/ingest.py` wires in
`_expand_plugins()` after the other four readers. Per plugin entry, the
decomposer:

1. Resolves the plugin **payload root** (`path:` in the registry; supports
   `~/`, absolute, or repo-relative).
2. Reads `.mcp.json` → MCP item(s), carrying the entry's `harnesses` and
   `gate_unless`.
3. Walks `skills/<n>/SKILL.md` → `path:` skill items (one per named skill
   dir, skipping any subdir that lacks `SKILL.md` — e.g. `references/`).
4. Stamps every emitted item's `_source_dir` **at the plugin payload root**.

### The critical `_source_dir` rule

Every renderer resolves payload files via:

```python
Path(item["_source_dir"]) / item["path"]
```

`_source_dir` MUST be the plugin payload root, not the dotfiles repo root.
Mis-stamping silently copies from the wrong tree. This is the single most
common failure mode and is unit-tested explicitly:
`test_ingest_plugins.py::test_source_dir_is_payload_root_not_repo_root` proves
it fails under repo-root stamping.

---

## Registry schema (`agents/plugins/registry.yaml`)

```yaml
plugins:
  <name>:
    path: ~/Dev/myplugin/plugins/myplugin   # payload root
    harnesses: [claude, codex, opencode, cursor, copilot, crush]
    claude_native: true   # Claude gets native marketplace install
    gate_unless: MY_ENV_VAR   # optional gate
    description: Human-readable description
```

**`harnesses`** — explicit MCP membership list. Deliberate: blanket-wide
membership taxes every per-request MCP-schema token budget. See
[[architecture/mcp-secret-handling]] for the token-cost tradeoff and
[[architecture/agent-profile]] for how harnesses membership flows.

**`claude_native`** — when `true`, the decomposer also produces a
`native_plugins` record so the claude renderer can register the plugin's own
marketplace. When `false` (or omitted), Claude receives decomposed primitives
like all other harnesses.

**`gate_unless`** — propagates to the decomposed MCP's `gate_unless` field,
using the same semantics as the MCP registry gate (see [[agents-dir]]).

---

## Per-harness reach

| Harness | Receives | Loses |
|---|---|---|
| claude | native marketplace install — full plugin | nothing |
| codex | MCP + skills + hooks | custom `/commands` (WARN+skip) |
| opencode | MCP + skills + agents | hooks, atomic install |
| cursor | MCP + skills + agents + commands + hooks | — |
| copilot | skills + hooks + agents; MCP only if `harnesses` includes copilot | custom `/commands` (WARN+skip) |
| crush | MCP only | all non-MCP primitives |

---

## The hybrid decision: Claude native + decompose rest

Claude Code has a native plugin system (marketplace install, plugin-scoped
`mcp__plugin_<name>_<server>__*` tool names, plugin-owned commands/hooks). The
other harnesses have no equivalent atomic install — they only accept
primitives via their config renderers.

The chosen model: Claude gets the native install for `claude_native: true`
entries; every other harness gets decomposed primitives via the existing
renderers. No renderer changes are needed for the decomposed path.

For entries with `claude_native: false`, Claude also receives decomposed
primitives. This is the right choice when a plugin's marketplace.json is
absent or the plugin is not ready for the marketplace.

---

## Relationship to retired `sync.sh`

`claude/plugins/sync.sh` is **retired**. Its marketplace-registration and
`enabledPlugins` logic for `claude_native` entries moves into the `ap` ingest
layer (`native_plugins` list). The `plugin-sync` alias now points to
`dots profile install base`; `plugin-edit` points to
`agents/plugins/registry.yaml`.

The `claude/plugins/registry.yaml` file remains for Claude-only official
marketplace plugins (playwright, claude-md-management, etc.) that have no
cross-harness payload. The cross-harness registry (`agents/plugins/`) is the
SSOT for any plugin that should reach non-Claude harnesses.

---

## Membership and the per-request MCP token tax

Every MCP in a harness's config is loaded at startup and its schema is
fetched per request. Blanket-wide membership (all harnesses for every plugin)
would tax every request with the plugin's tool schemas even when the user
is not using the plugin. Explicit `harnesses:` lists in the registry keep
this deliberate. See [[architecture/mcp-secret-handling]] for how schema
loading interacts with secret passthrough.

---

## Gotchas

- **`_source_dir` mis-stamping** — must be the payload root. The unit test
  explicitly proves the failure mode. If you see a renderer failing to find
  a skill file, check `_source_dir` on the item first.
- **Dev-path `.mcp.json`** — plugin payloads under development often use
  `--from /path/to/dev/repo` in their `.mcp.json`. This must be replaced
  with the portable `uvx <package>` form before the plugin can be used on
  other machines. The milknado migration (`fix/mcp-portable-uvx`) is the
  reference example.
- **Skill-name collisions** — `expand_registries` raises `ParseError` if a
  plugin skill name collides with an existing registry skill. The error is
  intentional: silent overwrite of the shared skill tree is Rule 9.
- **`clean`/uninstall ref-counting** — decomposed items land in shared/merged
  files (opencode.json, .cursor/mcp.json) and shared skill trees. `clean()`
  must attribute items to the plugin so uninstalling one plugin doesn't strip
  another's contributions. The renderers handle this via their existing
  surgical-removal logic.
- **marketplace-add CLI prime** — for `claude_native` entries, writing
  `extraKnownMarketplaces` alone is not enough. The `claude plugin marketplace
  add <abs>` CLI call primes the resolution cache. Without it, a freshly-added
  local plugin fails to install on first sync. The `_write_local_marketplace`
  method handles this.

---

## Worked example: milknado

**Payload root:** `~/Dev/milknado/plugins/milknado`

**Payload structure:**
```
.mcp.json                         ← {command: uvx, args: [milknado-mcp]}
.claude-plugin/marketplace.json   ← Claude native manifest
skills/
  harvest/SKILL.md
  load-roadmap/SKILL.md
  milknado-config/
    SKILL.md
    references/flavor-presets.md  ← subfile; NOT a skill itself
```

**Registry entry:**
```yaml
milknado:
  path: ~/Dev/milknado/plugins/milknado
  harnesses: [claude, codex, opencode, cursor, copilot, crush]
  claude_native: true
  description: Mikado execution engine — goal decomposition, batch planning, detached ralph-loop runs
```

**What `_expand_plugins` emits:**
- 1 MCP item: `{name: milknado, command: uvx, args: [milknado-mcp], harnesses: [...], _source_dir: <payload>}`
- 3 skill items: `harvest`, `load-roadmap`, `milknado-config` each with `_source_dir: <payload>` and `path: skills/<name>`
- 1 native_plugins descriptor for the claude renderer

**PyPI dependency:** `uvx milknado-mcp` requires milknado to be published to
PyPI. Until then, the rendered config references the portable form but the MCP
will not launch. Publishing is a separate milknado release step.

---

## Cross-links

- [[architecture/agents-dir]] — `agents/plugins/` as the 5th registry
- [[architecture/agent-profile]] — decomposer in the ingest layer
- [[architecture/mcp-secret-handling]] — MCP membership token cost
- [[operations/dev-environment]] — Claude marketplace section (sync.sh retired)
