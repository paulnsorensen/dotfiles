# Review profile write denial

The isolated `review` profile must deny every built-in text mutator: `Edit`, `Write`, `MultiEdit`, and `NotebookEdit`, as well as `mcp__tilth__tilth_write`.[^1]

`MultiEdit` is separately named by Claude's tool surface, so denying `Edit` and `Write` does not cover it.[^2]

[^1]: profiles/review/profile.yaml:24-29
[^2]: agents/lib/sensitive-file-guard.js:23
