# Session-analytics gotchas

Facts measured on 2026-09-04 that a future analysis would otherwise rederive.

## `tool_uses.bash_cmd` records the pre-hook command

The `tool-reroute` PreToolUse hook rewrites `cd <path> && git …` to `wt-git …` through `updatedInput`. The transcript stores the model's original input. Adoption of `wt-git` is therefore invisible in `tool_uses`. Measure rewrites from `tool_results` (`command not found: wt-git`) or add a decision log to the hook.

## `tilth_write` echoes the whole file after each edit

tilth 0.8.4 returns the full post-edit file with a fresh tag in every `tilth_write` result. In coder sub-agents this is ~30% of all tool-result bytes (median 8 KB per call). `tilth_read` is ~34%. The coder does not start large (median 22k tokens); it grows to a 112k median peak over ~54 turns.

## Sub-agent transcripts carry no agent type

`~/.claude/projects/<proj>/<session>/subagents/agent-<id>.jsonl` has `agentId` and `isSidechain` but no `subagent_type`. Join on the parent's `Agent` tool_use `input.prompt` prefix, or use `~/.local/state/claude-turn-budget/decisions.jsonl` (`budget_type`, `action`, `agent_id`).

## Auto-mode classifier prompts are not in transcripts

Only classifier blocks appear (`denied by the Claude Code auto mode classifier`). Approved prompts leave no record. Add a `Notification` hook on `permission_prompt` or a `PermissionDenied` hook to measure prompt volume.

## `cd-strip`'s cwd is Claude Code's tracked cwd, not the shell's live $PWD

The two can diverge after a `pushd`, a sourced script, or a `bash -c 'cd … && …'`. Check by grepping `decisions.jsonl` for `strip` records whose `rewrite` starts with `./`, `../`, or a bare script name.

## No-op directory rewrites require logical path safety

Physical path equality does not prove that `cd` has no effect.
A symlink target can change logical `PWD` while retaining the same physical directory.
Path normalization can also remove a missing component and hide a failing `cd`.[^rewrite-safety]

Reject uncertain path forms instead of extending a partial shell parser.
Git-chain rewrites must also preserve environment assignments and wrappers, or leave the command unchanged.[^rewrite-safety]

## Permission logs use bounded metadata

Permission suggestions can include complete shell commands in rule content.
Persist suggestion metadata rather than rule content.
Apply redaction at the shared persistence boundary before truncation.
Caller-only redaction lets new fields bypass the policy; truncation can cut a credential before the sanitizer recognizes it.[^log-safety]

Redaction covers known credential forms, not arbitrary secret detection.
Keep log directories and files private even when they already exist.
Open log descriptors in nonblocking mode.
FIFO paths otherwise block before file-type validation.
Check file permissions on the open descriptor.
Use that same descriptor for writes.
A pathname check followed by append permits a symlink swap.[^log-safety]

[^rewrite-safety]: PR 878 review reproductions; `agents/lib/tool-reroute/cd-strip.js`; `agents/lib/tool-reroute/cd-git.js`; `tests/tool-reroute.bats`.
[^log-safety]: PR 878 review reproductions; `agents/lib/jsonl-log.js`; `agents/lib/permission-log.js`; `tests/permission-log.bats`.
