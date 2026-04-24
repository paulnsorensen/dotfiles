# shellcheck disable=SC2034  # env_vars and extra_args are used by parent ccp function
# Extra launch args for the `todo` profile.
# Sourced by `ccp todo`.
# Adds plugin scoping, tool surface, and permission-skip on top of the
# mcp-scope.yaml / settings.json / CLAUDE.md that are picked up automatically.
#
# Tool surface: Todoist-first, but file ops (Read/Write/Edit/Grep/Glob) are
# available because tasks frequently reference local notes, and Bash is open
# so /research can spawn the gh CLI fetcher. Deliberately no LSP/NotebookEdit
# — this is still not a coding session.
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
    --tools "Skill,Agent,Read,Write,Edit,Grep,Glob,Bash,TaskCreate,TaskUpdate,TaskList,AskUserQuestion"
    --dangerously-skip-permissions
)
