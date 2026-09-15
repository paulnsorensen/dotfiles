# The global agents doc — what lives where and why

`agents/AGENTS.md` is the single source for cross-project agent preferences.
`dots sync` installs it as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.
The current shared agents document has no RTK import.

## Why routing detail lives in the preamble, not the agents doc

Claude and Codex receive both the shared agents doc and `agents/preamble.md`.
The preamble replaces the bundled system prompt through Claude's launcher and
Codex's `model_instructions_file`; the agents doc loads as additional context.
Duplicating routing guidance in both paid its token cost twice, so the preamble
owns task-to-tool routing and the agents doc keeps stable cross-project rules.

OMP uses its own native `~/.omp/agent/APPEND_SYSTEM.md`; its prompt contract is
not forced through the Claude/Codex preamble installer.

An earlier review removed duplicated RTK command tables.
The former `agents/RTK.md` source is no longer present; it is not part of the measured stack.

### tilth search v2 graduated to the canonical surface (2026-09-07)

Tilth main removed the temporary `tilth_search_v2` alias and the
`--search-surface` launch flag after the trial graduated. The canonical
`tilth_search` tool now uses the v2 request and response contract.[^tilth-graduation]

All managed MCP entries therefore launch `tilth --mcp --edit`. The preamble
names `tilth_search` directly. Retaining the trial flag prevents the MCP
process from starting, so the flag and tool name must move together.

[^tilth-graduation]: Tilth main `src/main.rs`, `src/mcp/mod.rs`, and `src/mcp/tools/definitions.rs`; dotfiles `agents/preamble.md:17` and `agents/mcp/registry.yaml:31-35`.

## Facts moved out of the agents doc (still true, just not standing context)

