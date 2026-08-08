# Cross-harness plugin support

A **plugin** in cheese-flow is a meta-item: profile parsing expands it into
its supported bundled primitives (MCP server(s), skills, agents, and hooks) and
feeds each into the existing per-harness renderers. No new renderer is
introduced; a decomposed plugin item is indistinguishable from a
registry-native item downstream. `commands/` are intentionally unsupported on
the decomposed path; native plugin installs may still expose native commands.

A profile directory remains a source tree, not a plugin payload. Cross-harness
plugins add a fifth registry (`agents/plugins/registry.yaml`) that any harness
can consume.

---

## Profile command ownership

cheese-flow owns the reusable profile engine and its public command set:

```text
cheese profile list --source-root PATH
cheese profile describe NAME --source-root PATH
cheese profile compile NAME --source-root PATH --baseline PATH --output PATH
cheese profile apply MANIFEST [--state PATH]
cheese profile launch HARNESS NAME --source-root PATH -- [ARG ...]
cheese profile permissions --project-root PATH [--local] [--harness NAME ...]
```

Dotfiles owns the personal profile sources and the thin `dots profile`
delegation. It supplies the explicit source root for `list`, `describe`,
`compile`, and `launch`; `apply` receives only the manifest and state path; and
`permissions` receives the caller's project root. Global harness configuration
and plugin cache preparation remain chezmoi/dotfiles responsibilities.

---

## Path model: marketplace root vs payload root

**Critical distinction** — a `path:` source resolves directly to the
marketplace root; a `git:` source resolves to the prepared
`~/.cache/cheese-flow/plugins/<name>` marketplace root. Neither source points
at the plugin payload root.

```
marketplace root:  ~/Dev/milknado/
  .claude-plugin/
    marketplace.json          ← {name: "milknado", plugins: [{source: "./plugins/milknado"}]}

payload root:      ~/Dev/milknado/plugins/milknado/
  .mcp.json                   ← {command: uvx, args: [milknado-mcp]}
  skills/
    harvest/SKILL.md
    load-roadmap/SKILL.md
    milknado-config/
      SKILL.md
      references/flavor-presets.md  ← NOT a skill
```

**What each path is used for:**

- `marketplace root` → registry `path:` field or the git cache; `extraKnownMarketplaces` path;
  `claude plugin marketplace add` argument
- `payload root` → resolved from `marketplace.json plugins[].source` relative
  to marketplace root; `_source_dir` on all emitted items; `.mcp.json`,
  `skills/`, `agents/`, and `.claude-plugin/plugin.json` hooks are read here

**Why this matters:** `claude plugin marketplace add` and `extraKnownMarketplaces`
both require the directory containing `.claude-plugin/marketplace.json`. Pointing
them at the payload root fails silently with "Marketplace file not found".

---

## The profile parser seam: `cheese_flow.profiles.parse`

`_expand_registries()` in `cheese_flow.profiles.parse` expands the plugin
registry alongside the MCP, agent, skill, and hook registries. For each plugin
entry, `_plugin_items()`:

1. Resolves `path:` directly under the explicit profile source root. If both
   `path:` and `git:` are present, `path:` takes precedence.
2. Resolves `git:` through the prepared `$HOME/.cache/cheese-flow/plugins/<name>`
   marketplace root when no local `path:` is supplied.
3. Reads `marketplace.json`, selects the `plugins[]` entry whose `name` matches
   the registry key, and resolves its `source` to the payload root relative to
   the marketplace root (or its declared `metadata.pluginRoot`). Absolute
   paths and traversal are rejected.
4. Reads `<payload>/.mcp.json` → MCP item(s), carrying the entry's `harnesses`
   and `gate_unless`.
5. Walks `<payload>/skills/<n>/SKILL.md` → `path:` skill items (one per named
  skill directory, skipping any nested directory that lacks `SKILL.md` — e.g.
  `references/`).
6. Walks `<payload>/agents/*.md` → agent items, parsing leading YAML
   frontmatter for metadata while preserving the original body file.
