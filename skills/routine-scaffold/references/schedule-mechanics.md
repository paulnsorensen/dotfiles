# Schedule mechanics — the RemoteTrigger / environment model

How a cloud routine is registered and what the hosted environment gives it. This
is the knowledge the Register phase hands to `/schedule`; the source of truth for
registration logic is the `/schedule` skill itself.

Reference: <https://code.claude.com/docs/en/routines>,
<https://code.claude.com/docs/en/settings> (allowlist prefix).

## Routines are RemoteTrigger cloud agents

- A **routine** is a scheduled/event-triggered cloud agent registered against the
  claude.ai remote-trigger API, driven by the **`RemoteTrigger`** tool. Its
  actions are `list` / `get` / `create` / `update` / `run` — there is genuinely
  **no delete** action (verified against the tool's own schema, not inferred).
- This skill owns authoring + review + landing the PR; the **cloud-routine**
  registrar owns creating and updating the RemoteTrigger. Do not duplicate
  registration logic here.

### Disambiguate the registrar — two skills are both named `schedule`

The Register hand-off MUST land on the **cloud-routine** registrar, not the
similarly-named local-task skill:

- **Cloud routines (this skill's target):** the `RemoteTrigger` tool (equivalently
  the built-in *cloud* `schedule` skill that drives it). Runs in a hosted
  **environment** (`env_…`), evaluates cron in **UTC**, and takes an
  `allowed_tools` allowlist plus trigger config.
- **Local scheduled tasks (the spec non-goal — do NOT use):** the plugin skill
  *also* named `schedule`, which calls the **`create_scheduled_task`** tool. It
  runs locally, evaluates cron in **local time**, and has no environment /
  `allowed_tools` / `github-event`. Registering a cloud routine through it is
  wrong.

Because a bare `/schedule` is ambiguous between the two, Register drives cloud
registration via the `RemoteTrigger` tool explicitly — never the local
`create_scheduled_task` skill. (The session-only `CronCreate` / `CronList` /
`CronDelete` tools are in-memory job timers for *this* session, not cloud
routines — do not confuse them with registration either.)

## Environment model

- **Environment id** — the routine runs in a named hosted environment (`env_…`).
- **`gh` auth** — the environment's native GitHub OAuth; no PAT. Cross-repo reach
  is unconfirmed — verify per target.
- **Supported extension points:** cached **setup scripts** and **env vars**.
- **Not supported:** custom base images / devcontainers for cloud routines.

## Connector auto-attach

Account connectors auto-attach to any routine created in the environment (Tavily,
Context7, and others). The skill assumes Tavily + Context7 are present as the
default research connectors.

- The routine still only gets the connectors named in its `allowed_tools`.
- Reference each as `mcp__<Server>__<tool>` — the `<Server>` segment is a literal
  connector name. Casing is confirmed off the first live run (see
  `safety.md`), not guessed.

## The bootstrap-message pattern

The routine's scheduled message is **not** the prompt — it is a short bootstrap
that points at the committed prompt:

```text
read agents/<name>/routine.md and follow it exactly
```

- The real prompt lives in `agents/<name>/routine.md`, version-controlled and
  edited by normal PRs — one source of truth.
- Updating the routine's behavior is a PR to that file, not a registration edit.
- The registration changes only when the trigger, env, or allowlist changes.

## Registration payload (handed to `/schedule`)

```yaml
trigger: cron | api | github-event   # see triggers.md
env: <environment id>
allowed_tools: [mcp__<Server>__<tool>, ...]   # default: Tavily + Context7
message: "read agents/<name>/routine.md and follow it exactly"
```

## Known unknowns

- **Numeric limits** (daily cap / concurrency / per-run timeout) — the docs'
  "Usage and limits" section did not render in research; do not assert a number
  until confirmed.
- **api / github-event creation via `RemoteTrigger`** — confirm the
  cloud-routine registrar exposes these trigger kinds before wiring them; it may
  support only cron creation today.
