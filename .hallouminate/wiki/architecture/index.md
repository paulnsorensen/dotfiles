# Architecture

How this dotfiles repo configures AI coding agents: shared registries rendered by `ap` where schemas align, plus native chezmoi registries where a harness needs first-class ownership.

- [[agents-dir]] — the `agents/` registry system: MCP / hook / sub-agent / skill registries, the system-prompt body, and the shared cheese-flair assets. Declares *what* every agent gets.
- [[global-agents-doc]] — the `agents/AGENTS.md` global agent doc deployed to Claude, Codex, and Pi, with routing detail kept in the system-prompt layer.
- [[agent-profile]] — the `ap` tool (`agent-profile/`): profiles, the four render targets (`claude`, `codex`, `cursor`, `copilot`), install vs launch, and the chezmoi drive path. OMP and Pi deliberately live outside this compiler.
- [[cross-harness-plugins]] — the 5th registry (`agents/plugins/registry.yaml`): how `ap`'s `_expand_plugins` decomposes a plugin into MCP / skill / agent / hook primitives, the native-vs-decomposed install split and DEDUP, and the marketplace-root vs payload-root path model.
- [[agent-vs-skill-tiering]] — when a behaviour earns a sub-agent vs a skill (the two axes: isolation, detect-vs-fix), the cross-repo ownership constraint (dotfiles agents ↔ easy-cheese skills), the self-filter-vs-wire-protocol scoring rule, and the deferred cheese-agent cleanup backlog.
- [[subagent-turn-budgets]] — the measured turn and context distributions behind the `maxTurns` caps (PR #344): per-agent p50/p90/p95/max, the 120K "dumb zone" crossing data (a sub-agent caps credit burn, not context quality), and why built-in agents (`general-purpose`/`Explore`/`Plan`) sit outside the cap's reach.
- [[harness-permissions]] — the four `ap` targets' native permission models, the three orthogonal levers, current lowering paths, and remaining Cursor/Codex/Copilot gaps.
- [[mcp-secret-handling]] — the current secret model: managed MCP credentials never reach the daily user or any harness config. Each credential-bearing managed entry launches `agent-secret-proxy` against a fixed per-consumer socket; a root-owned broker holds the credential, enforces the tool ceiling, and gates writes behind an operator nonce. (Supersedes the retired `${VAR}`/`envFile` passthrough design — no managed entry has a credential delivery channel any more.)
  - [[agent-secret-isolation-001]] — ADR: put reusable credentials behind per-consumer *system* identities, not a same-UID cache, keychain, or user service.
  - [[agent-secret-isolation-002]] — ADR: authorize provider operations in a local MCP firewall (secretless stdio proxy, policy-filtered `tools/list`/`tools/call`) rather than hosted OAuth or profile-only allowlists.
  - [[agent-secret-isolation-003]] — ADR: move mutation approval off the agent's own terminal onto an operator-only control socket, bound to consumer+tool+canonical args+nonce with a 60s one-shot expiry.
- [[cc-launch-env]] — `bin/cc-env-exec`, the launch-time wrapper that reloads non-secret `.env` settings into tmux-spawned Claude launches *and scrubs retired credential names plus the obsolete user secret cache* (and the argv-visibility reason it isn't `tmux new-session -e`).
- [[mcp-schema-loading]] — why MCP membership is a per-request token-budget lever: Claude defers schemas while Codex, Cursor, and Copilot eagerly load them.
- [[config-drift]] — why live harness config can diverge from generated state, the drift classes, and harness-doctor repair paths.
- [[cross-harness-guards]] — the git-guard adapters for Claude, Codex, Cursor, and Copilot plus the Claude-only sensitive-file guard.
- [[adr-chezmoi-authoritative-claude]] — the ADR series behind chezmoi-authoritative global Claude config: retiring `ap` from live installs, the forked `claude.yaml` registry, MCPs via the `claude mcp` CLI + manifest, and `exact_` dirs + wholesale settings-key authorship.
- [[codex-first-class-review]] — Codex first-class fixes: user-level hook command resolution, hook-health diagnostics in `harness-doctor`, isolated Codex profile projection, MCP tool-scope cleanup, and the remaining `PreToolUse` matcher-verification gap.
- [[chezmoi-authoritative-codex]] — the Codex counterpart to the Claude ADR series: `~/.codex` converges on `dots sync` from `codex.yaml` + `private_dot_codex/`, why `config.toml` is *merged* (the CLI writes its own runtime state into the same file) while `mcp_servers` is replaced wholesale, and the chezmoi attribute-order / `private_` gotchas.

## Routing and orchestration doctrine

- [[subagent-routing-policy]] — "discover, then commit": never ask a cheap worker to judge its own capability; gather bounded facts, let a deterministic policy pick the route, and spend frontier tokens only at serial bottlenecks (the shared plan, the fresh-context review).
- [[fanout-fanin-discipline]] — the *how* to [[subagent-routing-policy]]'s *whether*: the wall-clock-vs-token economics of a fan-out, and why parallelism buys latency rather than lower total spend.
- [[knowledge-graph-playbook]] — digest of the Anthropic KG/multi-agent playbook, kept for the doctrine that transfers here: stage-tiered model selection, shared memory over an orchestrator bottleneck, grounded evaluation, unattended-loop discipline.
- [[omp-agent-model-effort]] — the workload→model/effort table for OMP-native agents, and the rule that registry `effort` is Claude-only and must never be mirrored into OMP frontmatter.

## Profiles and workflows

- [[oss-docs-profile]] — the isolated `oss-docs` profile: what it supplies (code nav, grounding, current docs, browser verification), what it deliberately leaves to the target project, and the `cdp oss-docs` shortcut.
- [[review-profile-write-deny]] — the `review` profile must deny `MultiEdit` explicitly: Claude names it separately, so denying `Edit`/`Write` does not cover it.
- [[saved-workflows]] — `claude/workflows/*.js` is the source; `chezmoi/dot_claude/exact_workflows/` is a gitignored assembled artifact. The whole dir syncs, so no registry entry is needed.
- [[move-my-cheese-workflow]] — the incremental PR-age marker workflow: why convoy's combine/consolidate phases were dropped (background runs cannot pause for an approval gate) and why the marker is a PR comment rather than a git note.

## Conventions and retirements

- [[sourced-shell-libraries]] — the `bin/lib/*.sh` + `.sync-lib.sh` contract: no top-level side effects, including strict mode. Learned the hard way in PR #580.
- [[serena-retirement]] — Serena is no longer installed, configured, or exposed as an MCP; tilth is the sole code-intelligence MCP. Usage data behind the call is on the page. **Any surviving Serena reference elsewhere in this wiki is historical, not routing guidance.**

For the harness-specific consumption (and official upstream docs for each native config surface), see [[../harnesses/index]]. For the operational plumbing (sync, chezmoi, local-llm, dev environment), see [[../operations/index]].
