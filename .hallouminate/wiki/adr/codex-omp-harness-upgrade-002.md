# ADR-002 — Cut over to OMP's native Task schema

Status: accepted

Related spec: `/Users/paul/.local/share/cheese/paulnsorensen-dotfiles/specs/codex-omp-harness-upgrade.md`.

## Context

The managed OMP system append tells callers to pass `assignment` and `fork_turns`, and `no-fork-all.ts` blocks one value of `fork_turns`. The current OMP task interface instead accepts a batch of tasks whose brief is in each `task` field; it exposes neither obsolete field. Keeping prompt policy and an extension for a nonexistent schema teaches callers an invalid contract and creates a false safety boundary. Delegated LSP is also disabled even though local OMP agents advertise LSP.

## Decision

After verifying the installed OMP 17.2.5 Task schema, remove the `assignment` and `fork_turns` guidance, delete `no-fork-all.ts` and its dedicated test, and update the managed-extension assertion and durable OMP wiki page. Set `task.enableLsp: true`. Leave every other auto-discovered extension unchanged. Do not add a shim or replacement field mapping.

## Alternatives

- Keep the guidance and guard defensively: rejected because they enforce an API OMP does not expose.
- Translate obsolete fields in a compatibility extension: rejected because there are no managed callers requiring migration and the shim would preserve the wrong contract.
- Remove only the prompt lines: rejected because the dead extension, test, and documentation would continue to advertise the obsolete policy.

## Consequences

OMP callers receive one native Task contract, delegated workers can use LSP, and the extension surface loses a no-op guard. The deletion is gated on live 17.2.5 schema inspection and focused tests so an upstream schema change cannot silently remove a real boundary.

Sources: `chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md:49-50`; `chezmoi/dot_omp/private_agent/extensions/no-fork-all.ts`; `tests/extensions/no-fork-all.test.mjs`; `harnesses/omp.md`.
