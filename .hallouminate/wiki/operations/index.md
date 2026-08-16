# Operations

The repo's operational plumbing — the machinery that deploys config and the local dev environment, as opposed to [[../architecture/index]] (the agent-config system) and [[../harnesses/index]] (per-harness wiring).

- [[local-llm]] — the opt-in local-LLM stack: llama.cpp workers behind a LiteLLM proxy, the `localLLM` chezmoi gate, what's managed vs. runtime-only, and the `llm-*` commands.
- [[sync-and-chezmoi]] — how `dots sync` deploys (the symlink + `.sync` system, `SYNC_SKIP_LIST`, `bin/` PATH-from-clone), the chezmoi-managed subset, and the "shell functions need tests" convention.
- [[claude-dotfiles-ownership]] — treating `~/.claude/` as a runtime tree with repo-owned inputs: the settings scope model, the `modify_settings.json` merge/ownership policy, and the provenance-aware destructive-cleanup rule.
- [[rtk-diff-false-drift]] — why the rtk `diff`→`git diff` rewrite can report false file drift (a `~/.gitattributes` symlink error makes the command exit non-zero regardless of file equality), and to compare with `shasum`/`cmp` instead.
- [[dev-environment]] — git tooling (difftastic, mergiraf, the conflict-resolution chain), prek pre-commit hooks, Claude marketplace plugins, and skhd.
- [[tmux-plugin-gotchas]] — tmux plugin wiring: why continuum silently disarms when `status-right` is rewritten after TPM runs, the required plugin declaration order, catppuccin palette injection via `theme/generate.sh`, and the live vs. repo plugin tree.
- [[remote-access]] — the remote-shell stack: Tailscale mesh transport → mosh (UDP, survives roaming/sleep) → tmux session persistence, the `mtmux` wrapper, and why Tailscale stays a manual install under the Homebrew-on-Linux package model.

- [[subagent-dispatch-analytics]] — measured behaviour of the phase agents across 578 real runs: dispatch size (not detail) drives the coder's 37% out-of-context rate, line anchors don't rescue an oversized dispatch, ~40% of the coder's budget goes to pre-write exploration, and the tool-reroute hook catches under 8% of the shell searches it targets. Query pack in `references/subagent-runs.md`.

- [[omp-config-shape-drift]] — unknown-key gate tripping on nested `dev.autoqa.*` means a stale per-machine config serialization: normalize with an `omp config set` re-save; never fold the nested shape into the shared registry (the #487 flip-flop).
- [[omp-fanout-worker-models]] — OMP fan-out guardrails and evidence-dated worker-model cost research: separate parent reasoning from cheap worker roles, bound task fan-out, and treat speed rankings as provisional until measured locally.

- [[bitwarden-secrets-manager]] — the Bitwarden provider runbook behind `bin/vault-provision`: the exact three-Secret inventory, why records are created in the web application rather than via `bws secret create`, the single-line constraint the env-output fetch imposes, least-privilege machine account, root-shell access-token boundary, and key rotation.

## Repo-local traps

- [[git-stash-hygiene]] — the dotfiles tree carries unrelated WIP stashes, so a bare `git stash pop` applies someone else's WIP; pop only your own stash by exact ref, and untracked files don't stash via pathspec.
- [[just-check-claude-guard-flake]] — `just check` test 349 (claude-wrapper.bats) fails purely because ≥8 Claude sessions are running (the launcher guard), not because of the diff; confirm with `pgrep -cx claude` and rerun under `CLAUDE_GUARD=0`.
- [[cloud-routines-location]] — the five Claude Code cloud routines live in the private `paulnsorensen/routines` repo, not in dotfiles/tilth; edit them there.

## Packaging and machine state

- [[brew-machine-prune]] — the machine-side half of [[../adr/manifest-pinned-packages]]: `sync_brew` never uninstalls, so strays accumulate until pruned by hand. Read before pruning — `rustup` and `mise` must stay in brew (mise's `rust` is a symlink into rustup's tree; mise itself is the bootstrap trust root).
- [[mise-aqua-backend-retypes]] — an aqua-registry package retype breaks a working pin with no version change; the fix is a backend migration, not a version bump.
- [[rectangle-sync]] — why `rectangle/.sync` needs a hash stamp: it used to hard-restart Rectangle Pro on every `dots sync`, and SIGKILL leaves no crash report, so "the app keeps crashing" had no diagnostic trail.

## Measurement and prompting

- [[test-suite-performance]] — the Bats suite is dominated by repeated integration setup, not runner parallelism; keep the CPU-count default and shorten the work inside tests instead of tuning job count.
- [[prompting-claude-opus-5]] — the Opus 5 behaviour deltas that actually change decisions here: model-tier pins, review fan-out sizing, verification scaffolding, delegation restraint.