7. Reads `<payload>/.claude-plugin/plugin.json` hooks → registry-style hook
   items; script hooks can reach Claude/Codex/Cursor/Copilot, while literal
   command hooks can reach Claude/Codex.
8. Ignores `commands/`; there is no decomposed command primitive.
9. Stamps every emitted item's `_source_dir` **at the payload root**.

### Plugin MCP environment validation

Plugin MCP environment references are validated against the explicit caller
environment. A non-optional `${VAR}` reference that is unset is rejected;
optional servers may be dropped. Environment values are carried through as
literals (not substituted by profile parsing).

### The canonical marketplace name rule

`marketplace_name` comes from `marketplace.json["name"]`, not the registry YAML
key. When they differ (which they can), the marketplace.json name is authoritative:

- `extraKnownMarketplaces` key = `marketplace_name`
- `enabledPlugins` key = `<name>@<marketplace_name>`
- cleanup un-merges using `marketplace_name`

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

Each entry must provide a `path:` or `git:` source. If both are present,
`path:` wins; omitting both is an error:

```yaml
plugins:
  <name>:
    path: ~/Dev/myplugin               # local checkout marketplace root
    # git: https://github.com/org/repo  # prepared under ~/.cache/cheese-flow/plugins/<name>
    branch: main                        # optional metadata for git preparation

    harnesses: [claude, codex, opencode, cursor, copilot, crush]
    native: true              # native install on supported drivable harnesses
                              # ({claude, copilot}); or false / [list]
    gate_unless: MY_ENV_VAR   # optional gate
    description: Human-readable description
```

`path:` is the development-machine form and is resolved first. `git:` is the
portable form; dotfiles prepares or refreshes the shallow checkout at
`~/.cache/cheese-flow/plugins/<name>` before profile parsing uses it. The profile
engine does not consult the old package cache or discover another root.

`harnesses` is explicit primitive membership. For MCPs this remains especially
deliberate: blanket-wide membership taxes every per-request MCP-schema token
budget. For non-MCP plugin primitives, omitted `harnesses` defaults to every
harness that supports that primitive. See [[architecture/mcp-secret-handling]]
for the token-cost tradeoff.

---

## Native projection and primitive deduplication

The registry's `native` field is canonical:

- `native: false` or omitted decomposes the plugin on every selected harness.
- `native: [claude, copilot]` (or `true`, whose supported set is
  `{claude, copilot}`) keeps the native declaration on those harnesses and
  decomposes it elsewhere.
- A native plugin still contributes decomposed primitives to harnesses outside
  its native set. Native and decomposed items carry the same canonical
  permission names until renderer projection rewrites native MCP tools.
- `native` must be a subset of both the entry's `harnesses` and the supported
  native set; invalid values fail during profile parsing.

The parser stamps provenance markers on decomposed items:

```text
_from_claude_native_plugin
_from_copilot_native_plugin
```

Each per-harness renderer removes items carrying its own native marker before
writing decomposed output. Claude and Copilot therefore receive one native
plugin declaration, not a duplicate MCP/skill/agent/hook expansion. Codex,
OpenCode, Cursor, and Crush receive the decomposed primitives where their
`harnesses` membership allows them.

### Claude native projection

The Claude renderer merges each native entry's marketplace root into
`.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "milknado": {"source": {"source": "directory", "path": "<marketplace-root>"}}
  },
  "enabledPlugins": {"milknado@milknado": true}
}
```

The merge is deterministic (keys sorted), preserves unrelated settings, and
tracks the generated file for reconciliation. A native entry requires a
non-empty `marketplace_name` and `marketplace_root`; conflicts with an existing
marketplace root fail loudly.

### Copilot native projection

The Copilot renderer keeps native plugin primitives out of generated
`.github/agents`, `.github/skills`, and hook output, and rewrites permissions
for native MCP servers to the plugin-scoped tool names. Non-native entries keep
the decomposed files and canonical tool names.

### Codex and the decomposed harnesses

