#!/usr/bin/env node
// tool-reroute.js — PreToolUse rewrite hook (harness-agnostic).
//
// Transparently REWRITES wrong-tool Bash/Grep/Glob calls to their tilth /
// wt-git shell equivalent, DENIES the two cross-tool cases that have no shell
// rewrite target (the Grep/Glob tools, shell write-redirects), and DELEGATES
// every other Bash command to the harness's rtk hook for token compaction.
//
// Four detection modules run in order; the FIRST hit wins:
//   search   → grep/rg/ag/ack/find + the Grep/Glob tools
//   cd-strip → `cd <cwd> && …` — strip a no-op cd to the event's own cwd,
//              then re-classify the remainder against search/cd-git/io
//   cd-git   → `cd <path> && git …` (including a git-only chain)
//   io       → write-redirect (deny) / bare `cat` (rewrite)
// Each module's detect() returns {rewrite} (allow + updatedInput), {reason}
// (deny + message), or null. A null from every module on a Bash call means
// "not ours" → delegate to `rtk hook <harness>` (argv[2]), piping the original
// event through and echoing rtk's output verbatim, so non-reroute commands keep
// rtk's compaction.
//
// One exception sits before the delegate: inside a Claude-created isolated
// worktree (cwd under `.claude/worktrees/`) a plain `git …` PASSES THROUGH
// untouched (module tag `worktree-git`, action `passthrough`). Claude Code's
// worktree-isolation guard refuses the rtk rewrite (`rtk git status`) because
// it cannot prove the wrapped operand targets the agent's own worktree; the
// plain command is allowed. Git output is small — the lost compaction is
// accepted.
//
// Fail-open everywhere: malformed stdin, a thrown detection error, or an absent
// rtk all resolve to exit 0 with no rewrite — the command runs unchanged. A
// rewrite hook must never become a denial-of-service.

const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { appendJsonl, scrubSecrets } = require('./jsonl-log');
const { parse, commandWord } = require('./tool-reroute/shell');
const search = require('./tool-reroute/search');
const cdStrip = require('./tool-reroute/cd-strip');
const cdGit = require('./tool-reroute/cd-git');
const io = require('./tool-reroute/io');

const MODULES = [search, cdStrip, cdGit, io];
// Modules re-run against the cd-strip remainder — everything except cd-strip
// itself, so a stripped command can still hit search/cd-git/io.
const AFTER_STRIP = [search, cdGit, io];

// Pure over (toolName, input, cwd): the first module hit, or null. The unit-
// testable core the stdin adapter calls. A cd-strip hit is re-classified
// against the remaining modules on the stripped command; a hit there wins
// (its own module/rewrite/reason), otherwise the strip stands alone, tagged
// action: 'strip' so main() routes it through the rtk-delegating strip path
// instead of an unconditional allow.
function classify(toolName, input, cwd) {
  for (const m of MODULES) {
    const hit = m.detect(toolName, input, cwd);
    if (!hit) continue;
    if (m !== cdStrip) return hit;
    const rehit = classifyWith(AFTER_STRIP, toolName, { ...input, command: hit.rewrite }, cwd);
    return rehit || { ...hit, action: 'strip' };
  }
  return null;
}

function classifyWith(modules, toolName, input, cwd) {
  for (const m of modules) {
    const hit = m.detect(toolName, input, cwd);
    if (hit) return hit;
  }
  return null;
}

const MAX_LOG_BYTES = 5 * 1024 * 1024;
const MAX_TEXT_LENGTH = 500;

function safeText(value) {
  return scrubSecrets(String(value)).slice(0, MAX_TEXT_LENGTH);
}

function logDir() {
  return process.env.CLAUDE_TOOL_REROUTE_LOG_DIR
    || (process.env.XDG_STATE_HOME && path.join(process.env.XDG_STATE_HOME, 'claude-tool-reroute'))
    || path.join(os.homedir(), '.local', 'state', 'claude-tool-reroute');
}

// Log a rewrite/deny/strip/passthrough decision to decisions.jsonl. Never
// called for a plain delegate — that path carries no module/action to record.
function logDecision(harness, event, toolName, cwd, hit, action) {
  const command = (event.tool_input && event.tool_input.command) || '';
  appendJsonl(logDir(), 'decisions.jsonl', {
    ts: new Date().toISOString(),
    harness,
    session_id: event.session_id || null,
    cwd,
    tool_name: toolName,
    module: hit.module || null,
    action,
    command,
    ...(hit.pattern !== undefined ? { pattern: hit.pattern } : {}),
    ...(action === 'rewrite' || action === 'strip'
      ? { rewrite: hit.rewrite }
      : { reason: hit.reason }),
  }, MAX_LOG_BYTES);
}

