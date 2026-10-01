// factory-handback-gate.js — agent-scoped hooks for the cheese-factory-next
// prototype (ADR-012). Factory agents load this module through hook-runner.js
// from their own `hooks:` frontmatter; no global settings entry exists.
//
// PreToolUse(StructuredOutput): validate the handback, commit it as one
//   Wheypoint revision, and return the new pinned ref through updatedInput.
//   An invalid handback or a refused revision denies the call with a reason.
// SubagentStop: block one stop when the agent never handed back.

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const FACTORY_AGENTS = new Set(['curd-boss', 'factory-coder', 'factory-reviewer']);
const BOSS_ACTIONS = new Set(['dispatch_coder', 'dispatch_review', 'raise_fork', 'finish']);
// Prototype copy of the handback vocabulary. Easy-cheese owns the canonical
// table in easy_cheese_schemas.phase_contracts (spec FU-1).
const STATUS_RE = /^(ok|(ok-with-concerns|needs-context|gated|halt): [\x20-\x7e]{1,512})$/i;
const NEXT_BY_AGENT = {
  'factory-coder': new Set(['age', 'hold']),
  'factory-reviewer': new Set(['cure', 'done', 'mold', 'hold']),
};
const ID = '[a-z0-9][a-z0-9._-]{0,63}';
const REF_RE = new RegExp(`^wheypoint:(${ID})/(${ID})(?:@(rev-[0-9a-f]{12}))?$`);

function wheypointArchive() {
  return process.env.FACTORY_GATE_WHEYPOINT
    || path.join(os.homedir(), '.claude/skills/wheypoint/scripts/wheypoint.pyz');
}

function spoolPath(agentId) {
  const dir = path.join(process.env.FACTORY_GATE_SPOOL || os.tmpdir(), 'factory-handback');
  return path.join(dir, `${String(agentId).replace(/[^A-Za-z0-9_-]/g, '_')}.done`);
}

function singleLine(value) {
  return typeof value === 'string' && value.trim() !== '' && !/[\r\n]/.test(value);
}

function parseRef(ref) {
  const m = typeof ref === 'string' ? REF_RE.exec(ref) : null;
  return m ? { project: m[1], workId: m[2], revision: m[3] || null } : null;
}

// Return the first contract violation, or null when the handback is valid.
function violation(agentType, input) {
  if (!parseRef(input.wheypoint_ref)) {
    return 'wheypoint_ref: expected wheypoint:<project>/<work_id>[@rev-<12 hex>]';
  }
  if (agentType === 'curd-boss') {
    if (!BOSS_ACTIONS.has(input.action)) return `action: expected one of ${[...BOSS_ACTIONS].join(', ')}`;
    if (input.action.startsWith('dispatch_') && !singleLine(input.brief)) return 'brief: a dispatch needs a one-line brief';
    if (input.action === 'raise_fork') {
      const fork = input.fork || {};
      if (!singleLine(fork.question)) return 'fork.question: a fork needs a one-line question';
      if (!Array.isArray(fork.options) || fork.options.length < 2) return 'fork.options: a fork needs at least two options';
      const bad = fork.options.findIndex((o) => !o || !singleLine(String(o.option || '')) || !singleLine(o.breaks));
      if (bad >= 0) return `fork.options[${bad}]: each option needs a one-line option and breaks`;
    }
    return null;
  }
  if (!singleLine(input.status) || !STATUS_RE.test(input.status)) {
    return 'status: expected ok, or ok-with-concerns|needs-context|gated|halt: <reason>';
  }
  if (!singleLine(input.orientation)) return 'orientation: expected one line';
  const disposition = input.status.split(':')[0].toLowerCase();
  const stops = disposition === 'gated' || disposition === 'halt';
  if (!stops && !NEXT_BY_AGENT[agentType].has(input.next)) {
    return `next: ${agentType} may hand off only to ${[...NEXT_BY_AGENT[agentType]].join(', ')}`;
  }
  return null;
}

function reasonOf(status) {
  const i = status.indexOf(':');
  return i < 0 ? '' : status.slice(i + 1).trim();
}