Codex has no native marketplace projection in this contract. It receives
decomposed MCP/skill/agent/hook primitives according to `harnesses`. OpenCode
and Cursor receive MCP/skills/agents (plus hooks where supported); Crush
receives MCP only. `commands/` never becomes a decomposed primitive.

---

## Profile isolation and global ownership

Profile compilation and launch are isolated operations: generated fragments are
written beneath the requested output root. Launch replaces the cheese process
with the harness, so harness exit never triggers automatic success or failure
cleanup; the overlay remains until its owner removes or replaces it. Neither
operation mutates global harness configuration.

The dotfiles/chezmoi layer owns global configuration and reconciliation:

- `claude/plugins/registry.yaml` controls Claude marketplace enablement.
- `agents/plugins/registry.yaml` controls cross-harness plugin sources and
  primitive membership.
- `.chezmoidata/claude.yaml` supplies global settings overlays.
- `dots sync` deploys dotfiles and prepares git-backed plugin checkouts under
  `~/.cache/cheese-flow/plugins`; it does not consult alternate cache roots.

The profile commands consume these sources but do not rewrite them. Project
profiles may opt into explicit native entries; global plugin ownership remains
with chezmoi.

---

## Synchronization relationship

The two plugin registries are intentionally disjoint:

1. `claude/plugins/registry.yaml` owns official Claude marketplace entries and
   global `enabledPlugins` state.
2. `agents/plugins/registry.yaml` owns cross-harness entries and their
   decomposed/native projection.
3. `profiles/base/profile.yaml` is the only profile that reads the registry
   files; harness-specific profiles consume the resulting items.
4. The profile engine emits deterministic fragments; dotfiles reconciliation
   applies them and removes stale claims.

No plugin is registered twice. Editing either registry followed by `dots sync`
updates its owner; profile `compile`/`apply` remains the project-scoped path.

---

## Known gotchas and invariants

### Source selection

Use a marketplace root, not a payload directory. A local `path:` wins over a
coexisting `git:` value. A git source is expected at
`~/.cache/cheese-flow/plugins/<name>` after dotfiles preparation. The engine
does not search alternate cache roots or infer an unlisted nested directory.

### Canonical names

The registry key must match `marketplace.json.plugins[].name`; the marketplace
manifest's top-level `name` remains the canonical marketplace name for native
settings and cleanup. Keep `name` and `marketplace_name` distinct when the
manifest requires it.

### Harness membership

Keep MCP `harnesses` lists narrow because every selected harness pays the MCP
schema cost. Native projection is only supported for Claude and Copilot;
Codex, OpenCode, Cursor, and Crush rely on decomposed primitives.

### Configuration surfaces

Profile sources are explicit and read-only during compile. Generated manifests
are the apply input, and reconciliation is the only mutation boundary. Do not
hand-edit generated fragments; edit the profile or registry that owns them.

---

## Worked example: milknado

Given the registry entry:

```yaml
milknado:
  git: https://github.com/paulnsorensen/milknado
  branch: main
  harnesses: [claude, codex, opencode, cursor, copilot, crush]
  native: [claude, copilot]
```

After dotfiles prepares the checkout, the profile parser reads the marketplace
root and the `milknado` payload. It emits:

- one MCP item (`milknado`, `uvx milknado-mcp`) for every selected
  decomposed harness;
- one skill item for each payload skill with `SKILL.md`;
- one agent and hook item per supported payload file;
- one native descriptor for Claude and one for Copilot, each carrying its
  canonical marketplace root and name.

Claude and Copilot suppress their duplicate decomposed items. Codex,
OpenCode, Cursor, and Crush keep the decomposed items permitted by the
`harnesses` list. A missing local `uvx milknado-mcp` install remains a runtime
dependency; publishing is a separate milknado release step.

---

## Cross-links

- [[architecture/agents-dir]] — `agents/plugins/` as the 5th registry
- [[architecture/mcp-secret-handling]] — MCP membership token cost
- [[operations/dev-environment]] — global marketplace reconciliation
