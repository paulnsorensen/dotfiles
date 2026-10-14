# claude-workflows evaluation intent

This file states author intent before candidate results. It is independent of the current skill body.
Each requirement comes from a failed run of a real workflow in the dotfiles repository, recorded from 2026-10-11 to 2026-10-14.
In that period, 54 runs of cheese-board, cheese-factory, and move-my-cheese used about 23.5M tokens. No run returned `ok`.

## Questions

- Does the skill put human gates and run state in a calling skill, and only parallel units in a Workflow?
- Does each prompt and each check run under the host PreToolUse hooks?
- Does the advisor gate converge, or does it block on its own payload?
- Does each stop for input name a resume input that skips completed stages?
- Does the argument parser accept the inputs a user types?
- Does code do the git and GitHub plumbing instead of many small agents?
- Does the skill stay out of one-agent tasks?

## Behaviors

- **CW-01 — Form choice.** Keep user questions, approval, and run state in the calling skill. Use a Workflow only for independent units that each fit one fresh context.
- **CW-02 — Hook-safe checks.** A criterion check runs under the host hooks. It runs a repository test, `test -e`, or `git` plumbing. It never runs a denied file reader or searcher. Code rejects a denied check before the first implementer.
- **CW-03 — Guard outcome.** When a guard denies a check at verify time, the verdict is `unrun` with the guard as the reason, not `fail`. Plate stays blocked.
- **CW-04 — Advisor payload.** The advisor payload states the plan shape. It sends no `null` or empty placeholder for a field that the shape leaves out.
- **CW-05 — Advisor convergence.** The second advisor round judges only the first-round concerns. A new concern must be a blocker and is marked new. The advisor never reverses a prior concern. A concern that no rerun step can fix returns `needs-input`.
- **CW-06 — Resume contract.** Each `needs-*` result names a resume input. A resume validates durable state and skips completed stages.
- **CW-07 — Forgiving arguments.** A bare string maps to the main field. Free text that is not a spec routes to the spec skill. Each error shows the exact call shape.
- **CW-08 — Plumbing in code.** One script or one agent call does the git and GitHub plumbing. A `null` result without `StructuredOutput` takes the redo or salvage path.
- **CW-09 — Deploy and relaunch.** A changed workflow is edited at its source, deployed, and relaunched by name. The design does not relaunch an edited copy through `scriptPath`.
- **CW-10 — Invocation boundary.** A one-agent task gets one agent call, not a Workflow.
- **CW-11 — Honest evidence.** A change claims a better success rate only with run records from before and after the change.

## Negative Cases

- A criterion check uses `grep -Fq` on a file larger than 16 KiB.
- A clean, reviewed change ends `partial` because a guard denied its check.
- The plan advisor asks for a file list in round one, and for its removal in round two.
- A caller reruns a workflow seven times in 35 minutes, and each run stops at the same gate.
- A rerun repeats Recon and planning after the user approved the plan.
- The workflow rejects `"bugs related to routines"` or `null` with no call shape.
- A haiku agent runs one `git rev-parse` and returns its output.
- A design relaunches a `scriptPath` copy and the auto-mode classifier denies it.

## Notes

`cases.json` is a repository-local, runner-neutral case list. It is not an external runner schema. The object keys and rubrics are instructions for a human or an independently selected runner. They are not executable assertions. Do not launch autoimprove, paid model calls, or a custom eval engine from this directory. Keep these requirements stable when observations differ. Record new gaps separately, and revise intent only through an explicit review.
