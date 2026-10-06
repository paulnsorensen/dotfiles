# How We Made Claude.ai 3x Faster

Anthropic engineering post by Raymond Wang, Sam Attard, and Issac G., published 2026-09-23 and fetched 2026-10-06.
Canonical source: <https://claude.dev/blog/how-we-made-claude-ai-faster/>

## Result

A two-week sprint in August 2026 made claude.ai and the desktop app about 3x faster.
The team measured four journeys that cover 95% of activity: launch, start a conversation, load a conversation, and send a message.
Thirteen p75 measurements improved by a geometric mean of 3.1x. Twelve of thirteen sprint targets were met by day three.
Examples: fresh web load 3.1 s to 0.55 s; desktop cold start 6.31 s to 3.33 s; Cowork send 928 ms to 48 ms.

## Method

**Brief.** A Slack channel had Claude as a standing member. Claude chose the four journeys from Datadog data, estimated each candidate project in milliseconds, and summed estimates into targets.

**Anything can be hill climbed.** Wall-clock timing iterates only as fast as deploys. The team replaced it in the lab with deterministic counts:

- Pure JavaScript hot paths: CPU instructions under Valgrind with `node --predictable`.
- Browser paths: React commits per interaction, V8 coverage call counts, layout and style-recalculation counts, DOM mutations.

Each new benchmark had two jobs: a metric Claude could optimize in the lab, and **a guardrail in CI with ratcheting thresholds**.
The team first checked that each benchmark correlated with user latency.
Example: message-tree assembly lost 48% of instructions and 78% of wall-clock time. The post states: "With Claude, measuring something makes it tractable."

**The loop, per thread.**

1. A human opens a thread about a slow stretch, with a screenshot or recording.
2. Claude traces the flow and finds or builds a benchmark that shows the problem.
3. With promising lab results, Claude proposes PRs sized for risk and review. User-visible changes go behind flags.
4. After deploy, Claude reads field data.
5. If the metric improved, Claude ratchets the benchmark down. If not, Claude turns off the flag and iterates.
6. Claude picks the next opportunity in the same journey.

A sidebar layout-shift test ran red 20 of 20 times on main and green 20 of 20 on the PR. Field data then showed 31% of loads moved content after the page was usable.

**Horizontal scale.** By week two, more than 150 threads ran at once and more than 200 changes merged per day. One thread produced 50 to 100 PRs. About a third of PRs added telemetry or guardrails, which opened more threads.
Census finds included 6,900 hooks on one typing path, a `:root:has()` selector that cost 24 ms per DOM change, and a UTF-16 regex slow path triggered by em dashes.

## Guardrails

- Every PR had automated review and at least one human approval.
- Unit tests came before optimizations.
- User-visible changes shipped behind short-lived flags, classified as kill switches or ramps. About 200 flags were added; more than half were retired within the sprint.
- The static composer had a jsdom drift test, a 14-viewport pixel-alignment suite, a keystroke handoff test, and field telemetry at tenth-of-a-pixel resolution.

## Steering

- **Ambition.** Humans pushed Claude past careful scope: "the targets are not the stopping point."
- **Taste.** Each thread had a named human owner who decided user-perceptible trade-offs from before-and-after evidence. A 900-line PR was rejected: 2 ms per send did not justify the build plugin.
- **Direction.** Threads stayed narrow, one benchmark or journey each. Humans decided sequencing and diminishing returns.

## 8 ms budget

Claude set up deterministic 120 Hz frame stepping in headless Chromium, which made "did this frame fit 8.33 ms" an exact read. About 60 PRs cut long-reply main-thread blocking from about 750 ms to about 200 ms.

## Project relevance

The `hill-climb` skill and the `hill-climb-threads` workflow encode this method. See [[architecture/hill-climb-ratchet]].

_Source: <https://claude.dev/blog/how-we-made-claude-ai-faster/> · Updated: 2026-10-06 · Supersedes: none_
