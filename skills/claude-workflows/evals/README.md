# claude-workflows evaluation cases

[Evaluation intent](EVAL.md) defines stable requirements before candidate results. [Case data](cases.json) maps concrete tasks to those requirements. This is a repository-local, runner-neutral format, not an external runner schema. No custom runner lives here.

## Case format

Each case has an ID, requirement IDs, a mode (`review` or `design`), a user prompt, and a fixture contract.
It also has the observed evidence, expected artifacts, verification steps, a qualitative rubric, and fail conditions.
Verification text is guidance for an evaluator, not executable assertions. Review `EVAL.md` before you change a case oracle.

## Fixtures

The review cases use the dotfiles repository at commit `75b72713`, the last commit before the fixes from this analysis.
Read each workflow file at that commit with `git worktree add <dir> 75b72713`. Do not use `git show <ref>:<path>`.
The evidence fields name the run IDs. The run records live under `~/.claude/projects/*/*/workflows/wf_*.json` on the author's machine. Other machines do not have them.

## Baseline and candidate protocol

1. Freeze the fixture, prompt, requirement IDs, and oracle before either run.
2. Run the same task once without the skill and once with an explicit `/claude-workflows` invocation.
3. Use clean, independent worktrees with the same hooks. Record model, revision, commands, and tool availability.
4. Capture the findings table or the design and stage table. Record exact pass, fail, and unrun results for each case.
5. For a design case, also check the script against the host hooks: list each command that an agent prompt tells it to run.
6. Record new gaps separately. Do not rewrite an oracle from candidate output.

A case can remain **unrun**. Do not call an authored case a passed evaluation.
Do not launch skillz autoimprove or live paid evaluation calls without separate approval. That approval must name the cases, budget, and model.

## Results

No case has run yet. All cases are unrun as of 2026-10-14.
