# Cross-harness skill layout

Checked: 2026-09-12. `self-update` rewrites this date and this file.
Read when the Portability lens fires, in `add`, and in `self-update`.

## Layout

- One level deep: `skills/<name>/SKILL.md`. The directory name is the command name on every host; keep `name:` equal to it.
- Sidecars: `references/` (read on a trigger), `scripts/` (dependency-free), `assets/`, and `agents/openai.yaml` (Codex policy).
- Deploy targets from this repo: Claude `~/.claude/skills` (chezmoi), OMP `~/.omp/agent/skills` (chezmoi), and `~/.agents/skills` for Codex, Cursor, and Copilot (`npx skills add --copy`). All three come from `claude.skills` in `chezmoi/.chezmoidata/claude.yaml`.
- OMP scans providers non-recursively and resolves a duplicate name by priority: native `.omp` > Claude > Codex/`.agents`.
- Zed's own agent reads `~/.agents/skills`; ACP external agents inside Zed (Claude, Codex, OMP) use their native trees. Nothing extra is needed for Zed.
- Pi reads `~/.pi/agent/skills` and `~/.agents/skills`; commands render as `/skill:<name>`.

## Frontmatter matrix

| Field | Spec | Claude | Codex | OMP | Pi | Zed |
|---|---|---|---|---|---|---|
| `name` (≤64, kebab) | required | yes | yes | yes | yes | yes |
| `description` (≤1024) | required | yes; listing truncates `description`+`when_to_use` at 1536 | yes (implicit match) | yes | yes | yes |
| `license`, `compatibility` (≤500), `metadata` (string map) | optional | kept | kept | kept | kept | kept |
| `allowed-tools` | optional | enforced | accepted | accepted | accepted | accepted |
| `disable-model-invocation` | — | yes | **no** → `agents/openai.yaml` `policy.allow_implicit_invocation: false` | yes (`disableModelInvocation`) | ignored | ignored |
| `user-invocable`, `argument-hint`, `arguments`, `model`, `effort`, `context: fork`, `agent`, `background`, `hooks`, `paths`, `shell`, `when_to_use` | — | yes | ignored | ignored | ignored | ignored |
| `$ARGUMENTS`, `$0`, `$N` substitution | — | yes | no; free text follows the mention | no | no | no |

Unknown keys never break a load on any surveyed host.
Claude's cloud Skills API rejects non-spec keys; that surface is out of scope for repo skills.

## Rules (the Portability lens)

1. Use only spec fields plus the Claude extensions above. Do not invent keys.
2. A user-only skill sets `disable-model-invocation: true` **and** ships `agents/openai.yaml` with `allow_implicit_invocation: false`.
3. State arguments with `argument-hint`. Parse them in prose as "the text after the skill name". Never depend on `$ARGUMENTS`.
4. Reference helpers by repo-relative path (`skills/<name>/scripts/...`) or by the loaded `SKILL.md` directory. Never use `${CLAUDE_SKILL_DIR}`.
5. Cross-reference skills by `/name`. Never `@file`.
6. Name a sub-agent dispatch by contract first (fresh context, read-only, tier, synchronous), then show the host syntax as an example (`Agent(...)`, Codex `spawn_agent`, OMP `task(...)`).
7. State a GitHub action first, then the transport: host primitive, then `gh`.
8. Keep the body ≤5k tokens (o200k). Keep references one level deep, each with a read trigger.
9. Model policy in this repo: a model-invoked skill sets `model` + `effort` (haiku/low, sonnet/medium, opus/high); a user-only skill omits both and inherits the session model.
10. Put the trigger in the first sentence of `description`, in third person, with a "Do NOT use for" clause.

## Sidecar

```yaml
# skills/<name>/agents/openai.yaml
interface:
  display_name: "<Name>"
  short_description: "<one line>"
policy:
  allow_implicit_invocation: false
```

## Template (`add`)

```markdown
---
name: <name>
description: >
  <Verb> <object> <outcome>. Use when the user says "<phrase 1>", "<phrase 2>",
  "<phrase 3>", or invokes /<name>. Do NOT use for <adjacent task> (/<other>).
# user-only skills:
# disable-model-invocation: true
# argument-hint: "<args>"
# model-invoked skills:
# model: sonnet
# effort: medium
license: MIT
metadata:
  author: <handle>
---

# <name>

<One sentence: what this produces.>

## Inputs

<argument grammar; "the text after the skill name">

## Flow

1. <step> — done when <check>.

## Output

<format block>

## What this skill never does

- <boundary>

## References

- `references/<file>.md` — read when <trigger>.
```

## Sources

`self-update` queries each of these for changes since `Checked:`.

| Host | Source | Re-check |
|---|---|---|
| Claude Code | <https://code.claude.com/docs/en/skills> | frontmatter fields, listing truncation, line guidance |
| Agent Skills spec | <https://agentskills.io/specification> | field set and limits |
| Anthropic skills repo | <https://github.com/anthropics/skills> | reference layouts, skill-creator |
| Codex | <https://learn.chatgpt.com/docs/build-skills> | scan paths, `$skill` invocation, `agents/openai.yaml` |
| OMP | <https://github.com/can1357/oh-my-pi/blob/main/docs/skills.md> | provider priority, honored fields, `/skill:` |
| Pi | <https://pi.dev/docs/latest/skills> | paths, validation, `/skill:` |
| Zed | <https://zed.dev/docs/ai/skills> and <https://zed.dev/docs/ai/external-agents> | native vs ACP scope |
| skills CLI | <https://github.com/vercel-labs/skills> | per-agent path table, compatibility matrix |

Research record: `.cheese/research/cross-harness-skill-layout.md`.

## Rejected

- `${CLAUDE_SKILL_DIR}` as a portable helper path — Codex passes the literal string (easy-cheese `harness-portability.md`).
