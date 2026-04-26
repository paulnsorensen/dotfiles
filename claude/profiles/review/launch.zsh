# shellcheck disable=SC2034  # extra_args is consumed by the parent ccp function
# Extra launch args for the `review` profile.
# No Edit/Write/NotebookEdit — reviewers read and file comments, they don't fix.
# Bash stays in so `gh`, `git log/diff/show`, and test commands work.
# No WebFetch/WebSearch — review CLAUDE.md routes web research through /gh
# or /fetch (forked) to keep main context clean.
extra_args=(
    --tools "Read,Grep,Glob,Bash,Skill,Agent,LSP,TaskCreate,TaskUpdate,TaskList,AskUserQuestion"
)
