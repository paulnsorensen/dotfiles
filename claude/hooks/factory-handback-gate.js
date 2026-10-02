// factory-handback-gate.js — the /cheese-factory handback gate.
// Settings PreToolUse(StructuredOutput) loads it through hook-runner.js.
//
// It acts only on a handback that carries a factory `role` and a
// `wheypoint_ref` whose work id starts with `factory-`, so every other
// StructuredOutput call passes through untouched. For a factory handback it
// checks the contract, commits the handback as one Wheypoint revision, and
// returns the new pinned ref and record status through updatedInput. An
// invalid handback or a refused revision denies the call with a reason, and
// the agent calls StructuredOutput again.

const { spawnSync } = require('child_process');
const os = require('os');
const path = require('path');

const BOSS_ACTIONS = new Set(['dispatch_coder', 'dispatch_review', 'raise_fork', 'finish']);
// Local copy of the handback vocabulary. Easy-cheese owns the canonical
// table in easy_cheese_schemas.phase_contracts (spec FU-1).
const STATUS_RE = /^(ok|(ok-with-concerns|needs-context|gated|halt): [\x20-\x7e]{1,512})$/i;
const NEXT_BY_ROLE = {
  coder: new Set(['age', 'hold']),
  reviewer: new Set(['cure', 'done', 'mold', 'hold']),
};
const ROLES = new Set(['boss', 'coder', 'reviewer']);
const ID = '[a-z0-9][a-z0-9._-]{0,63}';
const REF_RE = new RegExp(`^wheypoint:(${ID})/(${ID})(?:@(rev-[0-9a-f]{12}))?$`);
const ENTRY_RE = /^[a-z]+-[0-9a-f]{12}$/;

function wheypointArchive() {
  return process.env.FACTORY_GATE_WHEYPOINT
    || path.join(os.homedir(), '.claude/skills/wheypoint/scripts/wheypoint.pyz');
}

function singleLine(value) {
  return typeof value === 'string' && value.trim() !== '' && !/[\r\n]/.test(value);
}

function parseRef(ref) {
  const m = typeof ref === 'string' ? REF_RE.exec(ref) : null;
  return m ? { project: m[1], workId: m[2], revision: m[3] || null } : null;
}

// A factory handback names a factory role; an unrelated StructuredOutput
// call never does.
function isFactoryHandback(input) {
  return Boolean(input) && ROLES.has(input.role)
    && typeof input.wheypoint_ref === 'string' && input.wheypoint_ref.includes('/factory-');
}

// Return the first contract violation, or null when the handback is valid.
function violation(input) {
  const ref = parseRef(input.wheypoint_ref);
  if (!ref || !ref.workId.startsWith('factory-')) {
    return 'wheypoint_ref: expected wheypoint:<project>/factory-<work_id>[@rev-<12 hex>]';
  }
  if (input.role === 'boss') {
    if (!BOSS_ACTIONS.has(input.action)) return `action: expected one of ${[...BOSS_ACTIONS].join(', ')}`;
    if (input.action === 'dispatch_coder' && !singleLine(input.brief)) return 'brief: a coder dispatch needs a one-line brief';
    if (input.action === 'raise_fork') {
      const fork = input.fork || {};
      if (!singleLine(fork.question)) return 'fork.question: a fork needs a one-line question';
      if (!Array.isArray(fork.options) || fork.options.length < 2) return 'fork.options: a fork needs at least two options';
      const bad = fork.options.findIndex((o) => !o || !singleLine(String(o.option || '')) || !singleLine(o.breaks));
      if (bad >= 0) return `fork.options[${bad}]: each option needs a one-line option and breaks`;
    }
    const resolves = input.resolves || [];
    const badResolve = resolves.findIndex((r) => !r || !ENTRY_RE.test(String(r.entry_id || '')) || !singleLine(r.quote));
    if (badResolve >= 0) return `resolves[${badResolve}]: each resolve needs an entry_id from show and the user's quote`;
    return null;
  }
  if (!singleLine(input.status) || !STATUS_RE.test(input.status)) {
    return 'status: expected ok, or ok-with-concerns|needs-context|gated|halt: <reason>';
  }
  if (!singleLine(input.orientation)) return 'orientation: expected one line';
  const disposition = input.status.split(':')[0].toLowerCase();
  const stops = disposition === 'gated' || disposition === 'halt';
  if (!stops && !NEXT_BY_ROLE[input.role].has(input.next)) {
    return `next: a ${input.role} may hand off only to ${[...NEXT_BY_ROLE[input.role]].join(', ')}`;
  }
  return null;
}

function reasonOf(status) {
  const i = status.indexOf(':');
  return i < 0 ? '' : status.slice(i + 1).trim();
}

// Build the CheckpointIntent for one handback. Wheypoint derives `status`
// from gating entries, so gated and halt become gating entries with a dossier.
function intentFor(input, ref) {
  const intent = { work_id: ref.workId, next: 'hold' };
  if (ref.revision) intent.base_revision_id = ref.revision;
  if (input.role === 'boss') {
    intent.orientation = `Boss decision: ${input.action}.`;
    const resolves = input.resolves || [];
    if (resolves.length) {
      intent.transitions = resolves.map((r) => ({ entry_id: r.entry_id, action: 'resolve', rationale: r.decision || r.quote, target_entry_id: null }));
    }
    const answers = resolves.map((r) => ({ kind: 'directive', summary: (r.decision || r.quote).slice(0, 2000), quote: r.quote, blocks_continuation: false }));
    if (input.action === 'raise_fork') {
      const { question, options } = input.fork;
      intent.entries = [...answers, { kind: 'question', summary: question, blocks_continuation: true }];
      intent.decision_dossier = [{
        fork: question.slice(0, 200),
        options: options.map((o) => ({ option: String(o.option), evidence: o.evidence || [], breaks: o.breaks })),
        prior_leaning: String(options[0].option),
      }];
    } else {
      intent.entries = [...answers, { kind: 'decision', summary: `Boss chose ${input.action}.`, rationale: input.brief || input.action, blocks_continuation: false }];
      if (input.action === 'finish') intent.next = 'done';
    }
    return intent;
  }
  const disposition = input.status.split(':')[0].toLowerCase();
  intent.orientation = input.orientation;
  if (disposition === 'gated' || disposition === 'halt') {
    const kind = disposition === 'gated' ? 'question' : 'blocker';
    const summary = `${input.role} ${disposition}: ${reasonOf(input.status)}`.slice(0, 2000);
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
    intent.entries = [{ kind: 'decision', summary: `${input.role} handed back ${disposition}.`, rationale: input.orientation, blocks_continuation: false }];
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
  matcher: (toolName, input) => toolName === 'StructuredOutput' && isFactoryHandback(input),
  handler: (_toolName, input, event) => {
    const problem = violation(input);
    if (problem) return deny(`${problem}. Fix the field and call StructuredOutput again.`);
    const ref = parseRef(input.wheypoint_ref);
    const result = commit(intentFor(input, ref), event.cwd || process.cwd());
    if (result.error) return deny(`wheypoint refused the revision (${result.error}). Run show for ${ref.workId} again and retry.`);
    return {
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'allow',
        updatedInput: { ...input, wheypoint_ref: `wheypoint:${ref.project}/${ref.workId}@${result.revision}`, record_status: result.status },
      },
    };
  },
};

module.exports = { hooks: [structuredOutputGate], violation, intentFor, parseRef, isFactoryHandback };
