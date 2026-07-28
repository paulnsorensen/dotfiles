# The global agents doc — what lives where and why

`agents/AGENTS.md` is the single source for cross-project agent preferences.
`dots sync` (via `chezmoi/.chezmoiscripts/run_onchange_after_install-agents-doc.sh.tmpl`)
copies it verbatim to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.
`agents/RTK.md` deploys to `~/.claude/RTK.md` only — RTK's rewrite hook lives in
the Claude harness, so Codex gets no RTK doc (the `@RTK.md` import at the bottom
of AGENTS.md is benign literal text there).

## Why routing detail lives in the preamble, not the agents doc

Both `agents/AGENTS.md` (as `~/.claude/CLAUDE.md`) and `agents/preamble.md` are
standing context in their Claude/Codex sessions — the preamble replaces the bundled system
prompt (Claude Code via `--system-prompt-file` in `zsh/claude.zsh`; Codex via
`model_instructions_file` in `~/.codex/config.toml`; opencode via
`~/.config/opencode/agents/build.md`), and the agents doc loads on top of it.
Duplicating routing guidance across both paid its token cost twice per session
for zero extra signal (2026-07 "loop and harness" review). Decision: the
preamble **owns** the task-to-tool tables, the serena-vs-tilth edit-shape
guide, the Codex `exec_command` rule, and the routing self-check; the agents
doc keeps only the two-MCP split and a pointer. When editing routing guidance,
edit the preamble — don't re-grow the section in AGENTS.md.

Same review deduped RTK to one canonical doc (`agents/RTK.md`): the repo-root
`RTK.md` and the `rtk init` block in the repo `CLAUDE.md` were deleted (the
zsh hook auto-rewrites commands, so per-command tables carried no signal). If
`rtk init` is ever re-run it will re-add the block — remove it again.

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

`tiktoken` 0.13.0 measures every repo-owned instruction source with both `o200k_base` and `cl100k_base`. `agents/instruction-budgets.toml` is the fail-closed inventory: adding a discovered `AGENTS.md`, `CLAUDE.md`, profile prompt, OMP addendum, or Copilot instruction without a declared ceiling fails `tests/agent-instruction-budget.bats`. The original ceilings were mechanical next-boundary starting points; they remain compatibility limits, not claims about ideal instruction size. Fixed ceilings move only through deliberate review.[^1]

| Default/repo stack | o200k | cl100k | ceiling |
|---|---:|---:|---:|
| Global Codex (`agents/AGENTS.md` + preamble) | 1,978 | 1,990 | 6,750 |
| Global Claude (+ `agents/RTK.md`) | 2,206 | 2,219 | 7,000 |
| This-repo Codex (+ root `AGENTS.md`) | 2,913 | 2,924 | 9,250 |
| This-repo Claude (+ RTK + root wrapper/doc) | 3,203 | 3,215 | 9,750 |
| Nested `agent-profile/` Codex (+ path-scoped `AGENTS.md`) | 3,463 | 3,473 | 10,000 |
| OMP addendum | 887 | 896 | 1,000 |

The previous audit missed three repo-owned classes: `agent-profile/AGENTS.md`, the selected profile prompts under `profiles/*/{AGENTS,CLAUDE}.md`, and Copilot's repo/path instructions. All are source-bounded now. `profiles/mgmt/CLAUDE.md` remains bounded but is excluded from injected stacks because its non-isolated profile does not consume `system_prompt`. The selected profile stacks are conservative this-repo maxima; the actual renderer paths are Claude `--append-system-prompt-file`, Codex `model_instructions_file`, and OpenCode additive `instructions`.[^2]

Copilot has separate 4,500-token ceilings for its coding and review maxima; OMP remains separate because it disables external agents-doc discovery. Conductor's app-owned system/workspace instruction is outside the repo-owned manifest. The repo's Conductor settings only define `just check`, while `agents/preamble.md` reaches Claude through the separate `_cc_base` zsh launcher; do not count that preamble in a Conductor launch without inspecting the live app/user launch configuration.[^3]

