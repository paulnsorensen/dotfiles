# Wheypoint Stop hook

`agents/hooks/wheypoint-stop-gate.sh` keeps a session's wheypoint current while work is in progress.
`chezmoi/.chezmoidata/claude.yaml` wires it as a `type: command` hook on `Stop`.
The registry entry `wheypoint-stop-gate` deploys the script to `~/.claude/hooks/`.
Tests: `tests/wheypoint-stop-gate.bats`.

## Behavior

The script reads `transcript_path` from the Stop payload and folds the assistant entries in order.
A wheypoint is a `Skill` call to `wheypoint` or an assistant line with `Wheypoint dropped:`.
A file change is a call to `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, or `tilth_write`, or a Bash `git commit` or `git push`.
Writes under `/tmp` and `.cheese/` do not count.
A wheypoint resets the change count to zero.

- No file change since the last wheypoint: the agent stops normally.
- A wheypoint exists and a file changed after it: the hook blocks with "Update this session's wheypoint".
- No wheypoint, a file changed, and the working tree is dirty: the hook blocks with "Work is uncommitted. Write a wheypoint".
- No wheypoint, a file changed, and the tree is clean: the agent stops. The work is committed.
- `stop_hook_active` true: the agent stops. This ends the follow-up.

Any error exits 0 with no output (fail-open). `WHEYPOINT_STOP_GATE=0` opts a session out.

## Why a command hook replaced the prompt hook

The first version was a `type: prompt` hook on Haiku.
It fired on every stop and judged "work remains" from the transcript.
It forced a wheypoint after Q&A turns that changed nothing, because an agent question counts as unfinished work.
A hook has no delay field, and all hooks for one event run in parallel, so a separate gate hook could not suppress the prompt hook.
A command hook that calls `claude -p` for the verdict would fire the user's other Stop hooks (tmux state) in the nested session.
A deterministic check on file changes avoids the model call, the cost, and the timeout.

Trade-off: the script cannot tell finished work from unfinished work except through the dirty-tree test.
After a wheypoint exists, any later file change demands an update, even for finished work.

## Gotchas if a prompt hook returns

- **Use the full model ID.** `model: haiku` fails with "There's an issue with the selected model (haiku)" (Claude Code 2.1.295). `claude-haiku-5-5` works.
- **Claude Code wraps the prompt.** The evaluator gets "Based on the conversation transcript above, has the following stopping condition been satisfied?" and then `Condition: <prompt>`. Write the prompt as a stop condition.
- **Use ordered steps.** A list of "condition holds if" clauses let Haiku treat "the agent asks a question" as the Q&A exemption.
- **Cost.** Each stop sent the whole message history to Haiku: about 26k input tokens and $0.0035 for a trivial session (2026-10-10).
- **Test with** `claude -p --settings <file> --debug-file <log>` in a temp directory. A run that ends at `--max-turns` never fires `Stop`.

## Deploy

`dots sync` deploys from the main clone, not from a T3 worktree.
Merge the change to `main`, then run `dots sync`.
