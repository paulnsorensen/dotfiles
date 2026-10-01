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

Keep rotation in one bounded open-and-validate loop.
Separate open sites duplicate validation and trigger CodeQL's check/use heuristic, which does not inspect flags.[^codeql-race]

## Write-redirect guard: variable targets and the retired skill name (2026-10-01)

A 14-day analysis found 205 `tool-reroute/io` write-redirect blocks in 134 sessions. Two causes were guard defects, not agent mistakes:

- **Variable targets resolved in-tree.** `S=/private/tmp/...; cat > $S/intent.json` resolved `$S/intent.json` relative to cwd, so the guard denied a valid out-of-tree scratch write. The guard now expands a leading `$NAME` or `${NAME}` from assignments in the same command. It delegates when the leading expansion is unknown, such as an unset variable, `$(...)`, or a backtick.
- **The deny text named a retired skill.** It said "use the cheez-write skill", which no longer exists. It also seeded new files with `prepend`. The text now names `mcp__tilth__tilth_write` and shows a `create_file` template.

The same pass added `tilth_write` rules to `agents/preamble.md`. Top `tilth_write` failures were a TAG reused for lines its read never displayed (138 in 14 days), a `replace_text` `old` outside the displayed section (19), JSON parse errors (11), and `create_file` on existing paths (11). The preamble budget rose to 575 tokens for these rules.

`tool-reroute/search.js` still names the retired `cheez-search` skill in its deny text.

[^codeql-race]: <https://raw.githubusercontent.com/github/codeql/main/javascript/ql/src/Security/CWE-367/FileSystemRace.ql>; PR 878 alerts 110 and 111.

[^rewrite-safety]: PR 878 review reproductions; `agents/lib/tool-reroute/cd-strip.js`; `agents/lib/tool-reroute/cd-git.js`; `tests/tool-reroute.bats`.
[^log-safety]: PR 878 review reproductions; `agents/lib/jsonl-log.js`; `agents/lib/permission-log.js`; `tests/permission-log.bats`.
