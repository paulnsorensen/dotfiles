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
export const ageFull = (number, overrides = {}) => ({ mode: 'full', scope: 'origin/main...HEAD', slug: `pr-${number}`, artifact: `.cheese/age/pr-${number}.md`, worktree_path: `/tmp/wt-${number}`, has_medium_plus_findings: false, ...overrides })
export const built = (head, worktree) => ({ status: 'done', completed: ['built'], remaining: [], checkpoint: head, head_sha: head, worktree_path: worktree, note: '' })
export const integrated = (merged) => ({ status: 'done', worktree_path: '/tmp/int', head: sha(98), merged, conflicted: [] })
export const verified = { criterion: 'AC-1', passes: true, evidence: 'grep -c printed 1' }
export const published = (target, number, head) => ({ results: [{ target, pr_number: number, url: `https://example.test/pr/${number}`, head_sha: head, changed_files: 2, lines_changed: 30 }] })
export const merged = { result: 'merged', note: '' }
export const stateMerged = { state: 'MERGED' }

const AC_1 = { id: 'AC-1', statement: 'the helper exists once', check_kind: 'command', check: 'grep -c helper src/1.js' }

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
      { id: 'T-2', kind: 'existing', pr: 2, branch: 'feat/pr-2', base: 'main', title: 'pr 2', sources: [], brief: 'keep', resolves: ['TN-1'], satisfies: ['AC-1'], depends_on: ['T-1'] },
    ],
    criteria: [{ id: 'AC-1', statement: 'both helpers load', check_kind: 'command', check: 'grep -c helper src/1.js src/2.js' }],
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

// Two PRs with one duplicate tension; the single planner consolidates them. Overrides win.
export const planRoutes = (overrides = []) => [
  ...overrides,
  ...reconRoutes([openPr(1), openPr(2)], [detail(1), detail(2)]),
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
  ['integrate:pre', integrated(['T-1'])],
  ['verify:pre:AC-1', verified],
  ['publish', published('T-1', 10, sha(50))],
  ['age:10', ageFull(10, { worktree_path: '/tmp/wt-t1' })],
  ['finalize:10', { pushed: false, head_sha: sha(50), marker_updated: true }],
  ['review:10:status', ready(10, { head_sha: sha(50) })],
  ['mark', { results: [{ pr: 1, action: 'drafted', note: '' }, { pr: 2, action: 'drafted', note: '' }] }],
])

export async function run(args, routes) {
  const workflow = await loadWorkflow(path)
  // Every executing run ends with a stamp agent; tests that care route it themselves.
  const { globals, trace } = createRuntime({ respond: router([...routes, ['stamp', { results: [] }]]) })
  const result = await workflow.run({ ...globals, args })
  const labels = trace.agents.map(({ opts }) => opts.label)
  const call = (label) => trace.agents.find(({ opts }) => opts.label === label)
  return { result, trace, labels, call }
}

// Plan once, then return the args that approve that plan.
export async function approve(routes, extra = {}) {
  const first = await run({ prs: [1, 2] }, routes)
  return { first, args: { prs: [1, 2], plan: plain(first.result.landing), approve: first.result.digest, ...extra } }
}
