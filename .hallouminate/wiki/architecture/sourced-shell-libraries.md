# Sourced shell libraries — the bin/lib contract

Applies to every `bin/lib/*.sh` and to `.sync-lib.sh`. Established the hard way
by PR #580, where violating both halves broke `dots sync` on machines where the
feature had *worked*.

## Rule 1: no top-level side effects, including strict mode

`bin/lib/resume.sh` and `bin/lib/worktree.sh` both open with
`# shellcheck shell=bash` and no shebang, and state the reason in their header:
*"Functions only — no top-level side effects, so sourcing is safe from bats
tests."*

`set -euo pipefail` in a sourced library is a top-level side effect. It arms
errexit/nounset in **the caller's shell**, and this repo instructs operators to
source libraries interactively — `bin/linux-install` and `bin/vault-provision`
both print `source bin/lib/vault.sh && vault_materialize`. A library that sets
strict mode there means the operator's next failing command or unset variable
kills their terminal.

Executables set their own strict mode (`.sync`, `agents/mcp/sync.sh`,
`bin/cc-env-exec`, `bin/vault-provision` all do); libraries must not.

**Corollary that bites:** code written *under* an inherited errexit often
relies on it silently. When removing `set -e` from a library, audit every
command whose failure was previously fatal — in `vault.sh` that was `mkdir -p`,
`chmod 600`, and `mv`, all of which would have started returning success on
failure. Each needs an explicit `|| return 1`. Removing strict mode without
that audit converts a loud bug into a silent one.

## Rule 2: never leave a `trap ... RETURN` installed

Bash's RETURN-trap scoping is not what it looks like, and three independent
reviewers each got it wrong in a different direction. The verified semantics:

- A `trap '...' RETURN` set inside a function is **global shell state**. It is
  not scoped to that function and is not cleared when it returns.
- It fires on the setting function's own return.
- It **does not** fire for functions invoked *afterwards* — RETURN traps are
  not inherited without `functrace` / `set -T`.
- It **does** fire for frames already on the call stack when it was installed
  — i.e. the caller's return.
- It **does** fire at the end of the next file finished by `source` / `.`.

So a trap body referencing function-locals (`local prev_umask`, `local tmp`) is
a delayed fault: by the time it re-fires, those locals are gone. Under the
caller's `set -u` that is a fatal `prev_umask: unbound variable`, attributed to
a line with no visible relationship to the vault.

In PR #580 this killed `dots sync` on the **success** path — `.sync:88`
`materialize_secrets` → `vault_materialize` installed the trap; it re-fired on
`materialize_secrets`' return and aborted the run between
`install_tilth_claude_code` (which clobbers the registry MCP shape in
`~/.claude.json`) and `reconcile_claude_mcps` (which repairs it).

Fix shape: `trap - RETURN` as the trap body's first statement, so it
de-registers the instant it fires. Or skip the trap and clean up explicitly on
each return path.

## Rule 3: test at the integration seam, not at top level

`tests/vault.bats` shipped 232 lines and 12 green tests while the shipped
integration was dead. Every case ran the function as
`run bash -c "source lib; fn"` — a bare top-level shell, which is precisely the
one call shape where a leaked RETURN trap is **inert** (no enclosing frame to
re-fire on, no subsequent `source`).

A library reached through a wrapper (`.sync` → `.sync-lib.sh` →
`bin/lib/vault.sh`) needs at least one test that calls it *through that
wrapper*, from inside a function, under the caller's real strict mode, and
asserts a statement after the call still executes. Top-level-only coverage
cannot see this class of defect.

## Rule 4: bash 4+ features need a version guard, not a shebang alone

macOS ships bash **3.2.57** at `/bin/bash` and always will (GPLv3). Homebrew's
bash 5 lives on `PATH`, so any script whose shebang is `#!/bin/bash` — or which
is exec'd directly, as `bin/dots:128,159` execs `.sync` — runs 3.2 regardless of
what an interactive `bash --version` reports.

The trap here is that 3.2 does not reject bash-4 syntax loudly. `local -A`
**no-ops**: the declaration succeeds, and every associative subscript then
collapses to index `0`. In `vault_materialize` that meant the closed-set key
check passed for *any* key and every template key was written with the *last*
response line's value — while the function still returned `0`, so
`materialize_secrets` logged success and recorded nothing in `SYNC_FAILURES`.
The observable result was one real token exported under four unrelated key
names to four third-party services, silently, on every macOS sync.

Two mitigations, both required:

- Guard explicitly, **before** the first bash-4 construct (the construct itself
  will not raise): `(( ${BASH_VERSINFO[0]:-0} >= 4 )) || { …; return 1; }`.
- Use `#!/usr/bin/env bash` in executables so `PATH` resolution can find bash 5.
  This alone is insufficient — it fixes the common case but silently regresses
  on any machine without a newer bash on `PATH`.

Interacts with Rule 3: the defect shipped green because every materialize test
used `run bash -c …`, resolving `bash` from `PATH` (Homebrew 5.3) and never
`/bin/bash`. Coverage for a bash-version guard must pin the interpreter
explicitly; the ambient one is the wrong one.

Related: [[cc-launch-env]] (the sibling loader), [[mcp-secret-handling]].
