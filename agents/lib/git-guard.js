#!/usr/bin/env node
// git-guard.js — PreToolUse guard (harness-agnostic hook).
//
// Blocks destructive git ops that silently discard uncommitted work — but
// ONLY when the targeted paths actually have uncommitted changes. A clean
// tree has nothing to lose, so the op is allowed and the guard never nags.
//
// Caught: `git checkout -- <path>` / `git checkout .` / `git checkout -f`,
//         `git restore <path>`, `git reset --hard`, `git clean -f`.
// Allowed: `git checkout <branch>` (a real branch switch) and every
//          destructive verb when the relevant paths are clean.
//
// This exists because `git checkout -- file` resets the WHOLE file to its
// committed state — used to "undo one edit", it wipes all uncommitted work
// in that file with no recovery. The escape hatch is in the message:
// commit/stash first (recoverable), or undo a single edit with Edit instead.
//
// Self-contained: reads the PreToolUse event JSON on stdin and, when the
// command is destructive against a dirty tree, emits a `deny` decision on
// stdout. Allow = exit 0 with no stdout. Works for BOTH Claude and Codex —
// their PreToolUse deny shape is the identical
// `hookSpecificOutput.permissionDecision: "deny"`, and both route shell
// through the `Bash` tool with `tool_input.command` (verified:
// developers.openai.com/codex/hooks). The dirty-tree check runs against the
// event's `cwd` (both harnesses provide it), falling back to process.cwd().
//
// Enforced by default (opt-out):
//   CLAUDE_GIT_GUARD=0|false|off|no   → disable entirely

const { execSync } = require('child_process');

function isDisabled() {
  const v = (process.env.CLAUDE_GIT_GUARD || '').trim().toLowerCase();
  return v === '0' || v === 'false' || v === 'off' || v === 'no';
}

// Segment a command line on shell operators so each git invocation in a
// compound command is classified independently.
function splitSegments(command) {
  return command.split(/(?:&&|\|\||[;&|\n()])+/);
}

// Leading `sudo`/`env`, then the git global options that take a value, so the
// real subcommand is found whether or not `-C <dir>` / `-c k=v` precede it.
// After an `env` prefix, also skip `VAR=value` assignment tokens
// (`env GIT_PAGER=cat git …`) so the wrapped git invocation is still found.
function gitArgs(seg) {
  const tokens = seg.trim().split(/\s+/).filter(Boolean);
  let i = 0;
  while (i < tokens.length && (tokens[i] === 'sudo' || /(^|\/)env$/.test(tokens[i]))) {
    const wasEnv = /(^|\/)env$/.test(tokens[i]);
    i++;
    if (wasEnv) {
      while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) i++;
    }
  }
  if (i >= tokens.length || !/(^|\/)git$/.test(tokens[i])) return null;
  return tokens.slice(i + 1);
}

function subcommand(args) {
  let j = 0;
  while (j < args.length && args[j].startsWith('-')) {
    if (args[j] === '-C' || args[j] === '-c') j += 2;
    else j += 1;
  }
  return { sub: args[j], rest: args.slice(j + 1) };
}

function pathsAfterDashDash(arr) {
  const k = arr.indexOf('--');
  return k >= 0 ? arr.slice(k + 1) : null;
}

// Returns { reason, paths } when the segment is destructive-to-uncommitted,
// else null. `paths === null` means "whole tree" (reset --hard / clean).
// `paths` as a list means scope the dirty check to those pathspecs.
function classify(seg) {
  const args = gitArgs(seg);
  if (!args) return null;
  const { sub, rest } = subcommand(args);
  if (!sub) return null;

  if (sub === 'restore') {
    const dd = pathsAfterDashDash(rest);
    const paths = dd || rest.filter((a) => !a.startsWith('-'));
    return { reason: 'git restore discards uncommitted changes', paths };
  }
  if (sub === 'reset' && rest.includes('--hard')) {
    return { reason: 'git reset --hard discards all uncommitted changes', paths: null };
  }
  if (sub === 'clean' && rest.some((a) => /^-[a-zA-Z]*f/.test(a))) {
    return { reason: 'git clean -f deletes untracked files', paths: null };
  }
  if (sub === 'checkout') {
    const dd = pathsAfterDashDash(rest);
    if (dd) return { reason: 'git checkout -- <path> discards uncommitted changes', paths: dd };
    if (rest.includes('.')) return { reason: 'git checkout . discards uncommitted changes', paths: ['.'] };
    if (rest.some((a) => a === '-f' || a === '--force')) {
      return { reason: 'git checkout -f discards uncommitted changes', paths: null };
    }
    // Otherwise a branch switch — not destructive to the working tree.
  }
  return null;
}

function classifyCommand(command) {
  for (const seg of splitSegments(command)) {
    const hit = classify(seg);
    if (hit) return hit;
  }
  return null;
}

function pathsDirty(cwd, paths) {
  try {
    const spec =
      paths && paths.length
        ? ' -- ' + paths.map((p) => `'${p.replace(/'/g, "'\\''")}'`).join(' ')
        : '';
    const out = execSync('git status --porcelain' + spec, {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    return out.trim().length > 0;
  } catch {
    return false; // not a git repo / git unavailable → never block
  }
}

// The user-facing block message. `command` is the offending command line.
function denyReason(command, hit) {
  return `Blocked: destructive git op against a dirty working tree.

  ${command}

${hit.reason}, and \`git status\` shows uncommitted changes there that are not
staged or committed anywhere — they would be unrecoverable. This is exactly how
working-tree work gets wiped by a whole-file revert.

Before re-running:
  • To undo a single edit you just made, put it back with Edit — not git.
  • To keep the work, commit it (git add -p && git commit) or git stash first.
  • To genuinely discard, stash/commit first so it stays recoverable, then run
    this — or run it yourself outside the agent.

Or export CLAUDE_GIT_GUARD=0 to disable this guard for the session.`;
}

// True when the Bash command should be blocked given the working tree.
// Pure over (command, cwd) — the unit-testable core the adapters call.
// Returns the classify hit when it should block, else null.
function shouldBlock(command, cwd) {
  const hit = classifyCommand(command || '');
  if (!hit) return null;
  if (!pathsDirty(cwd, hit.paths)) return null;
  return hit;
}

function main() {
  let stdin = '';
  process.stdin.on('data', (chunk) => { stdin += chunk; });
  process.stdin.on('end', () => {
    if (isDisabled()) return; // allow
    let event;
    try {
      event = JSON.parse(stdin);
    } catch {
      return; // fail-open on malformed input
    }
    if ((event.tool_name || '') !== 'Bash') return; // allow non-shell tools
    const command = ((event.tool_input && event.tool_input.command) || '').trim();
    const cwd = event.cwd || process.cwd();
    const hit = shouldBlock(command, cwd);
    if (!hit) return; // allow
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: denyReason(command, hit),
      },
    }));
  });
}

if (require.main === module) main();

// Exported for unit tests and the Cursor/Copilot adapters; harmless as a hook.
module.exports = { classify, classifyCommand, pathsDirty, shouldBlock, denyReason, isDisabled };
