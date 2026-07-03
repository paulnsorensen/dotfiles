# Codex Hooks Schema

Codex `~/.codex/hooks.json` must be a JSON object with a top-level `hooks` map, not a flat array. The documented shape is `{"hooks": {"EventName": [{"matcher": "...", "hooks": [{"type": "command", "command": "..."}]}]}}`.

Why this matters here: `agent-profile/agent_profile/renderers/codex.py` owns `~/.codex/hooks.json` for the global profile. A flat array of `{event, command, matcher}` records parses as JSON, but Codex rejects it as a hooks config with errors like `trailing characters at line 8 column 3`. The renderer should group registry hooks by event and emit command handlers under each matcher group.

Related pages: [[codex]], [[../architecture/agent-profile]], [[../architecture/config-drift]].
