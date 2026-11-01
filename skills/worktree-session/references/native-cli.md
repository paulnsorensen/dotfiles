# Native and CLI routing

This branch covers standalone Claude Code, Codex, OMP, and Pi.
Tools exposed inside T3 use the T3 reference instead.
Do not infer session capabilities from the model's name.

## Discover before launch

Inspect the active harness's available tools and installed launcher help.
Use current primary documentation when local help does not establish the required behavior.
Do not invent workspace, sandbox, resume, or background flags.
A supported mechanism must bind the destination session to the selected checkout before that session edits files.

Prefer native child-worktree isolation for delegated work when the host exposes it.
Verify whether that mechanism supports existing checkouts.
A fresh child checkout does not satisfy resumption of an existing dirty checkout.
For OMP and Pi, inspect actual capabilities instead of assuming Claude or Codex flags apply.

## CLI helpers

`wt` creates or resumes a checkout; it does not launch a session.
Use it only after identifying a launcher that can use its result.

- `wt -m <slug>` starts from the current local branch.
- `wt -o <slug>` starts from the remote default branch after fetching.
- Its JSON reports `path`, `branch`, `base_sha`, `base_branch`, and `created`.

Inspect a resumed checkout independently.
The requested base does not prove an existing checkout's ancestry.

`ccw` is a zsh function that calls `wt`, changes directory, and launches Claude through `cc`.
It is a Claude launcher, not a harness-neutral launcher.
Its slug path uses `wt`'s current-branch default.
It does not forward `-o` as a base-selection flag.
For an independent base, prepare with `wt -o <slug>` before using `ccw <slug>`.

Use `ccw` only when Claude is the approved destination provider.
Run interactive launchers through an available terminal/session surface.
Do not start an unattended nested interactive process in the parent's command tool.
If no suitable surface exists, give the operator a command and report pending.
Use the installed harness launcher for Codex, OMP, or Pi only after verifying its checkout-selection contract.

## Existing checkout and permissions

Start or select a session whose initial checkout is the existing target.
Verify the exact branch and dirty state before destination edits.
Do not reuse the parent's sandbox metadata as evidence of destination access.
Do not request broader parent write roots or a parent restart.
When no supported session launcher exists, report blocked.
Do not create another checkout as a substitute.

## Example

Request: "Resume edits in /repo/task-b from Codex; only /repo/task-a is writable here."

Inspect available Codex session-launch capabilities.
If none can bind a destination session to /repo/task-b, report blocked with the missing capability.
Leave both checkouts and the parent's permissions unchanged.
