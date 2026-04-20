# Extra launch args for the `fe` profile.
# Sourced by `ccp fe`.
#
# Re-enables claude.ai connectors so the Figma MCP is available for
# design-to-code flows. Other connectors (Gmail, Drive, Calendar, n8n)
# come along for the ride — the env var is all-or-nothing — but this
# profile has the full dev env, so nothing extra needs filtering.
env_vars=(
    ENABLE_CLAUDEAI_MCP_SERVERS=true
)
