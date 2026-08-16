# `just check` flake: the claude-wrapper guard, not your diff

`tests/claude-wrapper.bats` invokes `bin/claude` without setting `CLAUDE_GUARD=0`,
so the launcher's own guard applies: it exits 1 when `pgrep -cx claude` reaches 8,
or when `MemAvailable` drops below 15%. Running `just check` from inside a Claude
session — especially with several open — can therefore fail test 349 ("claude
wrapper delegates to the mise shim") with no relation to the diff under test.

**Why it matters.** The failure reads as a real regression during a completion
gate and invites a pointless bisect.

**How to confirm.** Check the live session count with `pgrep -cx claude`, then
rerun the isolated suite with the guard disabled:

    CLAUDE_GUARD=0 bats tests/claude-wrapper.bats

If it passes, the failure is ambient machine state — report it as an
environment-dependent test, not "pre-existing" without evidence.

Related: [[git-stash-hygiene]] — the other repo-local trap.
