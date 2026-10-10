# Claude prompt hooks

`chezmoi/.chezmoidata/claude.yaml` defines one `type: prompt` hook on `Stop`.
The hook keeps a session's wheypoint current.

## Behavior

- If the session has a wheypoint and work changed after it, the hook tells the agent to update it.
- If the session has no wheypoint and work remains, the hook tells the agent to write one.
- If `stop_hook_active` is true, the hook lets the agent stop. This stops a loop after the follow-up.
- A turn that only answers a question, or a session with no change since the wheypoint, stops normally.

## Gotchas

- **Use the full model ID.** `model: haiku` fails with "There's an issue with the selected model (haiku)" (Claude Code 2.1.295). The hook then does nothing. `claude-haiku-5-5` works.
- **Claude Code wraps the prompt.** The evaluator gets "Based on the conversation transcript above, has the following stopping condition been satisfied?" and then `Condition: <prompt>`. Write the prompt as a stop condition.
- **The evaluator sees the transcript.** It can find earlier `/wheypoint` runs, not only `last_assistant_message`.
- **Use ordered steps.** A list of "condition holds if" clauses let Haiku treat "the agent asks a question" as the Q&A exemption. Numbered steps fixed it.
- **A pause that the user asked for is not completion.** Without this rule, Haiku passed a stalled task because the user told the agent to stop and ask.

## Cost

Each stop sends the session's message history to Haiku, not only the last message.
The system prompt and tool definitions are not sent.
A trivial session sends about 26k input tokens and costs about $0.0035 per stop (2026-10-10).
Cost grows with session length; prompt caching reduces repeat stops.
The user accepts this cost for now.
The cheaper option is a command hook: search the transcript for a wheypoint, and send Haiku only the user prompts and `last_assistant_message`.

## Verification

Test with `claude -p --settings <file> --debug-file <log>` in a temp directory.
Look for `Prompt hook condition was met` or `was not met` in the log.
A run that ends at `--max-turns` never fires `Stop`.

## Deploy

`dots sync` deploys from the main clone, not from a T3 worktree.
Merge the change to `main`, then run `dots sync`.
