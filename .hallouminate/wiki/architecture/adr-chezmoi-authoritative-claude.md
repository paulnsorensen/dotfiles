# ADRs: chezmoi-authoritative global Claude config

Decision series from the `chezmoi-authoritative-claude` spec (/mold session,
2026-07-01). Spec: `~/.local/share/cheese/paulnsorensen-dotfiles/specs/chezmoi-authoritative-claude.md`.
Research: `.cheese/research/chezmoi-claude-authoritative/chezmoi-claude-authoritative.md`.
Related: [[architecture/agent-profile]], [[operations/sync-and-chezmoi]].

## ADR-001: Retire agent-profile from all live installs [status: accepted]

- **Context:** Live `~/.claude` was deployed by a three-way split (chezmoi,
  `ap`, `claude/.sync`). Overwrites worked but deletions didn't propagate —
  retired hooks/MCPs/plugins/skills lingered in live JSON and dirs. ap's own
  destruction handling (`_clean_legacy_settings_hooks`, `prune_mcps`,
  `_unregister_user_mcps`, commit `d8eb626`) is live code, but only covers
  ap-managed signatures, per-profile.
- **Decision:** ap no longer renders any live profile (any harness). It stays
  installed for scoped/ephemeral profiles (`ccp <name>`). `base-sync` removed.
  Claude gets a chezmoi-native replacement; other harnesses freeze as-is
  (follow-up specs).
- **Alternatives:** (a) claude-only disconnect, keep base-sync for the other
  four harnesses — rejected as a softer half-state; (b) keep ap but harden its
  pruning — rejected: the residue problem is structural (three writers, no
  single authority).
- **Consequences:** One workflow for claude (edit registry → `dots sync`).
  Codex/opencode/cursor/copilot live config stops refreshing until their
  follow-up migrations land.

## ADR-002: Claude forks to its own registry — `chezmoi/.chezmoidata/claude.yaml` [status: accepted]

- **Context:** The cross-harness `agents/` registries are the current single
  source of truth. Keeping them authoritative would require a render step
  writing into chezmoi source state on every sync.
- **Decision:** Claude gets its own registry as chezmoi template data
  (`.chezmoidata/claude.yaml`): mcps, hooks wiring, enabledPlugins,
  marketplaces, permissions, plus skill/agent selection lists.
  `modify_settings.json` and the MCP reconcile script template straight off it.
- **Alternatives:** render `agents/` registries → chezmoi source at sync time
  (one truth, chezmoi enforces) — rejected by the user in favor of a clean fork.
- **Consequences:** Adding an MCP for claude + another harness now means two
  edits (claude.yaml + agents/mcp/registry.yaml). Bought: zero coupling to ap's
  renderer, chezmoi-idiomatic data flow.

## ADR-003: MCPs via `claude mcp` CLI + manifest, not a `modify_` template [status: accepted]

- **Context:** Two sourced patterns exist for owning `mcpServers` inside
  `~/.claude.json` (a live file holding OAuth/project-state/caches):
  a `modify_dot_claude.json` chezmoi:modify-template with `setValueAtPath`
  (posquit0/dotfiles), or CLI registration. Validate cycle confirmed the
  per-project MCP-keying bug (claude-code#16728) does NOT apply locally
  (Claude 2.1.197: top-level `mcpServers`, no `~/.claude/.claude.json`).
- **Decision:** `run_onchange` script (hash of the registry mcps block)
  reconciles via `claude mcp add/remove --scope user` against a manifest at
  `~/.claude/.chezmoi-mcp-manifest`. Adopts pre-existing entries; never removes
  non-manifest entries the user added by hand (flags them instead).
- **Alternatives:** `modify_` template owning the `mcpServers` key —
  declarative, deletions free — rejected: couples to `~/.claude.json`'s exact
  layout, which Claude has changed before (#16728); the CLI survives layout
  changes.
- **Consequences:** Reconciliation is imperative (script + manifest) rather
  than declarative; needs a bats-tested lib function. Robust to Claude moving
  its MCP storage.

## ADR-004: `exact_` dirs + wholesale settings-key authorship; plugins dir untouched [status: accepted]

- **Context:** ap shipped hooks/commands inside a local plugin tree under
  `~/.claude/plugins/`, which Claude itself mutates at runtime (version cache,
  `installed_plugins.json`) — unsafe for chezmoi `exact_`.
- **Decision:** Hooks wire through the settings.json `hooks` key
  (registry-authored); skills/agents/commands/hook-scripts deploy as
  `chezmoi/exact_dot_claude/*` (apply deletes anything not in source);
  `~/.claude/plugins/` is left entirely to Claude's lifecycle. All formerly-ap
  settings keys (`hooks`, `enabledPlugins`, `extraKnownMarketplaces`,
  `permissions.*`) become registry-authored — session-granted permissions are
  wiped on next apply unless promoted to the registry (strict H1, user-chosen
  over live-preserving permissions). The `install-claude-assets.sh` manifest
  installer is retired; its collections fold into `exact_`.
- **Alternatives:** keep plugin packaging with manifest scripts (preserves
  today's shape, keeps residue risk); preserve live `permissions` extras
  (pragmatic, but reintroduces unmanaged state).
- **Consequences:** Zero residual state in managed dirs/keys; anything
  hand-dropped into an `exact_` dir is deleted on apply. ap's hook self-heal
  needs no port — wholesale `hooks` authorship subsumes it. The
  `modify_settings.json` unknown-key halt gate is retained as the safety net.
