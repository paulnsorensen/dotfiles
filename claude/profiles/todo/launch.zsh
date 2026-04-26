# shellcheck disable=SC2034  # env_vars and extra_args are used by parent ccp function
# Extra launch args for the `todo` profile.
# Sourced by `ccp todo`.
#
# Tool surface is owned by settings.json (loaded via --settings by the parent
# ccp function). LSP/NotebookEdit/WebFetch/WebSearch are denied there, not
# whitelisted here, so we don't have two sources of truth that can drift.
#
# claude.ai connectors are re-enabled here so Gmail is available for
# "email that task" / "turn this thread into a task" flows. This also
# pulls in Figma/Drive/Calendar/etc. instruction blocks — unavoidable,
# the env var is all-or-nothing.
env_vars=(
    ENABLE_CLAUDEAI_MCP_SERVERS=true
)
extra_args=(
    --plugin-dir "$DOTFILES_DIR/claude/plugins/local/todoist-flow"
    --dangerously-skip-permissions
)
