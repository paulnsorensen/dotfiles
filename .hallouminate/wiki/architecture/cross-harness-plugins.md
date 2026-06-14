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

1. Resolves the **marketplace root** (`path:` in the registry; supports
   `~/`, absolute, or repo-relative) — the dir holding
   `.claude-plugin/marketplace.json`.
2. Reads `marketplace.json`, picks the `plugins[]` entry whose `name` matches
   the registry key, and resolves its `source` (relative to the marketplace
   root) → the **payload root**.
3. Reads `<payload>/.mcp.json` → MCP item(s), carrying the entry's `harnesses`
   and `gate_unless`.
4. Walks `<payload>/skills/<n>/SKILL.md` → `path:` skill items (one per named
   skill dir, skipping any subdir that lacks `SKILL.md` — e.g. `references/`).
5. Stamps every emitted item's `_source_dir` **at the payload root**.

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
    path: ~/Dev/myplugin   # marketplace root (holds .claude-plugin/marketplace.json)
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
using the same semantics as the MCP registry gate (see [[agents-dir]]). It
gates only the decomposed MCP items, not the Claude-native install path.

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

## Relationship to `sync.sh` (narrowed, not retired)

`claude/plugins/sync.sh` is **narrowed, not removed**. `claude/.sync` still
invokes it (`bash "$SOURCE_DIR/plugins/sync.sh" --force`) on every claude sync to
register the Claude-only official-marketplace plugins (playwright,
claude-md-management, etc.) listed in `claude/plugins/registry.yaml` — plugins
with no cross-harness payload. Do not delete that invocation: nothing else
registers those marketplaces.

What changed: any plugin that should *also* reach non-Claude harnesses now lives
in the cross-harness registry (`agents/plugins/registry.yaml`), where `ap` ingest
registers its marketplace + `enabledPlugins` via the `native_plugins` list
(`_render_native_plugins`). milknado moved out of `claude/plugins/registry.yaml`
into the cross-harness registry for exactly this reason. The two registries are
**disjoint** — no plugin appears in both, so nothing is registered twice. The
`plugin-sync` alias points to `dots profile install base`; `plugin-edit` points
to `agents/plugins/registry.yaml`.

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

**Marketplace root** (the registry `path:`): `~/Dev/milknado`

**Payload root** (from `marketplace.json` `source: ./plugins/milknado`):
`~/Dev/milknado/plugins/milknado`

**Layout:**

```
~/Dev/milknado/                       ← marketplace root = registry path:
  .claude-plugin/marketplace.json     ← {plugins: [{name: milknado, source: ./plugins/milknado}]}
  plugins/milknado/                   ← payload root (the _source_dir stamp)
    .mcp.json                         ← {command: uvx, args: [milknado-mcp]}
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
  path: ~/Dev/milknado
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
- [[operations/dev-environment]] — Claude marketplace section (sync.sh narrowed)