- **Agent permission modes**: `acceptEdits` and `bypassPermissions` only
  suppress the Edit/Write dialog — they do **not** bypass the Bash/MCP
  allowlist. In sandboxed environments (Conductor, fresh worktree sessions),
  isolated agents may lack `git push` / `gh pr create` permissions. Pattern:
  isolated agents do code work + commit only; the orchestrator pushes / opens
  the PR (Rule 11's worktree carve-out references this).
- **Agent nesting**: Claude Code supports 1 level of sub-agent nesting.
  Orchestrators that need to fan out should be skills — they run inline in the
  caller's context, so their `Agent()` calls are first-level.
- **Evidence-discipline rationale**: live Rule 5 consolidates the former Rules
  12/13 (absence claims and re-derivation on pushback). It remains an
  output-gate rather than a dispositional request: a negative claim must name
  its checked scope, candidate mechanisms, and evidence, while contrary user
  evidence triggers a source reread and correction. The exact longer wording
  remains in `archive/agents-rules.md`.

Related: [[architecture/agents-dir]] · [[harnesses/index]] ·
[[operations/sync-and-chezmoi]]

## Measured and enforced instruction payload

The September 15 rewrite separates stable preferences from execution rules.
`agents/AGENTS.md` owns scope, communication, coding invariants, and completion.
`agents/preamble.md` owns tools, wiki use, and delegation.
OMP keeps a separate native addendum because it loads neither shared file.
Skills own phase procedures; agent definitions own model selection.
This removes mandatory delegation, fixed grounding-call quotas, and duplicated model tables from standing context.
These removals follow ownership and simplicity, not a measured causal effect on failures.

The existing budget helper measures both tokenizers and rejects undeclared instruction sources.[^1]
Run `uv run --project agent-profile --frozen python tests/helpers/agent_instruction_budget.py agents/instruction-budgets.toml`.
The following counts cover concatenated repository-owned source text only.
They exclude native prompts, tool schemas, loaded skills, agent bodies, user messages, and external instructions.

| Source or stack | Before o200k / cl100k | After o200k / cl100k | New ceiling |
|---|---:|---:|---:|
| Shared AGENTS | 1,021 / 1,029 | 463 / 463 | 550 |
| Shared preamble | 1,227 / 1,231 | 435 / 436 | 500 |
| Global Claude and Codex | 2,248 / 2,260 | 898 / 899 | 1,050 |
| OMP addendum | 816 / 820 | 419 / 422 | 500 |

Claude's default wrappers use `--system-prompt-file`; Codex uses `model_instructions_file`.
The declared global Claude stack does not include RTK.
OMP uses `--append-system-prompt` with its managed addendum.
The new ceilings prevent size regression; they do not prove better instruction adherence.
No controlled before-and-after agent evaluation runs in this change.

### Session evidence for retained rules

Seven successful report/query calls inspect reachable logs in `[2026-08-16, 2026-09-16)`.
Calls use distinct `(harness, sessionId, tool_use_id)` keys.
Results use the same join keys, with `bool_or(is_error = 'true')` per key.

| Harness | Calls | Sessions with calls | Joined results | Flagged errors |
|---|---:|---:|---:|---:|
| Claude | 42,811 | 1,319 | 42,765 | 2,239 |
| Codex | 6,367 | 118 | 6,367 | 0 |
| OMP | 63,796 | 764 | 63,792 | 2,947 |

Observed tool dates differ: Claude ends September 13, Codex ends September 2, and OMP ends September 15.
Codex result text contains failures despite zero flagged errors; do not compare cross-harness success rates.
OMP `write` includes device calls, so its errors are not a file-write failure rate.
Inspected errors include unsupported Tilth fields, invalid edit ranges, missing paths, and unmet tool prerequisites.
These examples support current-schema checks, bounded edits, and prerequisite repair before retries.
Claude Bash has 67 repeated failed-input groups within sessions, with 80 additional flagged failures.
OMP Bash has eight such groups, with ten additional flagged failures.
These counts support checking evidence before repeating a failed call; they do not identify every repeat as waste.
Canonical delegation tables do not measure all harnesses equally, so they do not justify compulsory delegation.

## Historical budget hypothesis

No checked vendor source defines a universal optimum for the aggregate always-on global instruction stack. Anthropic instead advises keeping each `CLAUDE.md` below 200 lines because longer files consume context and reduce adherence; imports still load into context, while path-scoped rules and skills avoid unconditional loading.[^4] OpenAI documents a configurable 32 KiB combined budget for the project `AGENTS.md` chain, but current Codex source assembles global user instructions separately; the 32 KiB value is a truncation limit, not an adherence target.[^5][^6]

The earlier hypothesis proposed 4,000–5,000 tokens, a 5,500-token warning, and a 6,500-token ceiling.
The September 15 size-regression ceilings supersede that proposal; neither proposal establishes an optimal instruction size.

Primary research supports minimizing unconditional instructions but supplies no direct `AGENTS.md`/`CLAUDE.md` token threshold. IFScale found model-specific adherence loss as simultaneous constraints increased; Lost in the Middle found position-sensitive use of long-context evidence; and an EMNLP 2025 study found task degradation from longer inputs even with perfect retrieval.[^7][^8][^9] These results justify local A/B evaluation rather than treating token count alone as instruction quality.

### Allocation by responsibility

| Responsibility | Working allocation |
|---|---:|
| Cross-project invariants | 1,400–1,700 tokens |
| Tool and harness routing | 900–1,200 tokens |
| Execution workflow | 700–900 tokens |
| Communication preferences | 300–500 tokens |
| Reserve | 400–700 tokens |

The allocation is for the effective stack, not individual files. Splitting prose into files improves ownership but saves no context when every file still loads.

### What earns standing context

- Keep cross-project invariants, concise routing defaults, essential workflow gates, and compact communication preferences always on.
- Put repository commands, layout, and local gates in project `AGENTS.md`/`CLAUDE.md` files.
- Load file-type and subsystem rules conditionally where the harness supports it.
- Put procedures and phase schemas in skills or agent definitions, enforced prohibitions in settings/hooks, and rationale or learned facts in the wiki.
- Compare representative coding tasks before claiming better adherence or task quality from shorter prompts.
- Treat token ceilings as size-regression checks, not behavioral evaluation results.

The complete research report is retained in the durable cheese corpus.[^10]

[^1]: `agents/instruction-budgets.toml:1-176`, `tests/helpers/agent_instruction_budget.py:14-125`, `tests/agent-instruction-budget.bats:14-38`, `agent-profile/pyproject.toml:18-22`
[^4]: Anthropic, “How Claude remembers your project.” <https://code.claude.com/docs/en/memory> (fetched 2026-07-28).
[^5]: OpenAI, “Custom instructions with AGENTS.md.” <https://learn.chatgpt.com/docs/agent-configuration/agents-md> (fetched 2026-07-28).
[^6]: OpenAI Codex source: `codex-rs/core/src/agents_md.rs` and `codex-rs/config/src/config_toml.rs`, <https://github.com/openai/codex> (fetched 2026-07-28).
[^7]: Jaroslawicz et al., “How Many Instructions Can LLMs Follow at Once?” <https://arxiv.org/abs/2507.11538>.
[^8]: Liu et al., “Lost in the Middle: How Language Models Use Long Contexts.” <https://aclanthology.org/2024.tacl-1.9/>.
[^9]: Du et al., “Context Length Alone Hurts LLM Performance Despite Perfect Retrieval.” <https://arxiv.org/abs/2510.05381>.
[^10]: `~/.local/share/cheese/paulnsorensen-dotfiles/research/effective-global-instruction-stack/effective-global-instruction-stack.md`

*Source: effective-global-instruction-stack research · Updated: 2026-07-28 · Supersedes: treating mechanical next-boundary ceilings as ideal target sizes*

Sliced Bread has a harness-neutral source at `agents/reference/sliced-bread.md` and a normative live path at `~/.agents/reference/sliced-bread.md`. The agents-doc installer deploys that copy; Claude/Codex instructions and the OMP addendum name the same path.[^shared-reference]

Earlier revisions consolidated numbered rules into behavior and coding-principle sections.
The September 15 rewrite removes numbered-rule duplication.
The older thirteen-rule block remains at `archive/agents-rules.md`; the archive does not deploy.[^rules-archive]

[^shared-reference]: `agents/reference/sliced-bread.md`; `chezmoi/.chezmoiscripts/run_onchange_after_install-agents-doc.sh.tmpl`; `agents/AGENTS.md`; `chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md`
[^rules-archive]: `agents/AGENTS.md`; `archive/agents-rules.md`; `archive/README.md`
