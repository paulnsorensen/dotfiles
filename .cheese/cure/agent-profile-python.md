status: ok
next: done
artifact: .cheese/cure/agent-profile-python.md
4 fixed (1 high + 3 medium), 4 deferred (low); gate green — 187 pytest pass.

## Cure Report

Phase 6 CURE worker for `/cheese-factory` spec `agent-profile-python`. Auto-mode, `--stake medium+`. Fixed every finding at HIGH or MEDIUM; left the 4 low findings documented as deferred. Sub-agent override honored: applied fixes, wrote this report, did not chain forward to `/age`.

### Applied
- **[correctness:high] pyproject.toml console script bypasses `registry.install()`** (`agent-profile/pyproject.toml:11-12`): removed the `[project.scripts] ap = "agent_profile.cli:main"` entry entirely. The `-m agent_profile` path (`__main__.install()` → `main()`) is the only supported entrypoint and the one the `ap` shim uses; the console script ran with `RENDERERS = {}` and silently rendered nothing. Spec open-question already leans "omit until needed". Package rebuilds cleanly without it.
- **[correctness:medium] `cmd_install` silent no-op on missing renderer** (`cli.py:201-204`): a requested harness whose renderer is unregistered now raises `CliError` (→ stderr + exit 1) instead of `continue`-ing and printing a green `✓ Installed`. Matches the bash, which had no analogous silent skip. New test `test_install_fails_loud_when_renderer_unregistered` asserts exit 1 + the stderr string.
- **[encapsulation:medium] `_union_files` reaches into manifest privates** (`cli.py:233-257` → `manifest.py`): added public `manifest.select_files(old_files, new_files, selected_harnesses)` that owns the owner-overlap orphan filter (the same logic `diff_and_clean` owns internally). `_union_files` now calls it; the CLI no longer imports `_path_owners`/`_owner_overlap`. Those privates are now used only within `manifest.py`.
- **[deslop:medium] scattered stdlib imports** (`cli.py:136,156,224,238`): hoisted `import json` and `import yaml` to module top; removed the three function-local `import json` and one function-local `import yaml`.

### Deferred (4 low — documented, unfixed per task)
- **[deslop:low]** `manifest.py:100-109` `record_file` orphaned-in-production (test-only helper).
- **[complexity:low]** `base.py:54-57` `DEFAULT_MCP_HARNESSES` near-dead (every renderer passes its own default).
- **[correctness:low]** `cli.py` `cmd_launch` ignores `cmd_install` return (latent; always 0 today, matches bash).
- **[deslop:low]** `copilot.py:55` `_AGENT_STRIP_KEYS` includes unused `agents_md_path`.

### Checks
- `uv run --project agent-profile pytest -q`: pass — 187 passed (186 baseline + 1 new fail-loud test). Baseline confirmed green before changes.

### Notes
- Behavioral parity preserved: all golden/steel-thread tests (`test_integration.py`, `test_integration_production.py`) stay green. The fail-loud change is unreachable in production (all five renderers wired) — it only fires for a partial/missing registry, which the previous code masked.
- Pre-existing unused `import argparse` in `cli.py` left untouched (out of scope — not orphaned by these changes).

### Re-review
- Remaining risk: `certain` — none from these fixes; the only observable behavior change (fail-loud) is covered by a new test and was a no-op-only path in production.
- Suggested next step: `/age --scope agent-profile/` if re-review is wanted. Sub-agent does not chain forward.
