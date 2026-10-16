// Shared fixtures for the move-my-cheese workflow tests. Each builder matches its stage schema.
import { resolve } from 'node:path'

import { createRuntime, loadWorkflow } from './harness.mjs'

const path = resolve(import.meta.dirname, '../../claude/workflows/move-my-cheese.js')
export const BASE_SHA = 'b'.repeat(40)

// Workflow-realm values carry foreign prototypes; clone them before deepEqual.
export const plain = (value) => JSON.parse(JSON.stringify(value))
export const sha = (n, salt = 0) => `${salt.toString(16)}${n.toString(16)}`.padStart(40, '0')

export function openPr(number, overrides = {}) {
  return { number, title: `pr ${number}`, branch: `feat/pr-${number}`, base: 'main', author: 'me', is_draft: false, is_cross_repository: false, ...overrides }
}

export function index(prs, overrides = {}) {
  return { default_branch: 'main', base_sha: BASE_SHA, viewer: 'me', open_prs: prs, ...overrides }
}

export function detail(number, overrides = {}) {
  return {
    number, title: `pr ${number}`, body: '', branch: `feat/pr-${number}`, base: 'main', head_sha: sha(number), state: 'OPEN',
    merge_state: 'CLEAN', ci: 'pass', files: [`src/${number}.js`], changed_files: 1, additions: 10, deletions: 2,
    review_decision: 'NONE', unresolved_threads: 0, aged_sha: '', aged_patch: '', aged_dirty: false, landing_digest: '', landing_head: '',
    url: `https://example.test/pr/${number}`, ...overrides,
  }
}

export const aged = (number, overrides = {}) => detail(number, { aged_sha: sha(number), aged_patch: sha(number, 7), ...overrides })
export const survey = ({ opts }) => {
  const pr = Number(opts.label.split(':')[1])
  return { pr, goal: `goal ${pr}`, approach: 'approach', contracts_touched: [], assumptions: [], completeness: 'complete', risks: [] }
}
export const noTensions = { blast_radius: 'low', tensions: [], note: '' }
export const tension = { id: 'TN-1', prs: [1, 2], kind: 'duplicate', severity: 'material', evidence: 'both add the same helper' }
export const ready = (number, overrides = {}) => ({ state: 'OPEN', head_sha: sha(number), ci: 'pass', merge_state: 'CLEAN', review_decision: 'NONE', unresolved_threads: 0, ...overrides })
export const approveP1 = { verdict: 'approve', chosen: 'P-1', concerns: [], guidance: '' }
export const approveDone = { verdict: 'approve', concerns: [], guidance: '' }
export const ageFull = (number, overrides = {}) => ({ mode: 'full', scope: 'origin/main...HEAD', slug: `pr-${number}`, artifact: `.cheese/age/pr-${number}.md`, worktree_path: `/tmp/wt-${number}`, has_medium_plus_findings: false, has_cheap_lows: false, ...overrides })
export const built = (head, worktree) => ({ status: 'done', completed: ['built'], remaining: [], checkpoint: head, head_sha: head, worktree_path: worktree, note: '' })
export const integrated = (merged) => ({ status: 'done', worktree_path: '/tmp/int', head: sha(98), merged, conflicted: [] })
export const verified = { criterion: 'AC-1', passes: true, tree_clean: true, missing_paths: [], evidence: 'grep -c printed 1' }
export const published = (target, number, head) => ({ results: [{ target, pr_number: number, url: `https://example.test/pr/${number}`, head_sha: head, changed_files: 2, lines_changed: 30 }] })
export const merged = { result: 'merged', note: '' }
export const stateMerged = { state: 'MERGED' }
export const finalized = { marker_updated: true }
// Isolated worktrees live under <main>/.claude/worktrees/<id>.
export const wt = (name) => `/repo/.claude/worktrees/wf_test-${name}`

const AC_1 = { id: 'AC-1', statement: 'the helper exists once', check_kind: 'command', check: 'node --test --test-name-pattern helper tests/helper.test.mjs' }

// Fold #1 and #2 into one new PR.
export function consolidatePlan(overrides = {}) {
  return {
    summary: 'consolidate',
    dispositions: [
      { pr: 1, action: 'supersede', target: 'T-1', reason: 'folded into T-1' },
      { pr: 2, action: 'supersede', target: 'T-1', reason: 'folded into T-1' },
    ],
    targets: [{ id: 'T-1', kind: 'new', pr: 0, branch: 'land/combined', base: 'main', title: 'feat: combined', sources: [1, 2], brief: 'combine both', resolves: ['TN-1'], satisfies: ['AC-1'], depends_on: [] }],
    criteria: [AC_1],
    open_questions: [],
    ...overrides,
  }
}

