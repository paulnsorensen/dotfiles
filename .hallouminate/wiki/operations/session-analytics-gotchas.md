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
