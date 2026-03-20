#!/usr/bin/env node

// PreToolUse hook: blocks deferral language in PR review replies.
// Catches "will address in a follow-up" patterns that avoid doing the work now.

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
  /\bbacklog\b/i,
];

// Only "forward-looking" is OK when explicitly labeling something as not-yet-implemented
const EXCEPTION_PATTERNS = [
  /\bforward[- ]looking\b/i,  // explicitly acknowledging something is aspirational
];

const REPLY_TOOLS = new Set([
  'mcp__plugin_github_github__add_reply_to_pull_request_comment',
  'mcp__plugin_github_github__add_issue_comment',
  'mcp__plugin_github_github__pull_request_review_write',
]);

let input = '';
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const event = JSON.parse(input);
    const toolName = event.tool_name || '';
    const toolInput = event.tool_input || {};

    // Check MCP reply tools
    const isMcpReply = REPLY_TOOLS.has(toolName);

    // Check gh CLI comment commands
    const isGhComment = toolName === 'Bash' && (
      /gh\s+(pr\s+comment|api\s+repos\/[^\s]+\/issues\/\d+\/comments)/.test(toolInput.command || '')
    );

    if (!isMcpReply && !isGhComment) {
      console.log(JSON.stringify({ decision: 'allow' }));
      process.exit(0);
    }

    // Extract the reply body
    const body = toolInput.body || toolInput.message || toolInput.command || '';

    // Check for exception patterns first
    if (EXCEPTION_PATTERNS.some(p => p.test(body))) {
      console.log(JSON.stringify({ decision: 'allow' }));
      process.exit(0);
    }

    // Check for deferral patterns
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
  } catch {
    console.log(JSON.stringify({ decision: 'allow' }));
  }
  process.exit(0);
});
