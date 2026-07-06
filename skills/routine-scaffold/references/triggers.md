# Triggers — cron, api, github-event

Claude Code routines take three combinable trigger types. All three are
first-class in this skill; only `cron` is battle-tested by us, so the api and
github-event wiring rests on Claude Code docs, not our own live run — flag that
uncertainty when you use them.

Reference: <https://code.claude.com/docs/en/routines>

## cron — scheduled, time-driven

The battle-tested path. Fires on a schedule.

- **Minimum interval: 1 hour.** Sub-hourly cron is rejected.
- **Timezone: UTC** for the routine cron expression (distinct from `/schedule`'s
  local-cron kind, which evaluates in local time).
- Use for: doc/dependency drift sweeps, weekly repo briefs, changelog drafts on a
  cadence, stale-doc scans.
- Example: `0 8 * * 1,4` — Mon + Thu 08:00 UTC.

## api — on-demand

No schedule; the routine runs when `RemoteTrigger.run` invokes it.

- Use for: automations you want to fire manually or from an external caller, not
  on a clock.
- No cron expression; register with an api trigger and invoke on demand.

## github-event — reactive

Fires in response to a GitHub event, unlocking reactive routines that cron
structurally cannot express.

- Use for: review-every-PR nags, label-on-open, react-to-release.
- Example event: `pull_request` (opened / synchronized).
- `<speculative>` on our end-to-end wiring — validate against `/schedule` and the
  first live event before asserting it works.

## Choosing

| Want | Trigger |
|---|---|
| "every Monday", "hourly", "nightly" | `cron` |
| "when I ask", "from a script" | `api` |
| "every time a PR opens", "on release" | `github-event` |

Combine when a routine needs both a cadence and a reaction (e.g. a nightly sweep
plus an on-PR check). Confirm `/schedule` exposes creation for the api and
github-event kinds before wiring them — it may support only cron creation today
(spec open question).