// Keep #1 and modify #2.
export function minimalPlan() {
  return {
    summary: 'minimal',
    dispositions: [
      { pr: 1, action: 'keep', target: 'T-1', reason: 'no change needed' },
      { pr: 2, action: 'modify', target: 'T-2', reason: 'drop the duplicate helper' },
    ],
    targets: [
      { id: 'T-1', kind: 'existing', pr: 1, branch: 'feat/pr-1', base: 'main', title: 'pr 1', sources: [], brief: 'keep', resolves: [], satisfies: ['AC-1'], depends_on: [] },
      { id: 'T-2', kind: 'existing', pr: 2, branch: 'feat/pr-2', base: 'main', title: 'pr 2', sources: [2], brief: 'remove the duplicate', resolves: ['TN-1'], satisfies: ['AC-1'], depends_on: [] },
    ],
    criteria: [AC_1],
    open_questions: [],
  }
}

// Keep both PRs; #1 lands first.
export function keepPlan() {
  return {
    summary: 'keep both, #1 first',
    dispositions: [{ pr: 1, action: 'keep', target: 'T-1', reason: 'fine' }, { pr: 2, action: 'keep', target: 'T-2', reason: 'fine after #1' }],
    targets: [
      { id: 'T-1', kind: 'existing', pr: 1, branch: 'feat/pr-1', base: 'main', title: 'pr 1', sources: [], brief: 'keep', resolves: [], satisfies: ['AC-1'], depends_on: [] },
      { id: 'T-2', kind: 'existing', pr: 2, branch: 'feat/pr-2', base: 'main', title: 'pr 2', sources: [], brief: 'keep', resolves: ['TN-1'], satisfies: ['AC-1'], depends_on: [] },
    ],
    criteria: [{ id: 'AC-1', statement: 'both helpers load', check_kind: 'command', check: 'node --test --test-name-pattern helpers tests/helper.test.mjs' }],
    open_questions: [],
  }
}

// Replace #1 with a new PR and keep #2.
export function replaceOnePlan() {
  return {
    summary: 'replace #1, keep #2',
    dispositions: [{ pr: 1, action: 'supersede', target: 'T-1', reason: 'rebuilt as T-1' }, { pr: 2, action: 'keep', target: 'T-2', reason: 'fine' }],
    targets: [
      { id: 'T-1', kind: 'new', pr: 0, branch: 'land/one', base: 'main', title: 'feat: one', sources: [1], brief: 'rebuild #1', resolves: ['TN-1'], satisfies: ['AC-1'], depends_on: [] },
      { id: 'T-2', kind: 'existing', pr: 2, branch: 'feat/pr-2', base: 'main', title: 'pr 2', sources: [], brief: 'keep', resolves: [], satisfies: ['AC-1'], depends_on: [] },
    ],
    criteria: [AC_1],
    open_questions: [],
  }
}

// Route each agent by label prefix; the first match wins. A function route receives the call.
export function router(routes) {
  return (call) => {
    for (const [prefix, value] of routes) {
      if (call.opts.label === prefix || call.opts.label.startsWith(`${prefix}:`)) return typeof value === 'function' ? value(call) : value
    }
    throw new Error(`unexpected agent ${call.opts.label}`)
  }
}

export const reconRoutes = (opens, details) => [['recon:index', index(opens)], ['recon:detail', { prs: details }]]
export const reconOnly = () => reconRoutes([openPr(1), openPr(2)], [detail(1), detail(2)])

// Two PRs with one duplicate tension; the single planner consolidates them. Overrides win.
export const planRoutes = (overrides = []) => [
  ...overrides,
  ...reconOnly(),
  ['survey', survey],
  ['tensions', { blast_radius: 'low', tensions: [tension], note: '' }],
  ['plan:minimal', consolidatePlan()],
  ['advise:plan:0', approveP1],
]

export const keepPlanRoutes = (overrides = []) => [
  ...overrides,
  ...reconRoutes([openPr(1), openPr(2)], [aged(1), aged(2)]),
  ['survey', survey],
  ['tensions', { blast_radius: 'low', tensions: [{ ...tension, kind: 'ordering' }], note: '' }],
  ['plan:minimal', keepPlan()],
  ['advise:plan:0', approveP1],
  ['review:1:status', ready(1)],
  ['review:2:status', ready(2)],
]

