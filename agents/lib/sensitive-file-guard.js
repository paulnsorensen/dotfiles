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

const path = require('path');

const READ_TOOLS = new Set(['Read', 'mcp__tilth__tilth_read']);
const SEARCH_TOOL = 'mcp__tilth__tilth_search';
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'mcp__tilth__tilth_write']);

// Non-secret .env companions — checked-in templates, never hold real values.
// Anchored to the trailing segment so a real secret file whose name merely
// contains a safe keyword (`.env.notsample`, `.env.template-prod`) is still
// guarded.
const SAFE_ENV = /\.(example|sample|template|dist|defaults)$/i;

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
// the metacharacters that attach a path with no surrounding space
// (`<.env`, `>./.env`, `-d@.env`, `a|cat .env`), and the command separators
// that chain or substitute a second command (`cat .env;…`, `echo $(cat .env)`,
// `(cat .env)`, `` cat `.env` ``) so the path always lands in its own token,
// then strip residual quote / option noise.
function bashTokens(command) {
  return String(command)
    .split(/[\s=<>|&@;()$`]+/)
    .map(unquote)
    .filter(Boolean);
}

function unquote(token) {
  return token.replace(/^['"]|['"]$/g, '');
}

// Split a command into simple commands at the unquoted separators (`|`, `;`,
// `&`, `(`, `)`, backtick, newline). Quoted text stays whole, so the jq
// filter in `jq 'to_entries[] | .key'` stays inside its jq command.
// Return null when this scan cannot follow the shell: an unquoted `#`
// (comment), `$'...'` or `$"..."` quoting, or an open quote at the end.
function shellSegments(command) {
  const segments = [];
  const s = String(command);
  let cur = '';
  let quote = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '\\' && quote !== "'" && i + 1 < s.length) {
      cur += c + s[++i];
    } else if (quote) {
      cur += c;
      if (c === quote) quote = '';
    } else if (c === '#' || (c === '$' && (s[i + 1] === "'" || s[i + 1] === '"'))) {
      return null;
    } else if (c === "'" || c === '"') {
      quote = c;
      cur += c;
    } else if ('|;&()`\n'.includes(c)) {
      segments.push(cur);
      cur = '';
    } else {
      cur += c;
    }
  }
  if (quote) return null;
  segments.push(cur);
  return segments;
}

// Keep shell word boundaries when selecting file-loading option operands.
function shellWords(segment) {
  const words = [];
  let word = '';
  let quote = '';
  let started = false;
  for (let i = 0; i < segment.length; i++) {
    const c = segment[i];
    if (c === '\\' && quote !== "'") {
      if (i + 1 === segment.length) return null;
      const next = segment[++i];
      if (next === '\n') continue;
      if (quote === '"' && !'\\$`"'.includes(next)) word += c + next;
      else word += next;
      started = true;
    } else if (quote) {
      if (c === quote) quote = '';
      else word += c;
      started = true;
    } else if (c === "'" || c === '"') {
      quote = c;
      started = true;
    } else if (/\s/.test(c)) {
      if (started) words.push(word);
      word = '';
      started = false;
    } else {
      word += c;
      started = true;
    }
  }
  if (quote) return null;
  if (started) words.push(word);
  return words;
}

// Leading words that run the next word as the command.
const COMMAND_WRAPPERS = new Set(['command', 'eatmydata', 'env', 'exec', 'nice', 'nohup', 'sudo', 'time', 'xargs']);

// 'jq' when a simple command runs jq by name or path, 'gh' when it runs `gh`
// with `--jq` or `-q`, else ''. Leading `VAR=value` words and wrappers are
// skipped.
function jqKind(words) {
  let i = 0;
  while (i < words.length && (/^[A-Za-z_]\w*=/.test(words[i]) || COMMAND_WRAPPERS.has(words[i]))) i++;
  const cmd = path.basename(words[i] || '');
  if (cmd === 'jq') return 'jq';
  if (cmd === 'gh' && words.some((w) => w === '-q' || w === '--jq' || w.startsWith('--jq='))) return 'gh';
  return '';
}

// True when jq reads its program from a file (`-f`, `-rf`, `--from-file`).
// Then the first positional word is a file, not a filter.
function jqProgramFromFile(words) {
  return words.some((w) => /^-[A-Za-z]*f[A-Za-z]*$/.test(w) || w === '--from-file');
}

// Files the command reads, writes, or sends by option or redirect: the file
// of jq `--rawfile`/`--slurpfile <name> <file>`, gh `--input <file>`, each
// `@<file>` value (gh `-F key=@file`), and each `<` / `>` target.
function fileOperands(segment, words, kind) {
  const out = [];
  words.forEach((w, i) => {
    if (w === '--rawfile' || w === '--slurpfile') out.push(words[i + 2]);
    if (kind === 'gh' && w === '--input') out.push(words[i + 1]);
    if (kind === 'gh' && w.startsWith('--input=')) out.push(w.slice('--input='.length));
  });
  for (const m of segment.matchAll(/(?:[<>]+&?\s*|@)([^\s<>|;&()]+)/g)) out.push(m[1]);
  return out.filter(Boolean).flatMap(bashTokens);
}

// A jq path such as `.key`, `.[].key`, or `.data.pem` starts with `.` and has
// no `/`. The split above makes it a token that the key-extension and
// `.secret` rules match. `.env*` and credential basenames such as `.netrc`
// are never jq paths.
function isJqPath(token) {
  return /^\.[^/]*$/.test(token) && !isEnvFile(token) && !SENSITIVE_BASENAMES.has(token);
}

// Bash targets: every token, except that a jq command drops its jq paths.
// No token is dropped when shellSegments cannot follow the command, when a
// jq command holds a command substitution (`$(...)` or a backtick), or when
// jq reads its program from a file. A file operand stays a target.
// Residual risk: a positional jq file operand that looks like a jq path
// (`jq . .key`) is not a target.
function bashTargets(command) {
  const segments = shellSegments(command);
  if (!segments) return bashTokens(command);
  return segments.flatMap((segment) => {
    const tokens = bashTokens(segment);
    const words = segment.trim().split(/\s+/).map(unquote);
    const kind = jqKind(words);
    if (!kind || /\$\(|`/.test(segment) || (kind === 'jq' && jqProgramFromFile(words))) return tokens;
    const operands = new Set(fileOperands(segment, words, kind));
    const targets = tokens.filter((t) => operands.has(t) || !isJqPath(t));
    if (kind !== 'jq') return targets;
    const boundWords = shellWords(segment);
    if (!boundWords) return targets;
    for (let i = 0; i < boundWords.length; i++) {
      const word = boundWords[i];
      if (word === '--') break;
      if (word === '--rawfile' || word === '--slurpfile') {
        const file = boundWords[i + 2];
        if (file && !targets.includes(file)) targets.push(file);
        i += 2;
      } else if (word === '--arg' || word === '--argjson' || word === '--argfile') {
        i += 2;
      } else if (word === '--indent' || word === '-L' || word === '--library-path') {
        i++;
      }
    }
    return targets;
  });
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

function resolveEditPath(rawPath, cwd) {
  if (typeof rawPath !== 'string' || !rawPath || typeof cwd !== 'string' || !cwd || path.isAbsolute(rawPath)) return rawPath;
  return path.resolve(cwd, rawPath);
}

function resolveTilthReadPath(rawPath, cwd) {
  if (typeof rawPath !== 'string') return rawPath;
  return resolveEditPath(rawPath.split('#', 1)[0], cwd);
}

function tilthReadTargets(input) {
  if (!Array.isArray(input.paths)) return [];
  return input.paths
    .map((x) => (typeof x === 'string' ? x : x && x.path))
    .filter(Boolean)
    .map((rawPath) => resolveTilthReadPath(rawPath, input.cwd));
}

function editTargets(input) {
  if (!Array.isArray(input.edits)) return [];
  const targets = [];
  for (const edit of input.edits) {
    if (!edit || typeof edit.path !== 'string' || !edit.path) continue;
    targets.push(resolveEditPath(edit.path, input.cwd));
    if (!Array.isArray(edit.ops)) continue;
    for (const op of edit.ops) {
      if (op && op.op === 'move_file' && typeof op.dest === 'string' && op.dest) {
        targets.push(resolveEditPath(op.dest, input.cwd));
      }
    }
  }
  return targets;
}

// tilth_search targets: every query glob, plus the scope. A glob is also
// tried with its wildcards stripped, because a wildcard can match nothing:
// `.env*` and `*.env` both match `.env`. The stripped `*.pem` is `.pem`,
// which the key-extension rule catches.
// A scope that is a credential directory itself (`~/.aws`, `.ssh`) is
// sensitive because the search would read the files inside it.
// A leading-wildcard glob with a source extension (`*.env.ts`) names source
// files such as `server.env.ts`, not a dotenv file, so it keeps only the raw glob.
const SOURCE_EXT = /\.(c|cc|cpp|cs|css|go|h|html|java|jsx?|kt|md|mjs|cjs|php|py|rb|rs|scss|sh|swift|tsx?|vue)$/i;

function globCandidates(glob) {
  const lead = glob.replace(/(^|\/)\*+(?=[^/*])/g, '$1'); // leading `*` of a path segment
  const bare = lead.replace(/\*+$/, ''); // trailing `*`
  if (lead !== glob && SOURCE_EXT.test(bare)) return [glob];
  return [glob, bare];
}

function tilthSearchTargets(input) {
  const out = [];
  if (Array.isArray(input.queries)) {
    for (const q of input.queries) {
      if (!q || typeof q.glob !== 'string' || !q.glob) continue;
      out.push(...globCandidates(q.glob));
    }
  }
  if (typeof input.scope === 'string' && input.scope) {
    const scope = resolveEditPath(input.scope, input.cwd);
    out.push(scope);
    if (/(^|\/)\.(aws|ssh|gnupg)\/?$/.test(scope)) out.push(scope.replace(/\/?$/, '/') + 'credentials');
  }
  return out;
}

function extractTargets(toolName, input) {
  if (!input) return [];
  if (toolName === SEARCH_TOOL) return tilthSearchTargets(input);
  if (toolName === 'Bash') return bashTargets(input.command || '');
  // Codex apply_patch: target paths live in the patch headers (command field).
  if (toolName === 'apply_patch') return applyPatchTargets(input.command || '');
  if (READ_TOOLS.has(toolName) || EDIT_TOOLS.has(toolName)) {
    const targets = editTargets(input);
    if (toolName === 'mcp__tilth__tilth_read') {
      targets.push(...tilthReadTargets(input));
    } else if (Array.isArray(input.paths)) {
      targets.push(...input.paths.map((x) => (typeof x === 'string' ? x : x && x.path)).filter(Boolean));
    }
    if (Array.isArray(input.files)) {
      targets.push(...input.files.filter((f) => f && f.path).map((f) => f.path));
    }
    const single = input.file_path || input.path;
    if (single) {
      targets.push(toolName === 'mcp__tilth__tilth_read'
        ? resolveTilthReadPath(single, input.cwd)
        : single);
    }
    return targets;
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

- For structure, use a checked-in template such as .env.example or .env.sample.
- For a real value, ask the operator to run the action and return only a non-secret result.
- If no compliant route works, ask the user for explicit approval before changing guard controls.`;
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
