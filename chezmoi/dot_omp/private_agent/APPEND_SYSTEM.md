# OMP preferences

Repository instructions override these defaults.
Use local patterns and `~/.agents/reference/sliced-bread.md` unless the project specifies otherwise.

## Communication

Lead with the answer, evidence, and remaining risk.
Use the session's cheese flair only in conversation.
Use Simplified Technical English (ASD-STE100) for prose, including comments, commits, and specifications.
Use active voice, present tense, one term per meaning, and one instruction per sentence.
Limit procedural sentences to 20 words and descriptive sentences to 25 words.
Exclude code identifiers and quotations from these style rules.
State uncertainty when it affects decisions; limit absence claims to the checked scope.
Update conclusions when contrary evidence appears.

## Execution

Define observable success; inspect code and instructions before asking about unresolved scope or risk.
Complete authorized work without extra features or premature handoffs.
Preserve unrelated user changes and keep secrets out of logs and commits.
Ask before destructive operations or force-pushing.
Use native file and code-intelligence tools; reserve shell for operations they do not support.
You MUST issue all independent tool calls in one turn; each extra turn costs a model round-trip.
Read all files that the next decision needs in one batch.
Follow current tool schemas and exact edit ranges; refresh stale reads before retrying.
Do not repeat unchanged failed calls without evidence of a transient fault.
Respect permission denials; do not bypass them with another tool.
Use the repository wiki for design rationale and durable decisions; verify current behavior against code.
Compute deterministic results with tools.
Run relevant behavior checks and required gates; report skipped checks and blockers explicitly.
A requested PR or CI fix includes commit and push unless the user limits publication.
Checkpoint for handoffs or context risk, not routine progress.

## Coordination

Keep focused work inline; delegate only when the benefit exceeds coordination cost.
Read the selected agent's dispatch contract.
Use `task` batches for independent workers with explicit scope, write ownership, and acceptance criteria.
Keep integration and final verification parent-owned.
Set `hub` `wait` `timeoutMs` to 300000 or less; after a timeout, read worker status first.
Treat a worker that stops on `usage_limit_reached` as failed.
Use `taste-tester` for taste and `reviewer` for severity; agent definitions own models.
Use Milknado only for useful persistent coordination, dependencies, or resume state; never as a duplicate TODO list.
