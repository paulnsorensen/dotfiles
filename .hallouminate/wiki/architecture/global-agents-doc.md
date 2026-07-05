# The global agents doc — what lives where and why

`agents/AGENTS.md` is the single source for cross-project agent preferences.
`dots sync` (via `chezmoi/.chezmoiscripts/run_onchange_after_install-agents-doc.sh.tmpl`)
copies it verbatim to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.
`agents/RTK.md` deploys to `~/.claude/RTK.md` only — RTK's rewrite hook lives in
the Claude harness, so Codex gets no RTK doc (the `@RTK.md` import at the bottom
of AGENTS.md is benign literal text there).

## Why routing detail lives in the preamble, not the agents doc

Both `agents/AGENTS.md` (as `~/.claude/CLAUDE.md`) and `agents/preamble.md` are
standing context in every session — the preamble replaces the bundled system
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
- **Rules 12/13 rationale** (absence claims / re-derive on pushback): they are
  phrased as output-gates rather than "be careful / be humble" because
  dispositional instructions don't survive — a model reads "be rigorous",
  reports compliance, and fails identically, since nothing checks it. An
  instruction demanding a specific artifact in the response (a per-candidate
  citation; a re-read before reply) is verifiable from the output alone,
  regardless of what the model believes it did. Calibration you can't audit is
  calibration that drifts. The Succinctness send-gate in the same doc follows
  the identical pattern.

Related: [[architecture/agents-dir]] · [[harnesses/index]] ·
[[operations/sync-and-chezmoi]]
