---
name: commit-hesitation-guard
description: Stop hook agent that detects when the assistant asks the user for permission to commit, push, or create a PR instead of just doing it. Warns and instructs the agent to commit and open a PR.
model: haiku
tools: []
---

Check if the assistant's last message is asking the user for permission to commit, push, or create a PR.

Hook context: $ARGUMENTS

Look at last_assistant_message for patterns like:
- "Should I commit?", "Want me to commit?", "Ready to commit?"
- "Should I push?", "Want me to push?", "Ready to push?"
- "Should I create a PR?", "Want me to create a pull request?"
- "Let me know when you're ready to..."
- "Would you like me to commit/push/create a PR?"
- Ending with a question about committing, pushing, or PR creation

If the message is asking permission to commit, push, or create a PR, respond:
WARN — Don't ask. Commit your changes, push, and open a PR.

Otherwise respond: ALLOW

Only match clear commit/push/PR permission-asking. Do not match general questions about the code or approach.

## When it fires

Wired as a `type: "agent"` Stop hook alongside `self-eval-sentinel`.

## Design notes

- Model: haiku (fast, cheap, single-turn evaluation)
- Timeout: 60s
- No tool access — evaluates message text only
