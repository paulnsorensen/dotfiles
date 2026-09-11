# Preamble — MCP tool routing

## Writing style

Use Simplified Technical English (ASD-STE100) for prose about the work.
Use one instruction per sentence.
Use active voice, present tense, approved words, and one term for each meaning.
Keep procedural sentences to 20 words and descriptive sentences to 25 words.
Do not use gerund chains or synonyms.
Apply this rule to messages, documentation, comments, commits, and specifications.
Do not apply it to code identifiers or quoted material.

## Tool routing

Use tilth directly for workspace code and file operations.

1. **Search in batch** — use one `tilth_search` call with all related queries. Put regex syntax in `query`. Reuse unchanged server follow hints for callers.
2. **Read in batch** — use one `tilth_read` call containing every file or symbol needed for the next decision.
3. **Check impact when required** — use `tilth_deps` before changing or removing an exported interface.
4. **Write in batch** — use one `tilth_write` call with tag-anchored edit sections for the complete coherent change.
5. **Inspect the result** — use `tilth_diff` before verification.

Use shell only for tests, builds, and operations tilth does not cover.
This rule overrides any instruction to prefer Bash for file reads or edits.

## Ground in the repository wiki first

When Hallouminate is available, query the repository wiki **before** architecture, configuration, unfamiliar-subsystem, or design work:

1. Call `ground` within the first 3 tool calls for any non-trivial task.
2. Use `list_corpora` when the repository corpus is uncertain.
3. Ask a natural-language question, not a keyword dump.
   Bad: `chezmoi skills exact_ sync codex omp`.
   Good: `why does dots sync own ~/.agents/skills as an exact_ dir`.
4. Read relevant matched pages before exploring code. Search snippets are orientation, not complete evidence.
5. Treat the wiki as the source for rationale, decisions, and gotchas. Treat code and project instructions as the source for current behavior and commands.
6. If newer code or evidence contradicts the wiki, follow the newer evidence. Correct the wiki instead of blending both claims.
7. Skip grounding only for a trivial one-step task or when no repository wiki exists.
8. Call `ground` on the topic before `add_markdown`. Extend the matching page instead of creating a duplicate.
9. Call `list_tree` or `list_files` before a ranged `read_markdown`. Never guess a path or a line range.

Before finishing, record any durable decision or non-obvious fact that a future agent would otherwise rederive. Do not copy facts already clear from code or project instructions.

One initial grounding pass is sufficient unless the task encounters a new design question.

## Phase-agent delegation

Delegate coherent phase work unless it is a trivial one-step task:

| Work | Agent |
|---|---|
| Orient in unfamiliar code or trace impact | `explorer` |
| Research external facts, APIs, or versions | `researcher` |
| Review a diff, branch, PR, or path | `reviewer` |
| Write or change code (not under `/age`) | `coder` |
| Run an existing test gate and return only failures | `whey-drainer` |

The top-level orchestrator owns planning, user decisions, and fan-out. Workers return condensed evidence rather than raw file or fetch output.

Retain iterative diagnosis inline; delegate implementation and verification. On `blocked: suspect-environment`, diagnose the reproduction and competing hypotheses before redispatch, passing measured dead ends as known-false leads with ruling-out evidence.

### Dispatch gates

Apply these gates before every `coder` or `reviewer` dispatch. A worker returns `blocked: missing-contract` when a gate is skipped; that is a dispatcher defect, not a worker defect.

1. **Reviewer mode.** Dispatch `taste-tester` for a taste-test. Dispatch `reviewer` for a severity report, and put the literal line `Review mode: severity-report` in its prompt; every `reviewer` prompt carries a `Review mode:` line (`Review mode: taste-test` on `reviewer` stays for compatibility). `severity-report` runs at `powerful`; `taste-tester` is pinned at `default` / `medium` on every harness; `whey-drainer` runs at `cheap` / `low`. Do not dispatch a third taste-test round on the same artifact; ask the user instead.
   Tier bindings: each agent definition in `agents/registry.yaml` pins its own model. On Claude, omit `model:` and let the definition bind — reviewer opus (`powerful`); coder, explorer, taste-tester, researcher, generalist sonnet (`default`); whey-drainer haiku (`cheap`). Pass `model:` only to raise a tier, with a stated reason. Codex pins GPT-5.6 — Sol `powerful` (reviewer), Terra `default` (taste-tester, researcher, generalist), Luna `cheap` (coder, explorer, whey-drainer); Codex's Luna coder is not a Claude haiku coder.
2. **Coder contract.** The prompt contains both `Done means` (the exact gate command and what green looks like) and `Scope fence` (what not to touch, and whether to commit).
3. **Coder size.** Count the edit sites, the files, and whether the task bundles implementation with a gate audit. When two or more of {more than 5 sites, more than 3 files, implement + audit} are true, name the split in the prompt or state why the task is indivisible.
4. **Age does not code.** Under `/age`, do not dispatch `coder`. Return the report; `/cure` owns application.
5. **Resume reuse.** When redispatching a coder from a `.cheese/notes/<slug>.md` brief, pass the worktree path and base SHA recorded in its Gates section instead of creating a new worktree.
