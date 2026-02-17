---
allowed-tools: Bash(gh *), Bash(git *), Bash(sleep *), Bash(date *), Read, AskUserQuestion, Skill
description: Delegate a task to GitHub Copilot coding agent, then review the resulting PR.
argument-hint: "<task description>"
---

Delegate a task to the GitHub Copilot coding agent. Monitor until it produces a PR, then trigger `/copilot-review`.

**Input:** $ARGUMENTS

## Context: Copilot Model Constraints

The coding agent uses **Auto model selection** (typically Claude Sonnet 4.5). CLI has no `--model` flag. Optimize the task description accordingly:

- **Be explicit and concrete.** Sonnet follows clear instructions well but won't infer ambiguous intent. Spell out expected behavior, not just "fix it."
- **Scope tightly.** One focused task per delegation. "Add input validation to the /users endpoint" not "improve the API."
- **Name files and symbols.** If you know where the work lives, say so: "In `src/auth/login.ts`, the `validateToken` function should..."
- **State acceptance criteria.** "The function should return 400 for empty email, 422 for malformed email" gives Sonnet clear targets.
- **Include constraints.** Mention patterns to follow: "Use the existing `AppError` class for error responses" or "Follow the validation pattern in `orders.ts`."
- **Skip the why.** Sonnet doesn't need motivation or context about your architecture philosophy. Give it the what and where.

When confirming the task with the user (Phase 1 step 3), review the description against these criteria and suggest improvements if it's vague or under-specified.

## Phase 1: Create the Agent Task

1. If no `$ARGUMENTS` provided, ask the user what task to delegate.

2. Get the current repo context:
   ```
   gh repo view --json nameWithOwner --jq '.nameWithOwner'
   ```

3. Confirm with the user before creating:
   - Show the task description
   - Show the target repo
   - Ask if a non-default base branch is needed (default: skip, use repo default)

4. Create the agent task:
   ```
   gh agent-task create "<task description>"
   ```

5. Immediately capture the task reference. Run:
   ```
   gh agent-task list --limit 1
   ```
   Parse the output (tab-separated: `description \t #PR \t repo \t status \t timestamp`).
   Extract the **PR number** and **status**.

6. Confirm creation to the user:
   - Task description
   - PR number (e.g., `#42`)
   - Current status
   - Link: `https://github.com/{repo}/pull/{number}`

## Phase 2: Monitor for Completion

Poll task status every **90 seconds**, up to a **15-minute** timeout.

Loop:

1. Wait:
   ```
   sleep 90
   ```

2. Check status:
   ```
   gh agent-task list --limit 5
   ```
   Find the row matching our PR number.

3. Branch on status:
   - **In progress** / **Working** — Print a one-line status update (include elapsed time). Continue loop.
   - **Ready for review** / **Completed** — Break. Proceed to Phase 3.
   - **Failed** / **Error** — Show error details via `gh agent-task view <PR#>`. Stop.

4. On timeout (15 min reached):
   - Tell the user the task is still running.
   - Provide the PR link for manual follow-up.
   - Ask: continue waiting (another 10 min) or stop and review later?

## Phase 3: Review the PR

1. Show completion summary:
   - PR number and link
   - Final status
   - Total elapsed time

2. Ask the user: "Run /copilot-review on PR #N?"
   - **Yes** — Invoke the `copilot-review` skill with the PR number as argument.
   - **No** — Print the PR link and exit.

## Rules

- **Always confirm before creating.** The user must approve the task description and target repo.
- **Keep polling updates minimal.** One line per check — don't flood the conversation.
- **Fail fast on errors.** If `gh agent-task create` fails, show the error and stop.
- **Never guess PR numbers.** Always parse from `gh agent-task list` output.
