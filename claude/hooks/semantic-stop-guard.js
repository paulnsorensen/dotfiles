#!/usr/bin/env node

const MIN_MESSAGE_LENGTH = 200;

const EVALUATION_PROMPT = `Run through the Self-Evaluation Checklist in your instructions. If any violations found, fix them before stopping. If clean, you may stop.`;

// Patterns that signal a "done" response worth evaluating.
// Short answers, clarifying questions, and mid-conversation replies skip the check.
const COMPLETION_PATTERNS = [
  /\blet me know\b/i,
  /\bwant me to\b/i,
  /\bshould\s+be\b/i,
  /\ball\s+(set|done|good|complete)/i,
  /\bthat('s| is)\s+(it|all|everything)\b/i,
  /\bready to\b/i,
  /\bhere('s| is)\s+(the|a|your|my)\b/i,
  /\bsummary\b/i,
  /\brecap\b/i,
  /\bship\b/i,
  /\bcommit\b/i,
  /\bmerge\b/i,
  /\bpush\b/i,
  /\blgtm\b/i,
  /\bcomplete[sd]?\b/i,
  /\bfinish/i,
  /\bimplement/i,
  /\bapplied?\b/i,
  /\bfixed?\b/i,
  /\bupdated?\b/i,
  /\bcreated?\b/i,
  /\brefactor/i,
  /\bclean\b/i,
  /\bchanges?\b.*\b(above|below|look|review)\b/i,
  /```/,  // code blocks suggest substantive output
];

function looksLikeCompletion(message) {
  return COMPLETION_PATTERNS.some(pattern => pattern.test(message));
}

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

    // Skip short responses and non-completion responses
    if (message.length < MIN_MESSAGE_LENGTH || !looksLikeCompletion(message)) {
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
