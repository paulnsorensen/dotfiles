#!/usr/bin/env node

// PreToolUse hook: blocks deferral language in PR review replies.
// Registered on MCP reply tools only (not Bash — gh CLI is rare for replies).

const DEFERRAL_PATTERNS = [
  /\bfollow[- ]?up\b/i,
  /\bseparate\s+(PR|pull\s+request|commit|branch)\b/i,
  /\bwill\s+(add|address|fix|handle|update|do)\s+(this\s+)?(in|later|separately)\b/i,
  /\bfuture\s+(PR|commit|iteration|pass)\b/i,
  /\bleave\s+(this\s+)?for\s+(later|now|another)\b/i,
  /\btrack(ing)?\s+(this\s+)?(as|in)\s+(an?\s+)?issue\b/i,
  /\bopen\s+(an?\s+)?issue\s+(for|to\s+track)\b/i,
  /\bcan\s+(revisit|circle\s+back)\b/i,
  /\bworth\s+(a\s+)?separate\b/i,
];

const EXCEPTION_PATTERNS = [
  /\bforward[- ]looking\b/i,
];

let input = '';
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  let event;
  try {
    event = JSON.parse(input);
  } catch {
    console.log(JSON.stringify({ decision: 'allow' }));
    process.exit(0);
  }
  const toolInput = event.tool_input || {};
  const body = toolInput.body || toolInput.message || '';

  if (EXCEPTION_PATTERNS.some(p => p.test(body))) {
    console.log(JSON.stringify({ decision: 'allow' }));
    process.exit(0);
  }

  const match = DEFERRAL_PATTERNS.find(p => p.test(body));
  if (match) {
    const snippet = body.match(match)?.[0] || '';
    console.log(JSON.stringify({
      decision: 'block',
      reason: `Review reply contains deferral language ("${snippet}"). Fix it now, push back, or mark as ASK — don't defer to a follow-up.`,
    }));
    process.exit(0);
  }

  console.log(JSON.stringify({ decision: 'allow' }));
  process.exit(0);
});
