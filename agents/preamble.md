# Preamble — MCP tool routing

## Tool routing

Use tilth directly for workspace code and file operations.

1. **Search in batch** — use one `tilth_search_v2` call with all related queries to locate definitions, callers, and affected files. Always prefer `tilth_search_v2`; fall back to `tilth_search` only when v2 is unavailable or reports a `miss` you need to re-run as `regex`/`callers`.
2. **Read in batch** — use one `tilth_read` call containing every file or symbol needed for the next decision.
3. **Check impact when required** — use `tilth_deps` before changing or removing an exported interface.
4. **Write in batch** — use one `tilth_write` call with tag-anchored edit sections for the complete coherent change.
5. **Inspect the result** — use `tilth_diff` before verification.

Use shell only for tests, builds, and operations tilth does not cover.

## Ground in the repository wiki first

When Hallouminate is available, query the repository wiki **before** architecture, configuration, unfamiliar-subsystem, or design work:

1. Use `ground` with the task's concepts; use `list_corpora` when the repository corpus is uncertain.
2. Read relevant matched pages before exploring code. Search snippets are orientation, not complete evidence.
3. Treat the wiki as the source for rationale, decisions, and gotchas; treat code and project instructions as the source for current behavior and commands.
4. If newer code or evidence contradicts the wiki, follow the newer evidence and correct the wiki rather than blending both claims.
5. Skip grounding only for a trivial one-step task or when no repository wiki exists.

Before finishing, record any durable decision or non-obvious fact that a future agent would otherwise rederive. Do not copy facts already clear from code or project instructions.

One initial grounding pass is sufficient unless the task encounters a new design question.

## Phase-agent delegation

Delegate coherent phase work unless it is a trivial one-step task:

| Work | Agent |
|---|---|
| Orient in unfamiliar code or trace impact | `explorer` |
| Research external facts, APIs, or versions | `researcher` |
| Review a diff, branch, PR, or path | `reviewer` |
| Write or change code | `coder` |

The top-level orchestrator owns planning, user decisions, and fan-out. Workers return condensed evidence rather than raw file or fetch output.

Retain iterative diagnosis inline; delegate implementation and verification. On `blocked: suspect-environment`, diagnose the reproduction and competing hypotheses before redispatch, passing measured dead ends as known-false leads with ruling-out evidence.

Every reviewer dispatch must explicitly set `Review mode: severity-report` or `Review mode: taste-test`.
