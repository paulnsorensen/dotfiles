# Routine safety — the invariants and how to hold them

A cloud routine runs unattended with write access. These are the safety rules the
skill bakes into every routine and the `reviewer` phase checks before landing.

## Never auto-merge; the human disposes

The converging safety default across every independent source reviewed
(matplotlib, ITK, camel-ai, Voyfai, and Chainguard's own gate): the routine
opens a PR or issue; a human reviews, merges, and runs any follow-on sync.

- Auto-merge is an explicit **v1 non-goal**. Do not configure it, even opt-in.
- The documented Chainguard exception (auto-merge behind a separate,
  deterministic non-LLM approver + green CI) needs infra most repos lack and is
  single-source-cited — out of scope for v1, revisitable later.

## No direct push to a default branch

Any state the routine advances (a reconciled marker, a version bump, a changelog
entry) advances **only inside a PR**. The routine never pushes to `main` /
`master` directly.

## Scoped write access

The routine writes only what its task needs:

- Its own artifact files and its own branch (`<name>/<item>-<ref>`).
- In fan-out, each subagent is file-disjoint — never another item's files.
- Confirm the environment's `gh` OAuth actually reaches the target repo before
  promising a PR. Cross-repo OAuth reach is unconfirmed; verify per target with
  `gh repo view <owner/name> --json viewerCanAdminister`.

## Allowlist gating

Connectors are gated by the routine's `allowed_tools` list. A tool the routine
needs but the allowlist omits is refused at run time.

- Reference MCP tools as `mcp__<Server>__<tool>` — the server segment is a
  literal connector name (e.g. `mcp__Tavily__*`, `mcp__Context7__*`; casing
  illustrative only — confirm off the first live run, below).
- Grant only the connectors the routine actually uses.

## Connector-casing verification

The exact casing of `mcp__<Server>__<tool>` is **not confirmed by docs** — it is
confirmed off the first live run's granted-tools list.

- Do not hardcode a casing guess as final.
- After the first run, read the granted-tools list; if the run was blocked, the
  allowlist casing is the first suspect.

## 403 `host_not_allowed` troubleshooting

A connector call blocked with `host_not_allowed` (or a tool refusal) means the
allowlist did not admit that tool:

1. Check the `allowed_tools` casing against the run's granted-tools list.
2. Confirm the connector is actually attached to the environment.
3. Update the routine's allowlist and re-run; the committed `routine.md` is
   unchanged — only the registration's allowlist moves.

## Label / track

Give each routine a tracking label (e.g. `gh label create <name>`) so its
artifacts are filterable and dedup can find prior work. Create it idempotently
(`|| true`) at the top of the routine.
