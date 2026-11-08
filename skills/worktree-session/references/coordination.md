# Coordinate multiple tasks in one worktree

Assign one coordinating agent to the destination worktree for the complete task set.
The coordinator owns decomposition, worker dispatch, shared state, integration, and final verification.
Do not dispatch each task as an isolated worktree when the user requests one shared worktree.

## Dispatch contract

Give the coordinator:

- The complete task list, dependencies, acceptance criteria, and scope limits.
- The destination checkout, branch, starting commit, and permission-verification requirements.
- Explicit permission to spawn its own sub-agents in that checkout.
- The requirement to integrate worker results and run the final combined acceptance checks.

Confirm that the destination session can spawn sub-agents before selecting its launcher.
A leaf agent without delegation tools cannot serve as this coordinator.
If no supported route provides that capability, report blocked instead of silently changing the orchestration.

## Worker ownership

The coordinator assigns each worker a task, owned files, acceptance checks, and dependencies.
Tell workers that they share the checkout and must preserve other workers' changes.
Workers use the coordinator's checkout and branch, not separate worktrees.
Run tasks concurrently only when their write sets and dependencies permit it.
Sequence tasks that edit the same files or depend on unfinished work.
The coordinator alone owns branch changes, integration, and publication when authorized.
Workers return compact results, verification evidence, and blockers.

## Completion

The coordinator checks every task against its acceptance criteria after integration.
Run project-wide gates once against the combined final tree.
Report task outcomes, remaining blockers, and the destination verification evidence to the parent.
The parent owns the user-facing result and verifies the coordinator's combined evidence.
Do not report completion merely because workers return successfully.

## Example

Request: "Complete the parser fix and its documentation in one worktree."

The parent starts one coordinator in the new worktree.
The coordinator gives the parser files to one worker and the documentation files to another.
The coordinator sequences any dependent work, checks the combined result, and reports both outcomes.
