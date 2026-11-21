# Worktree command names

The worktree skills and shell commands share the `wt` prefix. The operator chose this scheme on 2026-11-21. It extends the existing `wt` and `wt-git` names.

## Names

| Kind | Current | Former |
| --- | --- | --- |
| Skill | `/wt` | `/worktree-session` |
| Skill | `/wt-find` | `/worktree-find` |
| Skill | `/wt-triage` | `/worktree-triage` |
| Skill and shell | `wt-git` | (same) |
| Shell | `wt`, `wto`, `wtm` | (same) |
| Shell | `wt-find`, `wt-check`, `wt-rm`, `wt-sweep` | `ccw-find`, `ccw-check`, `ccw-rm`, `ccw-sweep` |
| zsh | `wt-clean`, `wt-ls` | `ccw-clean`, `ccw-ls` |
| Env | `WT_SWEEP_*` | `CCW_SWEEP_*` |

`ccw` keeps its name. It is a Claude launcher in the `cc` family (`cc`, `ccc`, `ccr`, `ccp`), not a worktree tool.

## Why not `/thread`

T3 and Claude Desktop already use "thread" and "session" for conversations, and `/steel-thread` is a different skill. `/wt-find` and `/wt-triage` act on worktrees, not threads.

## Compatibility

- `bin/ccw-*` are symlinks to `bin/wt-*`. The scripts locate `bin/lib/` through `BASH_SOURCE`, which works through the symlink.
- `zsh/claude.zsh` keeps `ccw-*` aliases that point to the `wt-*` names.
- `wt_env` in `bin/lib/worktree.sh` reads `WT_<suffix>`, then `CCW_<suffix>`, then the default. Validation messages name the `WT_SWEEP_*` form.
- Claude permission lists allow both `Bash(ccw-sweep:*)` and `Bash(wt-sweep:*)`.
- Skill descriptions name the former skill names, so a request that names an old skill still routes. A bare `/worktree-session` slash command does not resolve, because Claude Code looks up slash commands by skill name.
- Most `tests/wt-sweep.bats` cases still run `ccw-sweep` with `CCW_SWEEP_*` settings. This keeps the legacy path covered. The "Renamed entry point" cases cover `wt-sweep` and `WT_SWEEP_*`.
- The last output line of `wt-sweep` changed from `SUMMARY ccw-sweep:` to `SUMMARY wt-sweep:`, also through the `ccw-sweep` symlink. No consumer in the repo reads the old prefix. An outside script that matches it must change.

## Kept on purpose

`wt-sweep` keeps internal `ccw-sweep` names that are on-disk state, not interface:

- the archive default `~/.local/share/ccw-sweep/cheese`, so earlier archives stay together
- the `refs/ccw-sweep/` fetch namespace, which its cleanup deletes on every run
- the probe commit identity and temp-directory prefix

Renaming them would orphan existing data or leave stale refs.

## Model pin

`/wt` sets `model: inherit` and no `effort:`. A skill's `model` and `effort` apply for the rest of the turn ([Claude Code skills docs](https://code.claude.com/docs/en/skills.md)). Agents call `/wt` mid-task, so a `sonnet` pin moved the remaining verification and transfer work off an Opus session. `tests/agent-skill-model-effort.bats` accepts `inherit` only when `effort:` is absent. The operator approved this guard change on 2026-11-21.

## Related

- [[harnesses/claude-desktop-sessions]]
- [[architecture/global-agents-doc]]
