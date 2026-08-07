# ADR-002 — Tag vault cache provenance and invalidate source changes

Status: accepted

Related spec: `/Users/paul/.local/share/cheese/paulnsorensen-dotfiles/specs/machine-aware-vault-selection.md`.

## Context

All vault consumers share `${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/secrets.env`, but the cache records only six key/value lines. Once machines can choose a provider and source item, a failed source switch could leave consumers using credentials materialized from the previous provider or item. Deleting every last-good cache on any failure would instead discard valid same-source credentials during transient outages.

## Decision

Prepend non-secret comment metadata identifying the provider and source locator to each successful cache. Keep the existing path, exact six-key schema, atomic replacement, `umask 077`, and mode 0600.

Before fetching, compare expected source identity with cache provenance. Preserve a tagged same-source cache until a replacement has been completely fetched and validated. Invalidate a cache whose source differs or whose legacy provenance is unknown before attempting the new fetch. A same-source fetch failure leaves the cache byte-for-byte intact; a failed source change leaves no old-source cache for consumers to mistake as current.

Serialize resolver and materializer cache transactions with one persistent mode-0600 advisory-lock file. On macOS, BSD `lockf -k` locks the pathname while a fresh Bash process sources the vault library and runs the complete callback. The library captures its absolute physical path when first sourced so the child remains independent of later `$PWD` changes. On Linux, including BusyBox, a bounded non-blocking `flock` loop locks descriptor 9 around the callback. The file is never unlinked, so every contender addresses the same inode; kernel locking replaces PID metadata and stale-lock reaping.

Provider adapters remain responsible for the closed schema. The 1Password adapter derives all six references from `DOTFILES_OP_ITEM` and resolves them with `op inject`; the Bitwarden adapter retains project/token fetching. Existing shell, MCP, and Python loaders continue ignoring comment lines and consume the same key/value mapping.

## Alternatives

- Preserve every cache on failure: maximizes availability but can silently serve credentials from the wrong provider or item after a configuration change.
- Delete the cache before every fetch: prevents stale credentials but throws away a valid same-source last-good cache during transient failures.
- Store provenance in a sidecar: keeps the env file pristine but introduces a second atomicity and lifecycle problem.
- Encode provider identity in the cache path: isolates sources but redesigns every downstream consumer.
- Use a custom PID, hard-link, or reaper protocol: avoids an external lock primitive but introduces owner-publication, unlink/inode, ABA, and crashed-reaper recovery races.

## Consequences

Source changes intentionally sacrifice legacy or cross-source cache availability before the new fetch succeeds. Same-source outages retain the current resilience guarantee. Provenance exposes only non-secret provider/item or project identity, never secret values. The empty advisory-lock file persists at mode 0600; this is intentional so waiters cannot split across replaced inodes. Regression coverage must assert source-change invalidation, byte-identical same-source preservation, exact key validation, comment compatibility, atomic writes, native macOS `lockf` contention, Linux/BusyBox `flock` contention, recovery after a terminated transaction's provider exits, live-owner timeout, and mode 0600.

Sources: `bin/lib/vault.sh:82-371`; `bin/lib/vault.sh:443-448`; `bin/lib/vault.sh:470-711`; `secrets/secrets.env.tmpl:1-6`; `agents/mcp/sync.sh:63-71`; `zsh/core.zsh:98-113`; `bin/cc-env-exec:19-49`; `agent-profile/agent_profile/env.py:32-46`; [1Password inject](https://www.1password.dev/cli/reference/commands/inject).
