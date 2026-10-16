# Parallel writers on shared git state

Read at Flow step 8, or when two or more agents write code that must combine.

## Source scope

The fan-out sources in this skill cover read-heavy work. The research system runs parallel readers, and a lead agent combines their text [s12].
The coding harness runs one feature at a time, in sequence [s9].
No cited source covers parallel writers on one repository. The rules below come from local run evidence, not from a source.

## Rules

1. Order the writers by the task graph. Stack or serialize dependent writers. Run only independent targets in parallel.
2. Compute the planned file overlap in code before each wave. Serialize two targets whose planned files overlap, even when neither depends on the other.
3. Build each dependent target on the real integrated commit of its dependency. Code passes that commit SHA to the writer.
4. Do not tell a writer to "rebase on" a PR or to re-apply a diff. A writer that re-applies a diff creates a second copy of the change.
5. Integrate after each target or each wave, not only at one final barrier. Merge the target onto the integration head, then run a conflict probe.
6. A failed probe stops the dependents of that target. Log each stopped target with its reason.
7. Reject a plan in code when a target waits for a merge that cannot happen before publish. For example, target B waits for PR A to merge, but A merges only after the run publishes B. That plan deadlocks.
8. Run the merges and the probe through one deterministic script, such as `wfx integrate` and `wfx probe`. See the git row in `determinism.md`. An agent resolves a conflict only when the script reports one.

## Template status

`assets/workflow-template.js` predates these rules. It integrates once, at a final barrier, and its prompts carry git steps.
Its dependent tasks merge their dependency branches, so it follows rule 3 in part.
Adapt its integrate stage before you use it for writers that can conflict. The template stays self-contained for teaching; the dotfiles modules and `wfx` hold the tested versions.

Evidence: 48 move-my-cheese runs from 2026-10-12 to 2026-10-16 built targets in parallel from the base and combined them only at a final barrier. Three runs ended in conflicts. Builders told to "rebase on #115" re-applied the diff. One plan made a target wait for a merge that could not happen before publish, and the run deadlocked.
