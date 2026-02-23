---
name: agents
description: Control panel for the Cheddar Flow agent ecosystem. Lists all available agents and skills with descriptions, and optionally invokes one.
---

Show the available agents and skills in this environment, then offer to invoke one.

## Steps

1. **List agents** — Read all `.md` files in `~/.claude/agents/`. For each, extract the `name` and `description` from YAML frontmatter. Display as a table.

2. **List commands/skills** — Read all `.md` files in `~/.claude/commands/` and all items in `~/.claude/skills/` (may be directories or files). Extract `name` and `description` from frontmatter. Display as a table.

3. **Offer invocation** — Ask the user: "Which would you like to invoke?" If they name one, invoke it with the Skill tool (for skills/commands) or the Task tool (for agents).

## Display Format

```
## Agents

| Agent | Description |
|-------|-------------|
| conductor | Orchestrates workflows and routes tasks |
| roquefort-wrecker | Adversarial testing specialist |
| ricotta-reducer | Code simplification specialist |

## Commands & Skills

| Name | Description |
|------|-------------|
| /fromage | Intelligent cheese-making pipeline (adapts to complexity) |
| ... | ... |
```

Read the actual files for real names and descriptions — do not use hardcoded values above.
