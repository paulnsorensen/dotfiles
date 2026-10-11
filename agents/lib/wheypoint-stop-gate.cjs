'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const os = require('node:os');
const crypto = require('node:crypto');

function parse(value) {
  if (typeof value !== 'string') return value;
  try { return JSON.parse(value); } catch { return null; }
}

function excluded(file) {
  if (typeof file !== 'string' || !file) return true;
  const normalized = path.posix.normalize(file.replaceAll('\\\\', '/'));
  return normalized === '.cheese' || normalized.startsWith('.cheese/') ||
    normalized.includes('/.cheese/') || normalized.endsWith('/.cheese') ||
    normalized === '/tmp' || normalized.startsWith('/tmp/');
}

function gitMutation(command) {
  if (typeof command !== 'string') return false;
  const parts = command.match(/&&|\|\||[;|]|(?:[^\s"';&|]+|"[^"]*"|'[^']*')/g) || [];
  const separator = token => ['&&', '||', ';', '|'].includes(token);
  for (let i = 0; i < parts.length;) {
    let j = i;
    if (parts[j] === 'env') {
      j++;
      while (/^[A-Za-z_][A-Za-z0-9_]*=/.test(parts[j] || '')) j++;
    }
    if (parts[j] === 'command' || parts[j] === 'sudo') j++;
    if (parts[j] === 'git') {
      j++;
      while (['-C', '-c', '--git-dir', '--work-tree'].includes(parts[j])) j += 2;
      if (parts[j] === 'commit' || parts[j] === 'push') return true;
    }
    while (i < parts.length && !separator(parts[i])) i++;
    i++;
  }
  return false;
}

function callKind(name, input) {
  if (!input || typeof input !== 'object') input = {};
  if (['Edit', 'Write', 'MultiEdit', 'NotebookEdit'].includes(name)) {
    return excluded(input.file_path || input.notebook_path) ? null : 'mutation';
  }
  if (name === 'mcp__tilth__tilth_write' || name === 'tilth_tilth_write' || name.endsWith('__tilth_write')) {
    return Array.isArray(input.edits) && input.edits.some(e => !excluded(e.path)) ? 'mutation' : null;
  }
  const command = input.command || input.cmd;
  if (name === 'apply_patch' && typeof command === 'string') {
    const files = [...command.matchAll(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm)].map(match => match[1]);
    return files.some(file => !excluded(file)) ? 'mutation' : null;
  }
  if (typeof command === 'string') {
    if (/\bwheypoint\.pyz\s+checkpoint\b/.test(command)) return 'checkpoint-call';
    if (gitMutation(command)) return 'mutation';
  }
  return null;
}

function failed(output) {
  if (output == null) return true;
  if (typeof output === 'object') {
    if (output.is_error === true || output.isError === true || output.success === false) return true;
    if (typeof output.exit_code === 'number') return output.exit_code !== 0;
    if (typeof output.exitCode === 'number') return output.exitCode !== 0;
    if (output.status === 'pending' || output.session_id) return true;
    if (Array.isArray(output.content)) return output.content.some(failed);
    return false;
  }
  if (typeof output === 'string') {
    if (/Process exited with code (?!0\b)\d+/.test(output)) return true;
    const parsed = parse(output);
    if (parsed && typeof parsed === 'object') return failed(parsed);
  }
  return false;
}

function mutationSucceeded(name, input, output) {
  const parsed = parse(output);
  if (parsed && typeof parsed === 'object' && parsed !== output) return mutationSucceeded(name, input, parsed);
  if (failed(output)) return false;
  if (name === 'apply_patch') return /^Success\./.test(String(output));
  if (!(name === 'tilth_tilth_write' || name.endsWith('__tilth_write'))) return true;
  const text = Array.isArray(output?.content)
    ? output.content.map(item => item.text || '').join('\n')
    : typeof output === 'string' ? output : '';
  const sections = text.split(/^## /m).slice(1);
  if (!sections.length) return !/(?:^|\n)error:/.test(text);
  return (input?.edits || []).some(edit => {
    if (excluded(edit.path)) return false;
    return sections.some(section => {
      const [header, ...body] = section.split('\n');
      return header.trim() === edit.path && /^(?:applied|created)$/m.test(body.join('\n'));
    });
  });
}

function checkpointSucceeded(output) {
  if (typeof output === 'string') {
    const parsed = parse(output);
    if (parsed && typeof parsed === 'object') return checkpointSucceeded(parsed);
    const marker = 'Final output:\n';
    const index = output.lastIndexOf(marker);
    if (index < 0 || output.length - index > 65536) return false;
    const body = parse(output.slice(index + marker.length).trim());
    return !!body && checkpointSucceeded(body);
  }
  if (!output || typeof output !== 'object' || failed(output)) return false;
  if (output.ok === true && output.command === 'checkpoint' && output.replayed !== true) return true;
  if (Array.isArray(output.content)) return output.content.some(item => checkpointSucceeded(item.text || item));
  if (output.output != null) return checkpointSucceeded(output.output);
  return false;
}

function evaluateEvents(events) {
  let changes = 0;
  let checkpoint = false;
  for (const event of events) {
    if (!event.success) continue;
    if (event.kind === 'checkpoint') { changes = 0; checkpoint = true; }
    if (event.kind === 'mutation') changes++;
  }
  return {changes, checkpoint};
}

function lines(file) {
  return fs.readFileSync(file, 'utf8').split('\n').flatMap((line, index) => {
    if (!line.trim()) return [];
    try { return [{row: JSON.parse(line), index}]; } catch { return []; }
  });
}

function claudeRecords(rows) {
  const calls = new Map();
  const events = [];
  for (const {row, index} of rows) {
    const content = row.message?.content;
    if (!Array.isArray(content)) continue;
    for (const item of content) {
      if (item.type === 'tool_use' && item.id) calls.set(item.id, {kind: callKind(item.name, item.input), name: item.name, input: item.input});
      if (item.type !== 'tool_result') continue;
      const call = calls.get(item.tool_use_id);
      if (!call || !call.kind) continue;
      const success = item.is_error !== true && item.is_error !== 'true' && mutationSucceeded(call.name, call.input, item.content);
      const kind = call.kind === 'checkpoint-call' ? 'checkpoint' : call.kind;
      events.push({kind, success: success && (kind !== 'checkpoint' || checkpointSucceeded(item.content)), time: row.timestamp, index});
    }
  }
  return events;
}

function codexRecords(rows) {
  const calls = new Map();
  const events = [];
  for (const {row, index} of rows) {
    if (row.type !== 'response_item') continue;
    const item = row.payload || {};
    if (item.type === 'function_call') {
      calls.set(item.call_id, {name: item.name || '', input: parse(item.arguments) || item.arguments});
    } else if (item.type === 'function_call_output') {
      const call = calls.get(item.call_id);
      if (!call) continue;
      const callType = callKind(call.name, call.input);
      if (!callType) continue;
      const kind = callType === 'checkpoint-call' ? 'checkpoint' : callType;
      events.push({kind, success: mutationSucceeded(call.name, call.input, item.output) && (kind !== 'checkpoint' || checkpointSucceeded(item.output)), time: row.timestamp, index});
    }
  }
  return events;
}

function linkedClaudeChildren(transcript, rootRows) {
  const session = rootRows.find(({row}) => row.sessionId)?.row.sessionId;
  if (!session) return [];
  const dispatches = new Set(rootRows.flatMap(({row}) => {
    const content = row.message?.content;
    return Array.isArray(content)
      ? content.filter(item => item.type === 'tool_use' && ['Agent', 'Task'].includes(item.name)).map(item => item.id)
      : [];
  }));
  const dir = path.join(path.dirname(transcript), session, 'subagents');
  let names;
  try { names = fs.readdirSync(dir).filter(n => n.endsWith('.jsonl')).slice(0, 64); } catch { return []; }
  const children = [];
  for (const name of names) {
    let rows;
    try { rows = lines(path.join(dir, name)); } catch { continue; }
    let meta;
    try { meta = parse(fs.readFileSync(path.join(dir, name.replace(/\.jsonl$/, '.meta.json')), 'utf8')); } catch { meta = null; }
    const linked = (meta?.toolUseId && dispatches.has(meta.toolUseId)) ||
      rows.some(({row}) => row.sessionId === session && row.isSidechain === true);
    if (linked) children.push(...rows);
  }
  return children;
}

function journalPath(session) {
  if (typeof session !== 'string' || !session || session.length > 256) return null;
  const dir = path.join(os.tmpdir(), 'wheypoint-stop-gate');
  const id = crypto.createHash('sha256').update(session).digest('hex');
  return path.join(dir, id + '.jsonl');
}

function observe(input) {
  if (process.env.WHEYPOINT_STOP_GATE === '0') return;
  const file = journalPath(input.session_id);
  if (!file) return;
  const kind = callKind(input.tool_name || '', input.tool_input);
  if (!kind) return;
  const output = input.tool_response;
  const success = mutationSucceeded(input.tool_name || '', input.tool_input, output) &&
    (kind !== 'checkpoint-call' || checkpointSucceeded(output));
  if (!success) return;
  const event = {kind: kind === 'checkpoint-call' ? 'checkpoint' : kind, success: true};
  if (typeof input.tool_use_id === 'string') event.id = input.tool_use_id.slice(0, 128);
  fs.mkdirSync(path.dirname(file), {recursive: true, mode: 0o700});
  const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_APPEND | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeSync(fd, JSON.stringify(event) + '\n'); } finally { fs.closeSync(fd); }
}

function journalEvents(session) {
  const file = journalPath(session);
  if (!file || !fs.existsSync(file)) return [];
  const seen = new Set();
  return lines(file).map(({row}) => row).filter(event => {
    if (!['mutation', 'checkpoint'].includes(event.kind) || event.success !== true) return false;
    if (event.id && seen.has(event.id)) return false;
    if (event.id) seen.add(event.id);
    return true;
  });
}

function run(input) {
  if (process.env.WHEYPOINT_STOP_GATE === '0' || input.stop_hook_active) return null;
  if (input.hook_event_name === 'PostToolUse') { observe(input); return null; }
  const observed = process.env.DOTFILES_HARNESS === 'codex' ? journalEvents(input.session_id) : [];
  let events = observed;
  if (!events.length) {
    const transcript = input.transcript_path;
    if (typeof transcript !== 'string' || !fs.existsSync(transcript)) return null;
    const root = lines(transcript);
    const codex = root.some(({row}) => row.type === 'session_meta');
    const all = codex ? root : root.concat(linkedClaudeChildren(transcript, root));
    events = codex ? codexRecords(all) : claudeRecords(all);
    events.sort((a, b) => {
      if (a.time && b.time) return a.time.localeCompare(b.time) || a.index - b.index;
      return a.index - b.index;
    });
  }
  const state = evaluateEvents(events);
  if (!state.changes) return null;
  if (state.checkpoint) return {decision: 'block', reason: "Update this session's wheypoint with /wheypoint, then stop."};
  const cwd = typeof input.cwd === 'string' ? input.cwd : process.cwd();
  const dirty = execFileSync('git', ['-C', cwd, 'status', '--porcelain', '--', '.', ':(exclude).cheese'], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore']});
  return dirty.trim() ? {decision: 'block', reason: 'Work is uncommitted. Write a wheypoint with /wheypoint, then stop.'} : null;
}

if (require.main === module) {
  try {
    const chunks = [];
    process.stdin.on('data', chunk => chunks.push(chunk));
    process.stdin.on('end', () => {
      try {
        const raw = Buffer.concat(chunks).toString();
        const input = parse(raw);
        if (!input || typeof input !== 'object' || Array.isArray(input)) {
          if (raw.trim()) process.stderr.write('wheypoint-stop-gate: invalid hook input\n');
          return;
        }
        const decision = run(input);
        if (decision) process.stdout.write(JSON.stringify(decision) + '\n');
      } catch (error) {
        process.stderr.write('wheypoint-stop-gate: evaluation failed (' + (error.code || error.name || 'unknown') + ')\n');
      }
    });
  } catch (error) {
    process.stderr.write('wheypoint-stop-gate: input failed (' + (error.code || error.name || 'unknown') + ')\n');
  }
}

module.exports = {evaluateEvents, callKind, checkpointSucceeded, mutationSucceeded, failed, excluded, claudeRecords, codexRecords, observe, run};
