# Extra launch args for the `todo` profile.
# Sourced by `cc -p todo` via _cc_launch_profile.
# Adds plugin scoping, tool lockdown, and permission-skip on top of the
# mcp.json / settings.json / CLAUDE.md that are picked up automatically.
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
    --tools "Skill,Agent,Read,TaskCreate,TaskUpdate,TaskList,AskUserQuestion"
    --dangerously-skip-permissions
)
