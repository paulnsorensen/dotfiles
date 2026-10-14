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