// The consolidation plan, executed without land through ready.
export const builtConsolidation = (overrides = []) => planRoutes([
  ...overrides,
  ['target:T-1', built(sha(50), '/tmp/wt-t1')],
  ['publish', published('T-1', 10, sha(50))],
  ['age:10', ageFull(10, { worktree_path: '/tmp/wt-t1' })],
  ['finalize:10', finalized],
  ['review:10:status', ready(10, { head_sha: sha(50) })],
  ['mark', { results: [{ pr: 1, action: 'drafted', note: '' }, { pr: 2, action: 'drafted', note: '' }] }],
])

// One PR with medium+ findings that a pushed cure fixes; the poll then needs two /affinage rounds.
export const curedReviewRoutes = (cure) => [
  ...reconRoutes([openPr(1)], [detail(1)]),
  ['survey', survey],
  ['tensions', noTensions],
  ['age:1', ageFull(1, { worktree_path: wt('age'), has_medium_plus_findings: true })],
  ['cure:1', cure],
  ['reage:1', ageFull(1, { mode: 'incremental', worktree_path: wt('reage') })],
  ['finalize:1', finalized],
  ['review:1:status:1', ready(1, { ci: 'fail', head_sha: sha(1, 5) })],
  ['review:1:status:2', ready(1, { ci: 'fail', head_sha: sha(1, 6) })],
  ['review:1:status', ready(1, { head_sha: sha(1, 7) })],
  ['review:1:affinage', ({ opts }) => ({ status: 'ok', pushed: true, worktree_path: wt(opts.label.replaceAll(':', '-')), note: '' })],
]
export const pushedCure = { status: 'ok', committed: true, pushed: true, head_sha: sha(1, 5), worktree_path: wt('cure'), artifact: '.cheese/cure/pr-1.md', note: '' }

export const grounded = (overrides = {}) => ({ decisions: [], prior_research: [], research_questions: [], ...overrides })

// Fallbacks after each test's own routes: every planning run grounds in the wiki, every executing run ends
// with stamp and cleanup agents, and the done advisor approves unless a test routes it first.
// The wfx runner routes answer with ok envelopes: preflight passes, a save works, and a live recon repeats the detail() heads and BASE_SHA.
export const envelope = (cmd, data) => ({ ok: true, cmd, data })
export const failure = (cmd, code, message, details) => ({ ok: false, cmd, error: { code, message, ...(details ? { details } : {}) } })
// A live recon route. heads maps a PR number to a moved head SHA; base is the live default-branch SHA.
export const liveRecon = ({ heads = {}, base = BASE_SHA } = {}) => ({ prompt }) => {
  const csv = /--prs ([0-9,]+)/.exec(prompt)[1]
  const prs = csv.split(',').map(Number).map((n) => ({ number: n, head: { ref: `feat/pr-${n}`, sha: heads[n] ?? sha(n) }, base: 'main', state: 'OPEN', mergeable: 'MERGEABLE' }))
  return envelope('recon', { prs, base: { ref: 'main', sha: base } })
}
const WFX_LABEL_RE = /^(preflight|state:|stale:|integrate|worktree:)/
// ---- Integrate and verify defaults (AC-20, AC-25) ----
// wfx integrate and wfx worktree answer ok. The default verify-criteria stub passes every criterion it receives.
export const integrateOk = ({ prompt }) => envelope('integrate', { branch: /--branch '?([^' ]+)/.exec(prompt)[1], sha: sha(98), integrated: [/--target '?([^' ]+)/.exec(prompt)[1]] })
export const passingVerdict = (ac) => ({ criterion: ac.id, passes: true, evidence: `ran ${ac.id}`, tree_clean: true, missing_paths: [] })
export const defaultVerify = (input) => ({ status: 'ok', verdicts: input.criteria.map(passingVerdict), missing: [] })
export const INT_WORKTREE = '/repo/.claude/worktrees/lnd@verify'
// A stamp check answers with the head the fake gh last served for that PR (see legacyAdapter), else sha(n).
const DEFAULT_ROUTES = [
  ['ground', grounded()], ['advise:done', approveDone],
  ['stampcheck', ({ opts }) => envelope('poll', pollData({ headRefOid: servedHeads.get(Number(opts.label.split(':')[1])) ?? sha(Number(opts.label.split(':')[1])) }))],
  ['stamp', envelope('stamp', { stamped: true })],
  ['cleanup:sweep', envelope('worktree', { root: '/repo', worktrees: [] })],
  ['cleanup', ({ prompt }) => envelope('worktree', { path: /--path '?([^' ]+)/.exec(prompt)[1], removed: true })],
  ['preflight', envelope('preflight', { checks: [] })], ['state:put', envelope('run-state', {})], ['stale:recon', liveRecon()],
  ['integrate', integrateOk],
  ['worktree:add', envelope('worktree', { path: INT_WORKTREE, landing: 'lnd', name: 'verify', head: sha(98) })],
  ['worktree:remove', envelope('worktree', { path: INT_WORKTREE, removed: true })],
]

