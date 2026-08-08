# Agent profile engine

The reusable profile engine lives in cheese-flow's `cheese_flow.profiles` domain. Dotfiles keeps personal profile definitions and thin operator surfaces; cheese-flow owns reusable parsing, include and registry resolution, validation, renderers, compilation, apply/reconcile, launch policy, and project-permission projection.

## Ownership

### Cheese-flow

- `cheese_flow.profiles` is the reusable engine and public Python API.
- It accepts an explicit profile source root and immutable environment mapping.
- It owns profile resolution, harness renderers, schema-v1 compile publications, apply recovery, launch policy, and project-permission rendering.
- It performs no dotfiles, home-directory, working-directory, vault, or cache discovery.

### Dotfiles

- `profiles/` contains personal profile YAML, bodies, registries, and other source inputs.
- `bin/dots`, shell wrappers, and `claude/` provide the operator-facing delegation and documentation.
- Vault preparation and cache preparation remain dotfiles concerns.
- `packages/packages.yaml` pins the exact cheese-flow revision before profile commands are used.

## Current command surface

The supported profile commands are:

```text
cheese profile list --source-root PATH
cheese profile describe NAME --source-root PATH
cheese profile compile NAME --source-root PATH --baseline PATH --output PATH
cheese profile apply MANIFEST [--state PATH]
cheese profile launch HARNESS NAME --source-root PATH -- [ARG ...]
cheese profile permissions --project-root PATH [--local] [--harness NAME ...]
```

`list`, `describe`, `compile`, and `launch` inspect the caller-supplied source root. `apply` receives only the immutable manifest and optional state path. `permissions` reads the fixed project-local permission fragment beneath the explicit project root.

## Source-root and environment contract

The engine resolves profiles only beneath the explicit source root. It rejects traversal and symlink escapes before reading outside that root, and it reads only declared registries and profile inputs. Environment values are supplied by the caller; the engine does not consult `DOTFILES_DIR`, the current working directory, `.env`, vaults, or caches.

## Compilation and apply

Compilation renders into a private stage under the caller-owned output root. The published schema-v1 manifest binds ordered fragment records, destinations, drift, and hashes to a lowercase SHA-256 generation under `generations/<generation>/`. Failed compilation leaves the prior publication usable, and generation cleanup remains the caller's responsibility.

Apply validates the complete immutable generation before mutating a target. It uses an exclusive state lock, atomic per-file replacement, bounded stale ownership deletion, schema-v1 ownership state, and a private journal with `prepared`, `files_written`, and `stale_deleted` phases. Recovery completes the journaled transaction before accepting another manifest and never deletes an unowned path.

## Launch and project permissions

Launch builds a complete immutable, secret-safe `LaunchSpec` before exec. It validates profile policy and caller arguments, creates an ephemeral overlay only for isolated profiles, performs no persistent deployment writes, and removes a newly created workspace if exec fails. Copilot policy flags supplied by callers are rejected before exec.

Project permissions reads only `<project-root>/.agent-profiles/_permissions/profile.yaml`. It validates every selected harness output before the first write, supports Claude and Codex, reports exact written and skipped paths, and preserves the `--local` Claude-personal-settings behavior.

## Harness and source conventions

Compile and launch support the closed set `claude`, `codex`, `copilot`, `crush`, `cursor`, and `opencode`. Isolated launch support is limited to `claude`, `codex`, and `opencode`; project permissions support is limited to `claude` and `codex`. Personal registries and payload bodies stay in dotfiles, while renderer behavior and validation stay in cheese-flow.

## Migration provenance

The approved extraction and follow-up hardening are pinned at cheese-flow revision `862d8176cb5e87fc557e30c995fc8b2c7d49270d`. ADR-001 through ADR-005 record the ownership boundary, immutable generations, journaled apply, launch policy, and exact pinned cutover, with source citations that preserve the original implementation history. Historical wiki, ADR, issue, and one-time migration evidence remains unchanged; this page describes only the current supported surfaces.
