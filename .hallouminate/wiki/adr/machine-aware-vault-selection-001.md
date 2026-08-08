# ADR-001 — Resolve vault providers by explicit intent or unique readiness

Status: accepted

Related spec: `/Users/paul/.local/share/cheese/paulnsorensen-dotfiles/specs/machine-aware-vault-selection.md`.

## Context

`vault_detect` currently treats executable presence as availability and always prefers `op`. The committed 1Password references also assume `op://Private/dotfiles`. On the work laptop, `op` 2.38.1 can list the `Employee` vault while `Private` is absent and `bws` is not installed. `op account get` and vault/item commands work through desktop integration even though `op whoami` reports no signed-in account, so executable presence and `whoami` are both insufficient readiness tests.

## Decision

Replace `vault_detect` and `vault_provisioned` with a clean resolver cutover. Machine-local `.env` accepts `DOTFILES_VAULT_PROVIDER=auto|onepassword|bitwarden` and `DOTFILES_OP_ITEM=op://<vault>/<item>`, defaulting to `auto` and `op://Private/dotfiles`.

An explicit provider is authoritative: missing executable, configuration, authentication, vault, or item is an error and never triggers fallback. In `auto`, exactly one ready provider is selected, two ready providers are an ambiguity error, and zero ready providers is the non-failing bootstrap-unconfigured state. 1Password readiness is exact configured-item metadata access, not `op whoami`; Bitwarden readiness is executable, project ID, and token availability.

Package intent is a separate predicate: explicit `onepassword` suppresses `bws`, explicit `bitwarden` enables it, and `auto` preserves the existing executable-presence gate so transient authentication cannot cause package churn.

## Alternatives

- Keep executable-first detection: lowest complexity, but selects an inaccessible hardcoded item on this work account and silently changes behavior when another CLI appears.
- Hardcode `Employee/dotfiles`: fixes one laptop while breaking the personal default.
- Require explicit settings on every machine: deterministic, but removes useful zero-config behavior.
- Select the first currently available provider: hides ambiguity and makes transient readiness alter provider choice.

## Consequences

The work laptop can set `DOTFILES_VAULT_PROVIDER=onepassword` and `DOTFILES_OP_ITEM=op://Employee/dotfiles`; personal machines retain the `Private/dotfiles` default. Machines with both providers ready must choose explicitly. Auto mode probes both providers, while explicit mode probes only the selected provider. `vault_resolve` and `vault_disables_bitwarden_install` remain the provider-selection APIs. Credential materialization and `vault_secrets_file` were superseded by the privileged per-consumer broker design in [[../architecture/agent-secret-isolation-001]].

Sources: `bin/lib/vault.sh`; `.sync`; `.env.example`; [1Password item commands](https://www.1password.dev/cli/reference/management-commands/item); [1Password desktop integration](https://www.1password.dev/cli/app-integration).
