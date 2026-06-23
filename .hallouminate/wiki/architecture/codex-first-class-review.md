# Codex first-class review

Codex first-class work now has fixes for user-level hook command resolution, Codex hook-health diagnostics in `harness-doctor`, isolated Codex profile projection, and stale MCP tool-scope cleanup. The remaining known gap is live `PreToolUse` matcher-name verification before changing `agents/hooks/registry.yaml`.[^1]

## Findings and fixes

- **User-level hooks cannot use `.codex/hooks/...` relative commands.** Codex runs hook commands with the session working directory, not the config-file directory; the renderer now writes absolute commands to the copied script, and tests assert resolution from an unrelated cwd.[^2]
- **Codex hook-health is now visible to `harness-doctor`.** The doctor instructions now include `~/.codex/hooks.json`, flag relative user-level hook commands, and flag duplicate `hooks.json` plus legacy inline `[[hooks.*]]` wiring.[^3]
- **`ap launch codex <isolated>` now projects Codex-native profile files.** The redirected `CODEX_HOME` gets root `config.toml`, `hooks.json`, `agents/`, `rules/`, selected shared skills, and MCP tool scopes; Codex still has no built-in `--tools` equivalent, so tool whitelist fields remain ignored with warning.[^4]
- **MCP tool-scope cleanup now uses the previous manifest snapshot.** Install reconcile clears prior Codex `enabled_tools` / `disabled_tools` when the current profile no longer has any matching `mcp__*` rule for that server.[^5]

## Remaining follow-up

Capture real Codex `PreToolUse` payloads for `exec_command`, `apply_patch`, `tilth_read`, and `tilth_write` before changing `agents/hooks/registry.yaml` matcher names. The analytics adapter records those names, but that is not yet evidence of the live CLI hook payload shape.[^6]

[^1]: `.cheese/cure/codex-first-class.md`
[^2]: `agent-profile/agent_profile/renderers/codex.py:293-351`; `agent-profile/tests/test_renderer_codex.py:225-288`
[^3]: `skills/harness-doctor/SKILL.md:79-121`
[^4]: `agent-profile/agent_profile/overlay.py:257-467`; `agent-profile/tests/test_overlay.py:1309-1355`
[^5]: `agent-profile/agent_profile/cli.py:303-463`; `agent-profile/agent_profile/renderers/codex.py:492-520`; `agent-profile/tests/test_mcp_reconcile.py:264-299`
[^6]: `.cheese/age/codex-first-class.md:47-51`
