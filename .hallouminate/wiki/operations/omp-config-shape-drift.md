---
status: reviewed
last_verified: 2026-09-08
confidence: high
sources:
  - chezmoi/.chezmoidata/omp.yaml
  - chezmoi/dot_omp/private_agent/modify_config.yml.tmpl
  - https://github.com/can1357/oh-my-pi/commit/46ad908
  - https://github.com/can1357/oh-my-pi/commit/ec65115
  - .cheese/research/omp-autoqa-consent-shape/omp-autoqa-consent-shape.md
---
# OMP config-shape drift: normalize the machine, never fold into the registry

When `dots sync` halts with the unknown-key gate on nested `dev.autoqa` /
`dev.autoqa.consent` paths in `~/.omp/agent/config.yml`, the cause is a
**stale per-machine file serialization**, not an omp version or platform
difference.

## Two causes, opposite fixes — discriminate first

The unknown-key gate fires for two different reasons. Fixing one with the
other's remedy causes the #487 flip-flop (below). Ask omp itself which case
you have before touching anything:

```sh
omp config get <the.old.key>   # e.g. task.isolation.mode, dev.autoqa.consent
```

- **`Unknown setting` → genuine version rename/addition.** omp dropped or
  renamed the key in a version bump. **Fold** the new key into the registry
  (`chezmoi/.chezmoidata/omp.yaml`) at omp's live default, with an
  `omp-introduced (vX.Y)` comment. This is the same path as every other
  `omp-introduced` fold already in that file.
- **Resolves to a value → stale serialization.** The old key still exists;
  this machine's file just predates a rename. **Normalize the machine**
  (force a re-save), never fold. See below.

Worked example (v18.1.x, folded in commit that added the isolation keys):
`task.isolation.mode: auto` became boolean `task.isolation.enabled: true`
and a new top-level `isolation.backend: auto` appeared. `omp config get
task.isolation.mode` returned `Unknown setting`, so both were folded at live
defaults — not normalized.

## The stale-serialization case (dev.autoqa)

- omp's canonical file shape is **flat** `dev.autoqaConsent` since v17.0.0
  (oh-my-pi `46ad908`, 2026-07-15, "renamed settings keys to avoid
  nested-value lookup collisions"). The nested `dev.autoqa.consent` object is
  the *pre-rename legacy* shape, accepted only as read-migration (`ec65115`)
  and normalized on omp's next settings save.
- omp only re-saves settings when something writes them — a machine whose
  config predates the rename keeps the nested shape indefinitely, so
  different machines legitimately show different file shapes at the same omp
  version. The write path has zero platform conditionals (settings.ts is
  byte-identical across 17.0.5/17.0.6; verified in the research slug above).

## The trap (history: #487 → revert b27ab75)

The unknown-key gate compares **live file key-paths** against the registry
(`chezmoi/.chezmoidata/omp.yaml`). Folding a *stale* nested shape into the
shared registry makes sync pass on the stale machine and **halt on every
normalized machine** — that is exactly the #487 (authored on the Mac, nested
live file) → revert (authored on the UTC/Linux box, flat live file)
flip-flop. Both commits were "right" for the machine they were written on.
The discriminator above prevents this: a *stale* key still resolves via
`omp config get`, so it must be normalized, never folded.

## The fix (stale-serialization case)

Normalize the stale machine's file instead — force an omp settings save:

```sh
omp config set dev.autoqaConsent granted   # re-save normalizes legacy keys
```

then re-run `dots sync`. The registry stays flat everywhere. (If a shell
wrapper injects flags into `omp`, call the raw binary:
`$(which -a omp | tail -1)`.)

Related: [[sync-and-chezmoi]], [[../harnesses/omp]].
