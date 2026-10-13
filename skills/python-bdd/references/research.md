# Python BDD research

Read this reference when choosing a scenario or evaluation format, or explaining this standard's evidence.
The sources below support separate decisions about scenario language, execution, and skill evaluation.

## Scenario and execution lessons

- [Intent's gherkin-authoring](https://github.com/intent-driven-dev/skills/blob/main/.agents/skills/gherkin-authoring/SKILL.md) favors domain language and externally observable results. It does not select an execution boundary.
- [Playwright-BDD](https://github.com/vitalets/playwright-bdd/blob/main/skills/playwright-bdd/SKILL.md) connects scenarios, steps, and execution. Its browser workflow is not a universal requirement.
- [FradSer's BDD skill](https://github.com/FradSer/dotclaude/blob/main/superpowers/skills/behavior-driven-development/SKILL.md) requires observed red failures. Do not copy its instruction to delete existing production code into a brownfield project.
- [pproenca feature-design](https://github.com/pproenca/dot-skills/blob/master/skills/.experimental/acceptance-pipeline-feature-design/SKILL.md) depends on its acceptance catalog. Do not copy that pipeline into unrelated projects.
- [Automation Panda](https://github.com/AutomationPanda/gherkin-guidelines-for-ai/blob/main/gherkin-guidelines.md) gives domain-level Gherkin guidance. Readable scenarios alone do not prove execution.
- [Cucumber's testable architecture](https://cucumber.io/docs/guides/testable-architecture) permits lower-level execution and contract-checked substitutes alongside selected full-stack tests.

The inspected candidates cover different parts of suite design. Choose scenario language and the real execution boundary separately.
A generated scenario needs collected execution and an assertion against public behavior before it counts as regression evidence.

## Evaluation lessons

[OpenAI's skill evaluation guidance](https://developers.openai.com/blog/eval-skills) starts with measurable outcome, process, style, and efficiency goals before skill authoring.
[Firebase's eval-driven account](https://firebase.blog/posts/2026/08/eval-driven-development-agent-skills) defines expected outcomes as a baseline, then tests single-skill behavior, activation, and integrated journeys.
These are methods, not a portable file format.

[NVIDIA SkillEvaluator](https://docs.nvidia.com/skills/skillevaluator/eval-datasets) uses `evals/EVAL.md` for author guidance and separates questions, behaviors, negative cases, and notes from executable cases and runtime policy.
Its author requirements persist when trial runs omit them. Do not let observed outputs replace intended behavior.
The [Agent Skills specification](https://agentskills.io/specification) defines packaging, not a required behavior-document format.
The [Agent Skills evaluation guide](https://agentskills.io/skill-creation/evaluating-skills) describes cases and assertions; [Anthropic's skill-creator](https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md) also tests skill activation, and its [schema](https://github.com/anthropics/skills/blob/main/skills/skill-creator/references/schemas.md) names case checks `expectations`.
Pair activation checks with task-output checks. Select a runner before writing machine-readable cases; `assertions` and `expectations` do not establish schema compatibility.
No custom eval runner is required by this skill.

## Runtime sources

The [pytest-bdd README](https://github.com/pytest-dev/pytest-bdd/blob/master/README.rst) documents scenario binding, pytest fixtures, `target_fixture`, and marker selection. A feature file alone is not a collected pytest test.
[uv project sync](https://docs.astral.sh/uv/concepts/projects/sync/) documents locked synchronization and editable project installation. The [uv build reference](https://docs.astral.sh/uv/reference/cli/) documents wheel builds.
The [uv GitHub Actions guide](https://docs.astral.sh/uv/guides/integration/github/) demonstrates an installed-wheel smoke check and dependency caching. [GitHub's cache guidance](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching) warns against secrets and untrusted cache writes.
Run the wheel smoke check outside the source checkout; an editable test or a cache hit does not prove the wheel contains the required files.
