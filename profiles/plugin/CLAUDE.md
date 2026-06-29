# Plugin Dev Profile

This session is for building and iterating on Claude Code plugins. Plugins live in `claude/plugins/local/<name>/` (local dev) or are installed via the registry at `claude/plugins/registry.yaml`.

## Why this profile exists

Plugin dev needs heavy reference material (plugin SDK, hook events, MCP protocol, skill triggering rules) and cross-referencing against other plugins. This profile trims to navigation + external docs for plugin authoring.

## MCPs in scope

Defined in `mcp-scope.yaml` (registry-validated):

- **tilth** — `mcp__tilth__*` — AST-aware navigation inside `claude/plugins/` and cross-plugin symbol lookup.
- **context7** — `mcp__context7__*` — Claude Code plugin SDK, MCP spec, and related framework docs.
- **hallouminate** — `mcp__hallouminate__*` — per-repo markdown wiki: semantic search + LLM-authored notes for grounding plugin design decisions.

For reference plugin implementations, use `gh search code` directly or via the `/gh` skill.

## Working standards

- **Read before you write.** Read the plugin's manifest, existing skills, and hooks before changing wiring.
- **Smallest change that satisfies the ask.** No speculative scaffolding; every changed line traces to the request.
- **Calibrate claims.** Tag opinions `<certain>` / `<speculative>` / `<don't know>`.
- **Don't fake completion.** Test skills by actually invoking them before declaring done.
- **Be succinct.** Answer → minimal support → stop.
- **Use tilth (`mcp__tilth__*`)** for reading and searching inside `claude/plugins/`.

## Preferred skills

| Task | Skill |
|------|-------|
| New plugin from scratch | `/plugin-dev:create-plugin` |
| Add a command to a plugin | `/plugin-dev:command-development` |
| Add a hook | `/plugin-dev:hook-development` |
| Add an agent | `/plugin-dev:agent-development` |
| Add a skill | `/plugin-dev:skill-development` or `/skill-creator:skill-creator` |
| Wire up MCP | `/plugin-dev:mcp-integration` |
| Plugin file/manifest layout | `/plugin-dev:plugin-structure` |
| settings.json knobs | `/plugin-dev:plugin-settings` |
| Validate before shipping | `plugin-validator` agent |
| Review a skill's quality | `skill-reviewer` agent |

## Workflow

1. For new plugins, start with `/plugin-dev:create-plugin` — it scaffolds the manifest + directory shape.
2. After changes: run `plugin-validator` agent before claiming done.
3. Iterate locally: `ln -s $(pwd) ~/.claude/plugins/marketplaces/local/<name>` so Claude sees it without a publish cycle.
4. When stable, add to `claude/plugins/registry.yaml`, then `plugin-sync`.
5. Restart Claude Code after registry changes — plugin list is cached at startup.

## Defaults

- **Manifest-driven.** `plugin.json` is the contract. Never ship without it; `plugin-validator` will reject.
- **Skills over agents** unless the task needs sub-agent nesting (Claude Code only supports 1 level of sub-agent nesting, so orchestrators must be skills).
- **Descriptions matter.** Skill/agent triggering is description-driven — weak descriptions mean the skill never fires. Run `skill-reviewer` on fresh skills.
- **MCP tools in permissions.** If a plugin provides MCP tools, add `mcp__plugin_<name>__*` to `permissions.allow` in the user settings.
- **Scope your hooks.** PreToolUse hooks that match `*` are easy to misuse — scope by tool name.

## Hard constraints

- Don't hand-edit `~/.claude/plugins/` — that's Claude's cache. Work in the dotfiles repo and `dots sync`.
- The plugins directory is **not** symlinked via `.sync` (Claude uses it as cache); the registry is the source of truth.
- Test skills by actually invoking them (`Skill` tool) before declaring done — a "looks right" skill that never triggers is worthless.
