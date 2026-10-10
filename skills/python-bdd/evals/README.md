# Python BDD evaluation cases

[Evaluation intent](EVAL.md) defines stable requirements before candidate results. [Case data](cases.json) maps concrete tasks to those requirements. This is a repository-local, runner-neutral format, not an external runner schema. No custom runner lives here.

## Case format

Each case has an ID, requirement IDs, a user prompt, and a fixture/setup contract. It also has expected artifacts, verification instructions, a qualitative rubric, and fail conditions. Verification text is guidance for an evaluator, not executable assertions. Review `EVAL.md` before changing a case oracle.

## Baseline and candidate protocol

1. Freeze the fixture, prompt, requirement IDs, and oracle before either run.
2. Run the same task once without the skill and once with an explicit user invocation of the skill.
3. Use clean, independent worktrees and equivalent environments. Record model, revision, commands, and tool availability.
4. Capture artifacts and exact pass, fail, and unrun results for each run. Apply the deterministic checks and record rubric judgments separately.
5. Compare behavior and process evidence. Do not infer speed improvement without measured baseline and candidate timings.
6. Record new gaps separately. Do not rewrite an oracle from candidate output or current failures.

A case can remain **unrun**. Do not call an authored case a passed evaluation. Parent-owned representative smoke evidence does not imply that the full model evaluation suite ran. The user-only routing case states expected behavior; it does not prove every harness enforces it. See [initial results](results.md) for the six-pass smoke, restored regression, absent currency, and eight unrun cases. Do not launch skillz autoimprove or live paid evaluation calls without separate approval. That approval must name the cases, budget, and model.
