# Fit the host setup

Read at Flow step 1, and in review mode for each prompt that tells an agent to run a command.
This file describes the dotfiles setup: tilth, the tool-reroute hook, the worktree guard, and the phase agents.
In another repository, check each rule against that host. Mark a rule unverified when the host has no matching file.

## Rule

Every agent in a workflow runs under the same PreToolUse hooks as the parent session.
A prompt that tells an agent to use a denied tool makes the stage fail, even when the work is correct.
Design each prompt and each check so that it runs under these hooks without an exemption.

## Tool routing

| Need | Use | Denied form |
|---|---|---|
| Read a text file | `mcp__tilth__tilth_read` | Read tool; `cat`, `head`, `tail`, `less`, `nl`, `bat`, `sed`, `awk` on a file |
| Search code or text | `mcp__tilth__tilth_search` | Grep and Glob tools; `grep`, `rg`, `ag`, `ack` on a file or a directory |
| Write or edit a file | `mcp__tilth__tilth_write` | Write, Edit, MultiEdit; `echo`, `printf`, `cat` with `>`, `>>`, or `tee`; `sed -i` |
| Browse directories | `ls`, `find` | none |
| History and diffs | `git log`, `git diff`, `git show <sha> --stat` | `git show <ref>:<path>` reads file content outside tilth |

The hook source is `agents/lib/tool-reroute/` (`native.js`, `search.js`, `io.js`, `exempt.js`).

## Exemptions

The hook allows a shell reader or searcher in three cases only:

1. It filters a pipe or a here-string, for example `git log | grep fix` or `node --test x | grep -q ok`.
2. Every target is a regular file of at most 16 KiB, and the command writes no file.
3. Every target is in the session scratch directory `<tmp>/claude-<uid>/`.

A directory, a missing file, an `xargs` feed, or a shell expansion such as `$f` keeps the deny.
Do not rely on the 16 KiB exemption in a workflow. A file grows past it, and the stage then fails.

## Checks that run

A criterion check runs in a judge agent under these hooks. Write each check in one of these forms:

1. The repository's own test for the criterion: `node --test --test-name-pattern 'AC-2' <file>`, `pytest -k`, `bats -f`, or a `just` recipe.
2. `test -e <path>` or `test ! -e <path>`.
3. `git` plumbing with an exit status, for example `git diff --quiet <base> -- <path>`.

When a criterion asserts literal text in a file, the implementer adds a marked test, and the check runs that test.
Reject a check in code before the first implementer when it runs a denied reader or searcher on a file.
When a guard denies a check at verify time, record the verdict `unrun` with the guard as the reason. Do not record `fail`.

## Writes and worktrees

- `claude/hooks/worktree-guard.js` allows writes only inside the agent's own worktree root. It also allows `/tmp`, `$TMPDIR`, `~/.claude/`, any `.cheese/` directory, and `~/.local/share/cheese/`.
- A Bash `cd` does not change the guard root. Give each writer its own `isolation: 'worktree'` agent. Move state between stages through refs and commits.
- A preserved worktree from an earlier run belongs to that run. A new writer cannot edit it. Salvage its ref, then write in a new worktree.
- The WorktreeCreate hook must print the new worktree path. When it prints nothing, `isolation: 'worktree'` fails before the agent starts. Treat that failure as an infrastructure error, not a task failure.

## Agent types

| Type | Writes | Use for |
|---|---|---|
| `explorer` | none in source | grounding, survey, criteria extraction |
| `coder` | `tilth_write` in its worktree | implement, integrate, cure |
| `judge` | none; Bash to read state and run checks | advise, verify |
| `reviewer` | own `.cheese` artifact only | age review |
| `taste-tester` | none | handoff lenses |

No agent type has Grep or Glob. Tell agents to use tilth tools by name.

## Agent startup cost

Each agent pays a fixed startup cost that its agent type sets. The tool set and the injected instructions drive it.
Median first-request size, local measurement 2026-10-15 (1,021 Workflow agents; cache rules in [s17]):

| Agent type | Median first request |
|---|---|
| default `workflow-subagent` | 25.4k tokens |
| `Plan` | 30.5k tokens |
| `reviewer` | 26.3k tokens |
| `explorer` | 15.6k to 21.1k tokens |
| `coder` | 11.7k tokens |
| `judge` (sonnet) | 8.4k tokens |

Siblings share only about 7k prefix tokens, so a fan-out pays most of this cost again for each agent.

1. Count agents, not prompts. Cost grows with agent count.
2. Batch small items, such as a claim, a command, or a file, into one agent. Do not start one agent for each item.
3. Give a mechanical stage a narrow agent type, not the default.
4. Do not set `subagentPromptCacheTtl` to 1h for cost. The 5-minute TTL matters little, because siblings share only about 7k tokens.

Example defect: `brie-ground` verify started one default-type agent per claim, up to 85 agents in one run. That was 34% to 49% of the run's cost.

Caveat: repair and salvage agents never ran in the measured set, so their cost is unmeasured. A repair agent without an `agentType` pays the default startup of about 25k tokens.

## Workflow versus prose fan-out

Local measurement 2026-10-15: 4,750 Agent calls, 1,185 background hand-backs, 89 Workflow calls. Token sizes are characters divided by 4. Cost is in input-equivalent tokens: cache read 0.1x, cache write 1.25x, output 5x.

An Agent-tool sub-agent costs about 22k at startup. A default-type Workflow agent costs about 25k. A narrow type costs 8k to 12k.
The parent also pays for each prose sub-agent:

- Its prompt as parent output: about 2.6k.
- The launch receipt in context: about 2.3k.
- The hand-back result, re-read on a median 72 later requests: about 11.4k mean.
- A wake-up request per hand-back: about 22k. This figure is an estimate, not measured per event.

A saved Workflow run by name costs the parent one receipt (about 3.3k) and one final result (about 6.2k mean), whatever the agent count. Of 89 Workflow calls, 87 ran by name.

1. A Workflow saves through parent overhead, not per-agent cost. It saves about 15k to 35k for each agent that a prose parent would carry.
2. A Workflow wins with 3 or more agents behind a large parent context, with multi-stage pipelines, and when code does the dedup, sort, gate, or early exit. Script variables hold the intermediate results.
3. Prose stays cheaper for 1 or 2 agents, one stage, or a small parent context. It also fits work that needs a human decision mid-way, because a Workflow cannot pause.
4. A Workflow loses its saving when it starts more agents than a prose parent would. Keep the agent count, then batch and use narrow types.

## Structured output

The runtime logs `subagent completed without calling StructuredOutput` when an agent ends without its typed result. The call returns `null`.
Route that `null` through the redo path in `repair.md`. For an implementer, salvage from the ref first.
Keep each task inside one context. A long task ends without its result more often.

## Deploy and relaunch

- The source is `claude/workflows/<name>.js`. `dots sync` deploys it to `~/.claude/workflows/`, and the parent then calls the workflow by name.
- The auto-mode classifier denies a relaunch of an edited copy through `scriptPath` as `[Self-Modification]`. Edit the source, run `dots sync`, and relaunch by name. Otherwise, ask the user.
- Nesting allows one level. A workflow that calls a child workflow cannot itself run as a child.

## Evidence

- Run records: `~/.claude/projects/*/<session>/workflows/wf_*.json`. Each record holds `result`, `logs`, `agentCount`, `totalTokens`, and `durationMs`.
- Hook denials: `${XDG_STATE_HOME:-~/.local/state}/claude-tool-reroute/decisions.jsonl`.
- Use `/session-analytics` to count statuses across runs before you change a workflow. A design change needs a before and after success rate.
