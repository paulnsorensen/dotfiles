Run `cargo clippy --all-targets --all-features -- -D warnings` and walk the user through each warning.

For each warning:

1. Quote the file:line reference.
2. Explain what clippy is complaining about in one sentence.
3. Propose the smallest fix that satisfies the lint without changing behavior.
4. Apply the fix only after the user confirms (or if they passed `--auto`).

When done, re-run clippy and report whether the workspace is clean.
