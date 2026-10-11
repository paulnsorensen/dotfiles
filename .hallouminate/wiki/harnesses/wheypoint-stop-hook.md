# Wheypoint Stop hook

Claude, Codex, and OpenCode use one deterministic wheypoint policy.[^policy]
The policy keeps Q&A turns silent and requests a checkpoint only after confirmed file changes.
The policy replaces model verdicts, not task-completion checks.

## Shared policy

The shared classifier accepts completed mutations and successful `wheypoint.pyz checkpoint` results.[^policy]
A Skill invocation or quoted `Wheypoint dropped:` line does not prove persistence.
A replayed checkpoint does not clear later work.
Relative and absolute `.cheese/` paths do not count.
Absolute `/tmp/` paths do not count, including source paths in temporary worktrees.

- No confirmed mutation after the checkpoint: allow the turn to end.
- A checkpoint exists and a later mutation completes: request an update.
- No checkpoint exists and a mutation completes: request a checkpoint only when Git reports uncommitted work.
- No checkpoint exists and the tree is clean: allow the turn to end.

The policy recognizes supported file tools and Git commit or push commands.
It handles Git `-C` and `-c` options.
Failed calls and read-only delegation do not count as mutations.

## Native adapters

Claude reads successful tool results in the root transcript and verified session-linked child transcripts.[^claude]
The executable sources a small shell library.
The library runs the shared Node classifier.
The native Stop response uses `decision: block`.

Codex records completed PostToolUse events in a private per-session journal.[^codex]
The journal stores event kinds and call identifiers, not paths, commands, or tool output.
Nested code-mode calls use the same event path.
Subagent hooks use the parent session identifier.
The Stop hook consumes these events instead of guessing from JavaScript source.

OpenCode reads completed v2 tool records and verified child-session records.[^opencode]
It sends a queued synthetic follow-up after a successful root execution.
OpenCode has no synchronous Stop veto.
The plugin creates no checker session and makes no model call.

## Loop and error handling

Claude and Codex allow a Stop continuation when `stop_hook_active` is true.[^policy]
OpenCode sends at most one follow-up for a root turn.[^opencode]
The plugin rechecks the current turn and execution state before sending.
Child sessions do not receive their own follow-up.
Failed and interrupted executions do not receive a follow-up.

Errors fail open.
Unexpected evaluation failures produce a bounded stderr diagnostic without transcript contents.
`WHEYPOINT_STOP_GATE=0` disables the check.

## Why model checks are removed

The earlier prompt check judged unfinished work on every stop.
That check requested checkpoints after Q&A turns that changed no files.
A separate hook cannot suppress the prompt hook because event hooks run in parallel.
The deterministic policy removes that inference cost and avoids nested model-hook side effects.

Trade-off: a file-change rule does not assess unfinished tasks or changed decisions without file changes.
An existing checkpoint requires an update after later mutations, even when the work is complete.

## Deploy and verify

Run `DOTFILES_DIR=<checkout> bin/dots sync --no-upgrade` to deploy this checkout.[^deploy]
The default `dots sync` uses the main clone.
Restart the affected harnesses after deployment.
In Codex, review and trust new or changed hooks with `/hooks`.[^trust]

Tests cover native hook payloads, linked children, checkpoint results, errors, deployment, and queued-follow-up races.[^tests]
Authenticated live model turns are not part of the offline checks.

[^policy]: agents/lib/wheypoint-stop-gate.cjs
[^claude]: agents/hooks/wheypoint-stop-gate.sh; agents/lib/wheypoint-stop-gate.sh; chezmoi/.chezmoidata/claude.yaml
[^codex]: agents/hooks/registry.yaml; agents/lib/wheypoint-stop-gate.cjs; <https://developers.openai.com/codex/hooks>
[^opencode]: chezmoi/dot_config/opencode/plugins/wheypoint-idle.js; chezmoi/dot_config/opencode/lib/wheypoint-stop-gate.cjs.tmpl
[^deploy]: bin/dots:7-9; .sync:23-27
[^trust]: <https://developers.openai.com/codex/hooks#review-and-trust-hooks>
[^tests]: tests/wheypoint-stop-gate.bats; tests/opencode-wheypoint.test.js; tests/opencode-wheypoint-guards.test.js; tests/opencode-config.bats

_Source: PR #1253 review and user-approved cross-harness policy · Updated: 2026-10-11 · Supersedes: Claude-only attempt-based gate_
