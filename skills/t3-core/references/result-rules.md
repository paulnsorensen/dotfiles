# Result rules

The parent checks every child result before it uses the result.

## Cheap roles

Cheap roles are gate-runner, runner, recon, worktree-digest, formatter, and verifier. Each returns exactly one JSON object.

Every non-write result carries a non-empty string `status`.

1. Write the object to a file.
2. Run `bin/t3-run validate <role> <file>`.
3. On a failed check, retry once as a new call. Use the target from `t3-run role gate-runner`. Call `t3-run ledger reserve` again, and record the retry as its own `t3-run ledger record` entry.
4. On a second failure, mark that child blocked.

Reason: probe S-4. A cheap text child at low effort returned empty JSON with no tool call. Validation catches this.

## Write roles

A write role returns `{status, branch, head_sha}`. `head_sha` is a full 40-hex SHA.

1. Write the result to a file. Run `t3-run validate <role> <file>`.
2. Run `t3-run gate sha <head_sha>`.
3. Integrate by that SHA. Never integrate by branch name alone.

## Reviewers

A reviewer returns findings in the report format of the real skill. The parent reconciles the findings from all reviewers into one report.
