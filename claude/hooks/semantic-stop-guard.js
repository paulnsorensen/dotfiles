#!/usr/bin/env node

const MIN_MESSAGE_LENGTH = 20;

const EVALUATION_PROMPT = `STOP. Before you finish, evaluate your last response for these anti-patterns:

1. **SYCOPHANCY** — Did you praise the user's idea, say "Great question!", or agree without substance? Remove it.

2. **PREMATURE COMPLETION** — Did you claim work is done when it isn't? Did you leave TODOs, say "I've set up the foundation", or suggest the user finish steps? Go back and finish the work.

3. **DISMISSING FAILURES** — Did you downplay errors or call test failures "pre-existing" without verifying on the base branch? If failures exist, investigate and fix them NOW.

4. **HEDGING** — Did you use "this should work", "you might want to", "consider perhaps"? Either verify it works or state clearly what you don't know.

5. **SCOPE REDUCTION** — Did you silently drop requirements or say "for now" / "as a starting point" / "we can add X later"? If you reduced scope, acknowledge it explicitly and explain why.

6. **FALSE CONFIDENCE** — Did you claim something works without running tests or verifying? Go run the tests.

7. **AI SLOP** — Did you review your changes for AI anti-patterns before committing? Comment pollution, silent error swallowing, over-abstraction, partial strict mode (set -e without -uo pipefail), unnecessary type annotations, dead code. If you committed without checking, review now.

8. **WEAK ASSERTIONS** — If you wrote or modified tests, did you verify assertion strength? Existence checks instead of value equality, catch-all error types, length-only checks, mock verification without arguments, no-crash-as-success. If test files are in your changes, verify now.

If you find any violations: fix them, then try stopping again.
If your response is clean: you may stop.`;

let input = '';
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const payload = JSON.parse(input);

    if (payload.stop_hook_active) {
      console.log('{}');
      process.exit(0);
    }

    const message = payload.last_assistant_message || '';
    if (message.length < MIN_MESSAGE_LENGTH) {
      console.log('{}');
      process.exit(0);
    }

    console.log(JSON.stringify({
      decision: 'block',
      reason: 'Self-evaluation required before stopping.',
      systemMessage: EVALUATION_PROMPT
    }));
  } catch {
    console.log('{}');
  }
  process.exit(0);
});
