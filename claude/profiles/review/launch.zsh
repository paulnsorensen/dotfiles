# Extra launch args for the `review` profile.
# No Edit/Write/NotebookEdit — reviewers read and file comments, they don't fix.
# Bash stays in so `gh`, `git log/diff/show`, and test commands work.
extra_args=(
    --tools "Read,Grep,Glob,Bash,Skill,Agent,LSP,WebFetch,WebSearch,TaskCreate,TaskUpdate,TaskList,AskUserQuestion"
)