// Hand stdin to the harness's rtk hook and return its stdout, or null on a
// fail-open condition (rtk absent — ENOENT — or killed).
function runRtk(harness, stdin) {
  const res = spawnSync('rtk', ['hook', harness], { input: stdin, encoding: 'utf8' });
  if (res.error || res.status === null) return null; // fail open
  return res.stdout || null;
}

// Hand the original event to the harness's rtk hook and echo its stdout
// verbatim (the plain delegate path — no reroute module owns this command).
function delegate(harness, stdin) {
  const out = runRtk(harness, stdin);
  if (out) process.stdout.write(out);
}

// Claude Code's Agent tool (`isolation: "worktree"`) creates its worktrees
// under `<repo>/.claude/worktrees/agent-*`, and its isolation guard applies
// only to those. A path test is sufficient — no `git rev-parse`: the hook runs
// on every Bash call inside a 5 s budget.
function isIsolatedWorktree(cwd) {
  return /\/\.claude\/worktrees\//.test(cwd);
}

// True when any segment's command word is `git` (commandWord already strips
// env assignments and a leading `rtk` / `rtk proxy`). A lexer miss fails
// closed to false, so an odd shape keeps the plain delegate path.
function mentionsGit(command) {
  try {
    return parse(command).some((seg) => commandWord(seg.argv).word === 'git');
  } catch {
    return false;
  }
}

function main() {
  const harness = process.argv[2] || 'claude';
  let stdin = '';
  process.stdin.on('data', (chunk) => { stdin += chunk; });
  process.stdin.on('end', () => {
    let event;
    try {
      event = JSON.parse(stdin);
    } catch {
      return; // fail-open on malformed input
    }
    const toolName = event.tool_name || '';
    const input = event.tool_input || {};
    const cwd = event.cwd || process.cwd();

    let hit;
    try {
      hit = classify(toolName, input, cwd);
    } catch {
      return; // fail-open on a detection bug
    }

    if (hit && hit.action === 'strip') {
      // A no-op cd-strip with no rehit: rewrite the event's command and hand
      // it to rtk so a stripped command still gets rtk's own compaction. Per
      // Claude Code's PreToolUse contract, updatedInput WITHOUT
      // permissionDecision runs normal permission evaluation on the rewritten
      // input — the desired behaviour for a strip-only hit (no auto-allow).
      const strippedEvent = { ...event, tool_input: { ...input, command: hit.rewrite } };
      const rtkOut = runRtk(harness, JSON.stringify(strippedEvent));
      logDecision(harness, event, toolName, cwd, hit, 'strip');
      let forwarded = null;
      if (rtkOut) {
        try {
          const parsed = JSON.parse(rtkOut);
          if (parsed && typeof parsed === 'object') forwarded = rtkOut;
        } catch {
          /* rtk printed non-JSON — fall through to the plain strip output */
        }
      }
      process.stdout.write(forwarded !== null ? forwarded : JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          updatedInput: { ...input, command: hit.rewrite },
        },
      }));
      return;
    }
    if (hit && hit.rewrite !== undefined) {
      const orig = input.command || '';
      logDecision(harness, event, toolName, cwd, hit, 'rewrite');
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'allow',
          permissionDecisionReason: safeText('tool-reroute: ' + orig + ' → ' + hit.rewrite),
          updatedInput: { ...input, command: hit.rewrite },
        },
      }));
      return;
    }
    if (hit && hit.reason !== undefined) {
      logDecision(harness, event, toolName, cwd, hit, 'deny');
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: safeText(hit.reason),
        },
      }));
      return;
    }
    // No module owns it. Allow any other tool untouched. Inside an isolated
    // worktree a plain git command runs unchanged (see header); otherwise
    // delegate Bash to rtk.
    if (toolName !== 'Bash') return;
    if (isIsolatedWorktree(cwd) && mentionsGit(input.command || '')) {
      logDecision(harness, event, toolName, cwd, {
        module: 'worktree-git',
        reason: 'isolated worktree: plain git passes through so Claude Code can verify its target',
      }, 'passthrough');
      return;
    }
    delegate(harness, stdin);
  });
}

if (require.main === module) main();

// Exported for unit tests; harmless when run as a hook.
module.exports = { classify };
