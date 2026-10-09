---
name: harness-climb
model: opus
effort: high
description: Improve the agent harness (global docs, preamble, agent definitions, hooks, skills) from real Claude and Codex session history, one measured round at a time. Use for "harness climb", "improve the harness from session data", "/harness-climb", or one round of a /loop. Each run does one round and records state on disk, so it is safe to repeat. Route a single metric benchmark to /hill-climb and one-off session questions to /session-analytics.
---

# Harness climb

This skill turns session history into one small harness change per round.
A human merges the change. A field gate then measures it on later sessions.
One invocation is one round. A loop runs the skill until a stop condition occurs.

## Discipline

**Iron Law:** No change ships without evidence from session counts, and no change counts as kept without a field verdict.

**Red Flags** — stop when you notice these:

1. A finding has no query, no counts, or no blamed component.
2. A diff holds text from a user prompt or a project name.
3. You want to skip the critic or the freeze because the change is small.
4. You want to merge, sync, or revert by hand.

| Rationalization | Why it fails | Required action |
| --- | --- | --- |
| "The pattern is obvious." | Anecdotes are not counts. | Run `analyze` and cite the counts. |
| "The lab is slow, so skip it." | The freeze records the lab result. | Run the lab or record why it is held. |
| "The field gate says revert, so I revert." | The gate only opens a revert PR. | Open the PR. A human merges it. |

## Commands

Every step below uses one script. Each subcommand prints JSON. Exit 0 means pass, 1 means fail or refusal, 2 means error.

```bash
hc="$(git rev-parse --show-toplevel)/skills/harness-climb/scripts/harness_climb.py"
python3 "$hc" <analyze|critic|freeze|field-gate|ledger> --thread <thread> ...
```

Read [field-gate.md](references/field-gate.md) before you freeze a round or run a field gate.

## Thread state

State lives in `.harness-climb/<thread>/` and stays out of git:

- `STOP` — its presence ends the loop. Its first line is the reason.
- `ledger.md` — one line per round: round, change, pr, lab, claude, codex, candidate, merge.
- `rounds/r<n>/` — `tags.json` (path to one component tag) and `critic.json`.

The gate files live in the tracked directory `harness-climb/gates/`. Each file is `<thread>-r<n>.json`.

## Round

1. If `STOP` exists, run any subcommand. It prints the reason and writes nothing. Report it and end.
2. Check due field gates. Run `ledger tail`. For each line with `candidate=pending` and a merge SHA, run `field-gate --round <n> --merge <sha>`. Report `not-due` and move on. Record a verdict with `ledger append`. A `revert` verdict opens a revert PR through `/plate`. Never run a revert yourself.
3. Run `analyze`. Dispatch the `session-analytics` skill for the findings. Write them to a findings file and pass it with `--findings`. Every failure mode needs `query`, integer `counts`, and one blamed component. Every success habit needs a session count. Use claude and codex sessions only.
4. Propose one change for one component: `global-doc`, `preamble`, `agent-def`, `hook`, or `skill`. Edit owned source only. Do not edit vendored skills, rendered targets, runtime output, or `agents/instruction-budgets.toml`. Work on branch `harness-climb/<thread>/r<n>`. Write one component tag per changed path to `tags.json`. Never copy prompt text or project names into the diff.
5. Run `critic --round <n>`. On `fail`, repair the diff and run it again. The third failure returns `rejected`: the script writes the ledger line, and you open no PR.
6. Run the lab. A `skill` with an approved autoimprove contract runs `autoimprove`. Every other component is held. Pass `--contract --autoimprove-verdict <verdict>` to the freeze for a contracted skill.
7. Run `freeze --round <n> --component <c> --targeted-query-file <file> --direction <lower|higher>`. The freeze needs the passing critic verdict. It refuses while a merged gate of the same component has no field verdict. It commits the gate file.
8. Publish the branch through `/plate`. Put the evidence counts, the lab result, and the gate file path in the PR body. Stop at the PR.
9. Append a ledger line with `candidate=pending`, `claude=pending`, `codex=pending`, and `merge=none`. After the human merge, a later round replaces it with the field verdict and the merge SHA.

## Stop conditions

- Three rounds in a row with no `keep` verdict: write `STOP` with `diminishing-returns`.
- A trade-off needs human taste: write `STOP` with `needs-human` and the evidence.
- The session database is missing or a gate breaks for an unrelated cause: write `STOP` with `blocked`.
- The human owner asks to stop.

## Guardrails

- One component has one unmeasured merged candidate at a time.
- A pin bump for `claude-code` or `codex` fails CI while a soak window is open. Only the `harness-climb/soak-override` label passes it.
- The skill never merges, never syncs, and never reverts itself.
- Tokens are a cost, not a guard. A cheaper equal result is `keep-cheaper`.

## Loop drivers

Claude Code, self-paced: `/loop /harness-climb <thread>`.
Codex has no loop command. Drive it from the shell:

```bash
thread=docs
until [[ -e .harness-climb/$thread/STOP ]]; do
  codex exec -s workspace-write "Use the harness-climb skill. Run one round of thread $thread." || break
done
cat ".harness-climb/$thread/STOP"
```
