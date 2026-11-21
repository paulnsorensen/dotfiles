# Claude Desktop routing

Use this route in the Code tab of the Claude desktop app when T3 session tools are unavailable.
Desktop starts sessions through its `ccd_session` server, not through a terminal launcher.
Do not use `ccw`, `claude --worktree`, or a nested CLI process as a substitute.
Desktop does not list terminal, T3, or cloud sessions, so a substitute session is invisible in its sidebar.

## Detect

The `ccd_session` server's tools mark a Desktop session.
Examples are `start_session`, `list_start_targets`, and the session list, read, and message tools.
Read each live schema before the first call.
Since 2026-10, `start_session` replaces `spawn_task` when side sessions are on.
Use `spawn_task` only when the live catalog still lists it.
Do not copy parameter names from this page without the live schema.

## Choose by requested ownership

| Request | Mechanism | Completion evidence |
| --- | --- | --- |
| The user asks for a new or child session | `start_session` with `initiation:"user_asked"` | The started session reports its checkout, branch, base, and write access |
| Claude proposes work that the user did not request | `start_session` with `initiation:"own_initiative"` | The user clicks **Start**; the started session then verifies |
| Move the current session into a worktree | `EnterWorktree` (`name` for new, `path` for existing) | The current session verifies its new working directory |
| Several independent tasks | One task card with several tasks; the user clicks **Start all** | Each started session verifies |

A proposal card cannot carry a folder, host, environment, preset, or repository.
It opens in the proposing session's project.
For work in another repository, ask the user to request it, then use `user_asked` with the live place fields.
If the live schema refuses that place, report pending with the operator action.

## Worktree isolation

The **Worktree** toggle is off by default.
With it off, a session works in the project folder itself, not in an isolated checkout.
A started task uses the current session's environment by default.
A task started from a worktree session gets a new worktree of the same project.
A task started from a session without a worktree can share the project folder.

Set the worktree option when the live schema exposes one.
Otherwise, post a proposal card and tell the user to turn on **Worktree** under **Options** before **Start**.
Desktop stores worktrees under `<project-root>/.claude/worktrees/` unless **Settings > Code** sets another location.
A new Desktop worktree starts from Desktop's own base selection.
The skill cannot pass a base commit through a card, so verify the started commit after launch.
Report blocked when the started commit differs from the requested base.

`EnterWorktree` with `name` fails when the session already runs in a worktree.
`EnterWorktree` with `path` accepts only an existing worktree that `git worktree list` reports.
From a pinned sub-agent, the target must be under `.claude/worktrees/` of the same repository.
The switch moves the session, not its uncommitted changes.

## Model and effort

A proposal card's **Options** let the user set the model, environment, worktree, and permissions.
Set a model or effort only through fields that the live schema exposes.
If the user requests a model that the schema cannot set, tell the user to select it under **Options**.

## Unattended sessions

`start_session` refuses all initiation values in scheduled or remotely dispatched sessions.
It also refuses `user_asked` when the user drives the session over Remote Control.
The refusal follows the session's origin, so later typing does not remove it.
Report pending with the brief and this operator action: click **+ New**, turn on **Worktree**, and paste the brief.
Do not retry with another transport.

## Verify the destination

A card or launch receipt is pending, not proof that the destination can edit.
Use the Desktop session read and message tools to request verification from the started session.
Ask for the checkout path, branch, `HEAD`, dirty state, and an authorized write probe.
The receiving session follows its own permissions and inbound message controls.
If it refuses messages or does not reply, report pending.
Do not send a review round to a started session; start a new session for new work.

## Example

Request: "In Desktop, start a separate session in a new worktree for the cache fix; continue here."

Inspect the `ccd_session` tools and read the `start_session` schema.
Call `start_session` with `initiation:"user_asked"`, the brief, and the worktree option if one exists.
Keep the current session in its checkout.
Report pending until the started session confirms its worktree path, branch, base commit, and write access.
