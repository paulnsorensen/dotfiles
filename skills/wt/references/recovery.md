# Recover a failed worktree resumption

When resumption fails, copy the preserved work into a new worktree and continue through a supported session route.
This fallback changes the checkout, not the requested session ownership or provider.
Keep the original checkout unchanged and report both paths.

## Qualify the failure

Record the exact resume failure and inspect whether a destination session already starts.
Do not create duplicate sessions after a lost response.
A permission denial does not authorize this fallback.
Report blocked when required source reads or destination writes lack permission.
An unsupported existing-worktree selector qualifies when a supported new-worktree session route exists.
Do not create a top-level conversation for a child-only request.

## Preserve the source

Inspect the source repository, HEAD commit, branch, index, working tree, and task-relevant untracked files.
Preserve staged and unstaged differences separately, including staged-only file versions.
Record changed paths, file contents or digests, deletions, executable modes, and safe symlink targets.
Wait for source writers to finish before taking the transfer snapshot.
Recheck the source state before and after transfer.
If it changes, reconcile a fresh snapshot before continuing.

Never copy `.git`, credentials, sockets, caches, build outputs, or dependency directories.
Include the task's untracked source files, not just tracked changes.
Do not follow symlinks outside the source checkout.
Stop on unmerged index entries or ambiguous transfer conflicts rather than choosing a version silently.

## Prepare and transfer

Use the source HEAD as the recovery base unless the user explicitly requests another base.
If an explicit base differs, ask before changing that contract or applying incompatible changes.
Select a supported new-worktree session mechanism that can start from the resolved base.
Verify destination binding, branch, starting commit, and write access before copying files.
If no such mechanism exists, report blocked without creating an unused checkout.

Use approved file tools to copy source changes into the verified destination.
Transfer modifications, additions, deletions, staged state, file modes, and safe symlinks.
Apply deletions only when the destination path still matches the expected base version.
Do not overwrite unrelated destination changes or copy machine-specific Git metadata.
The destination agent performs writes when the parent's permissions exclude the new checkout.

## Verify and continue

Compare the destination's tracked changes and included untracked files with the source snapshot.
Verify file contents, deletions, modes, symlink targets, and staged versus unstaged state.
Confirm that the original checkout remains unchanged.
Continue the requested tasks only after transfer verification passes.
For multiple tasks, the destination coordinator owns this transfer and then dispatches its sub-agents.
If transfer verification fails, retain both checkouts and report pending or blocked with the exact mismatch.

## Example

Request: "Resume this worktree; copy the files to a new worktree if resumption fails."

The existing-checkout selector reports unsupported.
Start a supported destination session at the source HEAD and verify its binding and permissions.
Copy modified files and safe untracked files, preserve deletions and staged state, and compare both checkout states.
Leave the source intact and continue in the verified destination.