The counts concatenate source text and exclude harness-native prompts, tool schemas, invoked skills, sub-agent bodies, user messages, and external personal/organization instructions.

## Research-backed working budget hypothesis

No checked vendor source defines a universal optimum for the aggregate always-on global instruction stack. Anthropic instead advises keeping each `CLAUDE.md` below 200 lines because longer files consume context and reduce adherence; imports still load into context, while path-scoped rules and skills avoid unconditional loading.[^4] OpenAI documents a configurable 32 KiB combined budget for the project `AGENTS.md` chain, but current Codex source assembles global user instructions separately; the 32 KiB value is a truncation limit, not an adherence target.[^5][^6]

The working local hypothesis is **4,000–5,000 tokens target**, **5,500 warning**, and **6,500 post-rewrite policy ceiling** for the effective repo-owned global stack. This is an evaluation target, not current production policy or a model limit. Current compatibility caps may remain higher while prompt reductions are tested.

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
- Before lowering production caps, compare the current and shortened stacks on representative coding tasks; measure instruction adherence, contradictions, task quality, and context cost with both configured tokenizers.

The complete research report is retained in the durable cheese corpus.[^10]

[^1]: `agents/instruction-budgets.toml:1-176`, `tests/helpers/agent_instruction_budget.py:14-125`, `tests/agent-instruction-budget.bats:14-38`, `agent-profile/pyproject.toml:18-22`
[^2]: `agent-profile/AGENTS.md:1-43`, `agent-profile/agent_profile/overlay.py:247-290`, `agent-profile/agent_profile/overlay.py:402-424`, `agent-profile/agent_profile/overlay.py:661-695`, `profiles/mgmt/profile.yaml:6-11`
[^3]: `.github/copilot-instructions.md:1-70`, `.github/instructions/*.instructions.md`, `chezmoi/.chezmoidata/omp.yaml:20-24`, `.conductor/settings.toml:1-3`, `zsh/claude.zsh:17-46`
[^4]: Anthropic, “How Claude remembers your project.” <https://code.claude.com/docs/en/memory> (fetched 2026-07-28).
[^5]: OpenAI, “Custom instructions with AGENTS.md.” <https://learn.chatgpt.com/docs/agent-configuration/agents-md> (fetched 2026-07-28).
[^6]: OpenAI Codex source: `codex-rs/core/src/agents_md.rs` and `codex-rs/config/src/config_toml.rs`, <https://github.com/openai/codex> (fetched 2026-07-28).
[^7]: Jaroslawicz et al., “How Many Instructions Can LLMs Follow at Once?” <https://arxiv.org/abs/2507.11538>.
[^8]: Liu et al., “Lost in the Middle: How Language Models Use Long Contexts.” <https://aclanthology.org/2024.tacl-1.9/>.
[^9]: Du et al., “Context Length Alone Hurts LLM Performance Despite Perfect Retrieval.” <https://arxiv.org/abs/2510.05381>.
[^10]: `~/.local/share/cheese/paulnsorensen-dotfiles/research/effective-global-instruction-stack/effective-global-instruction-stack.md`

_Source: effective-global-instruction-stack research · Updated: 2026-07-28 · Supersedes: treating mechanical next-boundary ceilings as ideal target sizes_

Sliced Bread now has a harness-neutral source at `agents/reference/sliced-bread.md` and a single normative live path at `~/.agents/reference/sliced-bread.md`. The agents-doc installer deploys that copy, while global Claude/Codex instructions and OMP's compact addendum name the same path.[^shared-reference]

The global rules were consolidated from thirteen overlapping rules to five operational rules after their distinct requirements moved into the earlier behavior and coding-principle sections. The last-written thirteen-rule block remains verbatim at `archive/agents-rules.md`; the archive does not deploy.[^rules-archive]

[^shared-reference]: `agents/reference/sliced-bread.md`; `chezmoi/.chezmoiscripts/run_onchange_after_install-agents-doc.sh.tmpl`; `agents/AGENTS.md:44-57`; `chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md`
[^rules-archive]: `agents/AGENTS.md:71-95`; `archive/agents-rules.md`; `archive/README.md`
