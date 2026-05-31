#!/usr/bin/env node
// sensitive-file-guard.js — PreToolUse guard (harness-agnostic hook).
//
// Blocks reads, writes, and shell access to secret-bearing files: .env
// files, private keys, credential stores, and other sensitive material.
// Covers the file tools (Read, Edit, Write, MultiEdit), the tilth MCP
// reader/writer, and Bash (the `cat .env` / `cp .env /tmp` bypass).
//
// Self-contained: reads the PreToolUse event JSON on stdin and, when a
// target is sensitive, emits a `deny` decision on stdout. Allow = exit 0
// with no stdout. Works for BOTH Claude and Codex — Codex's PreToolUse deny
// shape is the identical `hookSpecificOutput.permissionDecision: "deny"`
// (verified: developers.openai.com/codex/hooks). Codex routes shell through
// `Bash` (tool_input.command) and edits through `apply_patch`; both are
// handled below alongside the Claude file tools and the shared tilth MCP.
//
// Enforced by default (opt-out):
//   CLAUDE_SENSITIVE_GUARD=0|false|off|no   → disable entirely
// Allow-list escape hatch (substring match against the path):
//   CLAUDE_SENSITIVE_GUARD_ALLOW=/abs/ok.env,fixtures/  (comma-separated)

const READ_TOOLS = new Set(['Read', 'mcp__tilth__tilth_read']);
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'mcp__tilth__tilth_write']);

// Non-secret .env companions — checked-in templates, never hold real values.
const SAFE_ENV = /(example|sample|template|dist|defaults)/i;

// Credential stores keyed by exact basename.
const SENSITIVE_BASENAMES = new Set([
  '.netrc', '_netrc', '.pgpass', '.npmrc', '.pypirc',
  '.git-credentials', '.htpasswd', 'kubeconfig',
  'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519',
]);

// Private-key / keystore file extensions.
const SENSITIVE_EXT = /\.(pem|key|p12|pfx|keystore|jks|ppk)$/i;

// Secret bundles by basename shape.
const SENSITIVE_NAME = [
  /^secrets?\.(ya?ml|json|toml|env)$/i, // secrets.yaml, secret.json
  /\.secret$/i,
];

function isDisabled() {
  const v = (process.env.CLAUDE_SENSITIVE_GUARD || '').trim().toLowerCase();
  return v === '0' || v === 'false' || v === 'off' || v === 'no';
}

function allowList() {
  return (process.env.CLAUDE_SENSITIVE_GUARD_ALLOW || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

function isEnvFile(base) {
  if (base === '.env') return true;
  if (!base.startsWith('.env.')) return false;
  return !SAFE_ENV.test(base);
}

// True when the basename names secret-bearing material.
function sensitiveBasename(base) {
  if (!base) return false;
  if (isEnvFile(base)) return true;
  if (SENSITIVE_BASENAMES.has(base)) return true;
  if (SENSITIVE_EXT.test(base)) return true;
  return SENSITIVE_NAME.some((re) => re.test(base));
}

// True when the path sits inside a private credential directory.
function sensitiveDir(p) {
  if (/(^|\/)\.aws\/credentials$/.test(p)) return true;
  if (/(^|\/)\.gnupg\//.test(p)) return true;
  // .ssh private material — allow the public/known/config companions.
  if (/(^|\/)\.ssh\//.test(p)) {
    const base = p.slice(p.lastIndexOf('/') + 1);
    if (base.endsWith('.pub')) return false;
    if (base === 'known_hosts' || base === 'config' || base === 'authorized_keys') return false;
    return true;
  }
  return false;
}

function isSensitive(rawPath) {
  if (!rawPath) return false;
  const p = String(rawPath).trim();
  if (!p) return false;
  if (allowList().some((a) => p.includes(a))) return false;
  const base = p.slice(p.lastIndexOf('/') + 1);
  return sensitiveBasename(base) || sensitiveDir(p);
}

// Pull candidate paths out of a Bash command line. Split on whitespace, `=`,
// and the shell metacharacters that attach a path with no surrounding space
// (`<.env`, `>./.env`, `-d@.env`, `a|cat .env`) so the path lands in its own
// token, then strip residual quote / option noise.
function bashTokens(command) {
  return String(command)
    .split(/[\s=<>|&@]+/)
    .map((t) => t.replace(/^['"]|['"]$/g, ''))
    .filter(Boolean);
}

// Codex routes file edits through `apply_patch`, whose tool_input.command is a
// patch whose headers name the target files (`*** Add|Update|Delete File: <p>`).
// Match only the headers, not patch content, to avoid flagging a diff that
// merely mentions ".env" in a code line.
function applyPatchTargets(command) {
  const out = [];
  const re = /^\*\*\*\s+(?:Add|Update|Delete)\s+File:\s+(.+?)\s*$/gm;
  let m;
  while ((m = re.exec(String(command))) !== null) out.push(m[1]);
  return out;
}

function extractTargets(toolName, input) {
  if (!input) return [];
  if (toolName === 'Bash') return bashTokens(input.command || '');
  // Codex apply_patch: target paths live in the patch headers (command field).
  if (toolName === 'apply_patch') return applyPatchTargets(input.command || '');
  if (READ_TOOLS.has(toolName) || EDIT_TOOLS.has(toolName)) {
    if (Array.isArray(input.paths)) {
      return input.paths.map((x) => (typeof x === 'string' ? x : x && x.path)).filter(Boolean);
    }
    if (Array.isArray(input.files)) {
      return input.files.filter((f) => f && f.path).map((f) => f.path);
    }
    const single = input.file_path || input.path;
    return single ? [single] : [];
  }
  return [];
}

function blockedTargets(toolName, input) {
  return extractTargets(toolName, input).filter(isSensitive);
}

function denyReason(toolName, hit) {
  return `Blocked: ${toolName} touches sensitive file(s): ${hit.join(', ')}

These hold secrets (.env values, private keys, credentials) and must not be
read into the agent context or modified by an automated tool.

- Need a real value? Pull it yourself and paste only what's required.
- Reading a checked-in template? Use the .env.example/.sample variant.
- Genuinely need access this session? export CLAUDE_SENSITIVE_GUARD=0
- Allow specific paths only: export CLAUDE_SENSITIVE_GUARD_ALLOW=/abs/path,substr`;
}

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
  const hit = blockedTargets(event.tool_name || '', event.tool_input || {});
  if (hit.length === 0) return; // allow
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: denyReason(event.tool_name || 'Tool', hit),
    },
  }));
});

// Exported for unit tests; harmless when run as a hook.
module.exports = { isSensitive, blockedTargets, extractTargets };
