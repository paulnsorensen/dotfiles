# Routine authoring — how to write a routine prompt that behaves

The routine prompt (`agents/<name>/routine.md` in the target repo) is the single
source of truth. The scheduled message only says "read it and follow it
exactly," so everything the routine needs lives here. It runs cold in a hosted
environment with no memory of the authoring session.

## Self-contained prompt

The prompt must stand alone:

- Never reference "this session," "the above," or any ephemeral context — a
  future run has none of it.
- State the objective, the exact steps, every file path / URL / tool name, the
  success criteria, and the stop condition inline.
- Write in second-person imperative: "Run the scanner…", "Open a PR…".

## Explicit stop conditions

A routine that cannot decide when to do nothing will manufacture busywork.

- Name what "nothing to do" looks like (empty scanner result, no matching PRs,
  no drift).
- On that condition, **exit quietly** — no output, no artifacts, no PR.
- The Acceptance case is literal: when a routine finds nothing to act on, its
  authored prompt makes it exit silently.

## Evidence, not inference

Act on observed tool output, never on a guess about repo state.

- Push deterministic math (version diffs, counts, date windows) into a
  committed, tested scanner — not the model's head. The routine parses the
  scanner's JSON; it does not eyeball versions.
- Research via connectors (Tavily for web/release notes, Context7 for library /
  API / config docs) to *judge impact*, then read the governed files directly
  before acting.

## Idempotency and dedup

Runs overlap and repeat; the routine must not stack duplicate artifacts.

- Before acting on an item, search open PRs/issues **and** the work branch
  (`<name>/<item>-<current>`) for existing coverage; if found, report `dup` and
  stop for that item.
- Store the last-reconciled marker as a committed field that advances **only
  inside a merged PR**, so drift keeps surfacing until a human disposes it.

## File-disjoint fan-out

When a routine processes several independent items, fan one subagent per item so
each item's reading and reasoning stays in its own context window:

- Give each subagent exactly one item plus the data it needs.
- Keep subagents **file-disjoint** — each touches only its own governed files and
  its own line in the manifest (git merges the per-line updates); never another
  item's files or branch.
- If subagent dispatch is unavailable in the environment, process items
  sequentially in the same context — the per-item logic is identical.

## The scan-and-triage triad (watcher shape)

The doc-drift watcher is the worked example. When the task is a watcher, scaffold
all three:

1. **Data manifest** (`agents/<name>/sources.yaml`) — what to watch, the signal
   to resolve it, the files each item governs, and the reconciled marker.
2. **Deterministic scanner** (`bin/<name>-scan`) — resolves current state,
   compares to the marker, emits JSON (`{id, current, drifted, status}`), with
   bats tests in the target's suite. Fail loud on an unknown signal type.
3. **Routine prompt** (`agents/<name>/routine.md`) — runs the scanner, triages
   each drifted item (no-op / small / large-idea → PR / PR / issue), fans out
   per item, honors the invariants.

Not every routine is a watcher — a changelog-draft or repo-brief needs only the
prompt. Scaffold the manifest + scanner only for scan-and-triage shapes.
