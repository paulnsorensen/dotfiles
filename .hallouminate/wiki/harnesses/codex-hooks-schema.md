# Codex Hooks Schema

Codex `~/.codex/hooks.json` must be a JSON object with a top-level `hooks` map, not a flat array. The documented shape is `{"hooks": {"EventName": [{"matcher": "...", "hooks": [{"type": "command", "command": "..."}]}]}}`.

Why this matters here: `agent-profile/agent_profile/renderers/codex.py` owns `~/.codex/hooks.json` for the global profile. A flat array of `{event, command, matcher}` records parses as JSON, but Codex rejects it as a hooks config with errors like `trailing characters at line 8 column 3`. The renderer should group registry hooks by event and emit command handlers under each matcher group.

Related pages: [[codex]], [[../architecture/agent-profile]], [[../architecture/config-drift]].

## Hook command exec semantics: shell vs argv-split

Codex's hook runner is not proven to run a `command` string through a shell. If it argv-splits instead, a bare `DOTFILES_HARNESS=codex bash <path>` prefix execs a binary literally named `DOTFILES_HARNESS=codex`, which fails and silently disables the hook (git-guard, sensitive-file-guard). `env DOTFILES_HARNESS=<name> bash <path>` is robust to both semantics: `env` is a real executable, so it runs correctly whether Codex execs argv[0] directly or hands the string to `sh -c`. Claude still relies on shell expansion of `${CLAUDE_PLUGIN_ROOT}` (the live `claude.yaml` ships an `if ...; then ...; fi` compound command, which only a shell can run), so its prefix uses the same `env` form for consistency rather than because Claude needs it.