// ---- Legacy to envelope adapter ----
// The status, merge, and merged stages now run through wfx and answer with envelopes. Many tests still route
// them with the shapes the removed agent prompts returned: ready(n) for a status, merged for a merge,
// stateMerged for a merged wait. This adapter turns those legacy values into the matching wfx envelopes.
// A value that already is an envelope (it has ok and cmd) passes through unchanged.
const servedHeads = new Map()
export const pollData = (over = {}) => ({
  pr: 0, state: 'OPEN', isDraft: false, mergeStateStatus: 'CLEAN', reviewDecision: 'NONE', headRefOid: sha(0), baseRefName: 'main',
  checks: { passing: 1, failing: 0, pending: 0, items: [{}] }, unresolvedThreads: 0, ...over,
})
const CHECKS_OF = {
  fail: { passing: 0, failing: 1, pending: 0, items: [{}] },
  pending: { passing: 0, failing: 0, pending: 1, items: [{}] },
  none: { passing: 0, failing: 0, pending: 0, items: [] },
  pass: { passing: 1, failing: 0, pending: 0, items: [{}] },
}
const isEnvelope = (v) => Boolean(v) && typeof v === 'object' && 'ok' in v && 'cmd' in v
function legacyToEnvelope({ opts, prompt }, value) {
  const label = opts.label
  const pr = Number(/--pr (\d+)/.exec(prompt)?.[1] ?? 0)
  if (/:status:\d+/.test(label) && value && 'merge_state' in value) {
    const draft = value.merge_state === 'DRAFT'
    servedHeads.set(pr, value.head_sha)
    return envelope('poll', pollData({
      pr, state: value.state, isDraft: draft, mergeStateStatus: draft ? 'CLEAN' : value.merge_state, headRefOid: value.head_sha,
      reviewDecision: value.review_decision, checks: CHECKS_OF[value.ci], unresolvedThreads: value.unresolved_threads,
    }))
  }
  if (/^merge:/.test(label) && value && 'result' in value) {
    return value.result === 'refused'
      ? failure('merge', 'merge-failed', value.note)
      : envelope('merge', { pr, method: 'squash', head: /--head (\S+)/.exec(prompt)?.[1] ?? '', queued: value.result === 'queued' })
  }
  if (/^merged:/.test(label) && value && 'state' in value) return envelope('poll', pollData({ pr, state: value.state }))
  return value
}
export const legacyAdapter = (respond) => (call) => {
  const value = respond(call)
  if (isEnvelope(value)) {
    if (value.ok && value.cmd === 'poll' && /--pr (\d+)/.test(call.prompt) && value.data.headRefOid) servedHeads.set(Number(/--pr (\d+)/.exec(call.prompt)[1]), value.data.headRefOid)
    return value
  }
  return legacyToEnvelope(call, value)
}

// A test may pass its own budget object; the harness default has no total, so the floor never applies.
// child stands in for workflow(): brie-ground research and the age-fanout child.
// verify replaces the default verify-criteria stub: it receives the child input and returns the result or throws.
export async function run(args, routes, budget = null, child = null, verify = defaultVerify) {
  const workflow = await loadWorkflow(path)
  servedHeads.clear()
  const { globals, trace } = createRuntime({ respond: legacyAdapter(router([...routes, ...DEFAULT_ROUTES])) })
  const workflowCalls = []
  const stub = async (name, input) => {
    workflowCalls.push({ name, input: plain(input) })
    if (name === 'verify-criteria') return verify(input)
    if (!child) throw new Error('workflow() is not supported in the offline harness')
    return child(name, input)
  }
  const result = await workflow.run({ ...globals, ...(budget ? { budget } : {}), workflow: stub, args })
  // trace, labels, and call show the planning and build agents. The wfx runner calls sit in raw and wfxLabels.
  const isWfx = ({ opts }) => WFX_LABEL_RE.test(opts.label)
  const shown = { ...trace, agents: trace.agents.filter((a) => !isWfx(a)) }
  const labels = shown.agents.map(({ opts }) => opts.label)
  const wfxLabels = trace.agents.filter(isWfx).map(({ opts }) => opts.label)
  const call = (label) => trace.agents.find(({ opts }) => opts.label === label)
  return { result, trace: shown, raw: trace, labels, wfxLabels, call, workflowCalls }
}

// Plan once, then return the args that approve that plan.
export async function approve(routes, extra = {}) {
  const first = await run({ prs: [1, 2] }, routes)
  return { first, args: { prs: [1, 2], plan: plain(first.result.landing), approve: first.result.digest, ...extra } }
}
