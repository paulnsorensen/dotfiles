---
status: reviewed
last_verified: 2026-08-07
confidence: high
sources:
  - agents/hooks/registry.yaml
  - chezmoi/.chezmoidata/claude.yaml
  - agents/hooks/doom-loop-guard.sh
  - agents/lib/doom-loop-guard.js
  - chezmoi/dot_omp/private_agent/extensions/doom-loop-guard.ts
  - tests/doom-loop-guard.bats
  - tests/extensions/doom-loop-guard.test.mjs
  - https://openrouter.ai/docs/agent-sdk/call-model/doom-loop-detection
  - https://code.claude.com/docs/en/hooks
  - https://learn.chatgpt.com/docs/hooks
  - https://github.com/can1357/oh-my-pi/blob/main/docs/hooks.md
---
# Cross-harness doom-loop detection

Claude, Codex, and OMP share one stateful detector for repeated identical local tool calls. Harness adapters translate its four verdicts—allow, observe, block, and stop—into each runtime's native hook response.[^1]

## Detection contract

A repeat is the same tool name plus recursively key-sorted JSON input within one user request. Request scope comes from Claude's `prompt_id`, Codex's `turn_id`, or an OMP `agent_start` generation; replayed delivery of one `tool_use_id`/`toolCallId` counts once. Counts are tracked per tool, so intervening calls to another tool do not reset the streak; changed input resets only that tool. State lives under the dotfiles cache rather than the process, preserving counts across hook subprocesses while the scope prevents carry-over into later requests.[^2]

The thresholds follow OpenRouter's recommended ladder:

1. First call: allow.
2. Second identical call: observe and steer the agent.
3. Third through fifth: block.
4. Sixth and later: stop where the harness supports stopping.

Task delegation and polling tools are exempt. They can legitimately repeat identical inputs while waiting for another worker and would otherwise produce false positives.[^3]

State filenames hash the harness/session identity, state files are mode 0600, the directory is mode 0700, and retention is capped by age, session-file count, and tracked-tool count. Malformed payloads, missing identity, unavailable Node, state errors, and lock contention fail open.[^4]

## Harness adapters

Codex derives its catch-all PreToolUse entry from agents/hooks/registry.yaml. Claude's wholesale settings source declares the corresponding entry in chezmoi/.chezmoidata/claude.yaml. The shell bridge loads the same deployed Node module in either harness.[^5]

Claude can stop execution at the sixth call with top-level continue: false. Codex does not support that field for PreToolUse, so its stop-strength verdict remains a denial whose reason identifies the stop threshold.[^6]

OMP does not consume the shared hook registry. Its native tool_call extension imports the detector deployed under ~/.claude/lib, steers on observe, returns { block: true, reason } on block, and combines ctx.abort() with a block at the stop threshold.[^7]

## Deliberate limits

This reproduces local tool-call loop detection, not OpenRouter's text-response or server-tool repetition checks. Those events do not pass through these local PreToolUse/tool_call surfaces.

Distinct calls in one parallel tool batch have distinct invocation IDs and therefore count separately. The shared local hook surfaces do not expose a uniform batch identifier, so this implementation cannot reproduce OpenRouter's batch-level deduplication across all three harnesses.[^8]

## Verification

The Bats suite pins thresholds, canonical inputs, per-tool reset behavior, request-scope reset, invocation replay deduplication, session isolation, exemptions, harness-specific stop responses, and fail-open behavior. The Node extension test pins OMP request reset, steering, blocking, and abort behavior.[^9]

[^1]: agents/lib/doom-loop-guard.js:114-209, chezmoi/dot_omp/private_agent/extensions/doom-loop-guard.ts:18-62
[^2]: agents/lib/doom-loop-guard.js:24-70, agents/lib/doom-loop-guard.js:147-200; [OpenRouter doom-loop detection](https://openrouter.ai/docs/agent-sdk/call-model/doom-loop-detection); [Claude prompt IDs](https://code.claude.com/docs/en/hooks); [Codex turn IDs](https://learn.chatgpt.com/docs/hooks); [OMP lifecycle events](https://github.com/can1357/oh-my-pi/blob/main/docs/hooks.md)
[^3]: agents/lib/doom-loop-guard.js:15-40
[^4]: agents/lib/doom-loop-guard.js:46-112, agents/lib/doom-loop-guard.js:132-190
[^5]: agents/hooks/registry.yaml:107-119, chezmoi/.chezmoidata/claude.yaml:55-104, agents/hooks/doom-loop-guard.sh:1-14
[^6]: [Claude hooks](https://code.claude.com/docs/en/hooks); [Codex hooks](https://learn.chatgpt.com/docs/hooks)
[^7]: chezmoi/dot_omp/private_agent/extensions/doom-loop-guard.ts:18-62; [OMP hooks](https://github.com/can1357/oh-my-pi/blob/main/docs/hooks.md)
[^8]: [OpenRouter doom-loop detection](https://openrouter.ai/docs/agent-sdk/call-model/doom-loop-detection); [Claude hooks](https://code.claude.com/docs/en/hooks); [Codex hooks](https://learn.chatgpt.com/docs/hooks); [OMP hooks](https://github.com/can1357/oh-my-pi/blob/main/docs/hooks.md)
[^9]: tests/doom-loop-guard.bats:55-126, tests/extensions/doom-loop-guard.test.mjs:49-96

_Source: OpenRouter detector semantics adapted to the native Claude, Codex, and OMP hook surfaces · Updated: 2026-08-07_
