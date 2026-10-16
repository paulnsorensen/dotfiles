# Sources

Read when a claim needs its source URL. Fetch date for all sources: 2026-10-06.

| ID | Source |
|---|---|
| s1 | <https://www.anthropic.com/engineering/building-effective-agents> |
| s2 | <https://www.anthropic.com/engineering/code-execution-with-mcp> |
| s3 | <https://www.anthropic.com/engineering/advanced-tool-use> |
| s4 | <https://code.claude.com/docs/en/hooks-guide> |
| s5 | <https://platform.claude.com/docs/en/build-with-claude/prompt-caching> |
| s6 | <https://docs.claude.com/en/docs/build-with-claude/structured-outputs> |
| s7 | <https://platform.claude.com/docs/en/agent-sdk/structured-outputs> |
| s8 | <https://python.useinstructor.com/concepts/retrying> |
| s9 | <https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents> |
| s10 | <https://code.claude.com/docs/en/agent-sdk/agent-loop> |
| s11 | <https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons> |
| s12 | <https://www.anthropic.com/engineering/multi-agent-research-system> |
| s13 | <https://github.com/github/spec-kit/blob/main/spec-driven.md> |
| s14 | <https://kiro.dev/docs/specs/> |
| s15 | <https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool> |
| s16 | <https://claude.com/blog/the-advisor-strategy> |
| s17 | <https://code.claude.com/docs/en/workflows> |

The Workflow runtime facts live in the built-in workflow-authoring skill. It ships inside the Claude Code CLI, and this skill does not copy it.
The local exemplars come from `claude/workflows/*.js` in the dotfiles repository. Other repositories do not have these files.
Local measurement 2026-10-15: 1,021 Workflow agents and 4,699 Agent-tool sub-agents, from `~/.claude/projects/*/*/subagents/workflows/wf_*/agent-*.jsonl` transcripts on the author's machine.
Session analytics 2026-10-16: 48 move-my-cheese runs over 7 sessions, from 2026-10-12 to 2026-10-16. No run landed its plan end to end.