// Build the CheckpointIntent for one handback. Wheypoint derives `status`
// from gating entries, so gated and halt become gating entries with a dossier.
function intentFor(agentType, input, ref) {
  const intent = { work_id: ref.workId, next: 'hold' };
  if (ref.revision) intent.base_revision_id = ref.revision;
  if (agentType === 'curd-boss') {
    intent.orientation = `Boss decision: ${input.action}.`;
    if (input.action === 'raise_fork') {
      const { question, options, prior_leaning: lean } = input.fork;
      intent.entries = [{ kind: 'question', summary: question, blocks_continuation: true }];
      intent.decision_dossier = [{
        fork: question.slice(0, 200),
        options: options.map((o) => ({ option: String(o.option), evidence: o.evidence || [], breaks: o.breaks })),
        prior_leaning: lean || String(options[0].option),
      }];
    } else {
      intent.entries = [{ kind: 'decision', summary: `Boss chose ${input.action}.`, rationale: input.brief || 'finish', blocks_continuation: false }];
      if (input.action === 'finish') intent.next = 'done';
    }
    return intent;
  }
  const disposition = input.status.split(':')[0].toLowerCase();
  intent.orientation = input.orientation;
  if (disposition === 'gated' || disposition === 'halt') {
    const kind = disposition === 'gated' ? 'question' : 'blocker';
    const summary = `${agentType} ${disposition}: ${reasonOf(input.status)}`.slice(0, 2000);
    intent.entries = [{ kind, summary, blocks_continuation: true }];
    intent.decision_dossier = [{
      fork: summary.slice(0, 200),
      options: [
        { option: 'resume', evidence: [], breaks: 'repeats the failure if the cause stays' },
        { option: 'abandon-curd', evidence: [], breaks: 'drops the curd from plate' },
      ],
      prior_leaning: 'resume',
    }];
  } else {
    intent.next = input.next;
    intent.entries = [{ kind: 'decision', summary: `${agentType} handed back ${disposition}.`, rationale: input.orientation, blocks_continuation: false }];
  }
  return intent;
}

function commit(intent, cwd) {
  const run = spawnSync('python3', [wheypointArchive(), 'checkpoint', '-', '--no-note'], {
    cwd, input: JSON.stringify(intent), encoding: 'utf8', timeout: 30000,
  });
  let reply = null;
  try {
    reply = JSON.parse(run.stdout || run.stderr || 'null');
  } catch {
    reply = null;
  }
  if (!reply || !reply.ok) {
    return { error: (reply && reply.error) || (run.stderr || 'wheypoint checkpoint failed').trim().slice(0, 400) };
  }
  return { revision: reply.revision_id, status: reply.status };
}

function deny(reason) {
  return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: `Factory handback gate: ${reason}` } };
}

const structuredOutputGate = {
  matcher: (toolName, _input, event) => (event.hook_event_name || 'PreToolUse') === 'PreToolUse'
    && toolName === 'StructuredOutput' && FACTORY_AGENTS.has(event.agent_type),
  handler: (_toolName, input, event) => {
    const problem = violation(event.agent_type, input);
    if (problem) return deny(`${problem}. Fix the field and call StructuredOutput again.`);
    const ref = parseRef(input.wheypoint_ref);
    const result = commit(intentFor(event.agent_type, input, ref), event.cwd || process.cwd());
    if (result.error) return deny(`wheypoint refused the revision (${result.error}). Re-resolve ${ref.project}/${ref.workId} and retry.`);
    const spool = spoolPath(event.agent_id);
    fs.mkdirSync(path.dirname(spool), { recursive: true });
    fs.writeFileSync(spool, `${ref.workId}@${result.revision}\n`);
    return {
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'allow',
        updatedInput: { ...input, wheypoint_ref: `wheypoint:${ref.project}/${ref.workId}@${result.revision}`, record_status: result.status },
      },
    };
  },
};

const stopBackstop = {
  matcher: (_toolName, _input, event) => event.hook_event_name === 'SubagentStop' && FACTORY_AGENTS.has(event.agent_type),
  handler: (_toolName, _input, event) => {
    if (fs.existsSync(spoolPath(event.agent_id))) return null;
    if (event.stop_hook_active) {
      console.error(`factory-handback-gate: ${event.agent_type} ${event.agent_id} stopped without a handback`);
      return null;
    }
    return { decision: 'block', reason: 'Factory handback gate: call StructuredOutput with your handback before you stop.' };
  },
};

module.exports = { hooks: [structuredOutputGate, stopBackstop], violation, intentFor, parseRef };
