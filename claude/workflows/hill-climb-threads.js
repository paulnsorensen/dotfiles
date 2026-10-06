export const meta = {
  name: 'hill-climb-threads',
  description: 'Run several narrow /hill-climb threads in parallel worktrees: each thread iterates measure -> change -> verify -> ratchet until diminishing returns, then optionally opens one draft PR per thread',
  whenToUse: 'A performance or efficiency goal with several independent journeys or metrics to drive down at once. Use /hill-climb under /loop for one thread.',
  phases: [
    { title: 'Survey', detail: 'one read-only agent splits the goal into narrow threads, each with one journey and one deterministic metric' },
    { title: 'Adopt', detail: 'once, one agent wires the ratchet check into CI for every ratchet file when CI does not already run it' },
    { title: 'Climb', detail: 'per thread, one /hill-climb iteration per round in its own worktree; threads never wait for each other' },
    { title: 'Verify', detail: 'a skeptic re-measures every claimed gain and runs the ratchet gate; a refuted gain is reverted next round' },
    { title: 'Publish', detail: 'only when publish=true: one draft PR per thread with a verified gain, via /plate' },
  ],
}

// Source: "How we made claude.ai 3x faster" (Anthropic, 2026-09-23). The
// article ran 150+ narrow threads at once, one benchmark each, and ratcheted
// every verified gain into CI. This workflow is that horizontal shape; the
// per-iteration method lives in skills/hill-climb/SKILL.md, which each Climb
// agent loads through the Skill tool. Wiki: architecture/hill-climb-ratchet.
//
// Args: { goal: string, threads?: number | ThreadSpec[], rounds?: number,
//         dryLimit?: number, ratchetDir?: string, publish?: boolean }
//   A bare string arg is the goal. ThreadSpec = {slug, journey, metric,
//   direction?, benchmark?}; an explicit list skips Survey.
//
// Each thread climbs in its own loop, so no barrier holds a fast thread
// behind a slow one. Each thread writes its own ratchet file
// (<ratchetDir>/<slug>.json), so thread branches do not conflict on one JSON
// file. Round 1 creates the worktree; later rounds cd into the returned path
// rather than re-isolating (a second checkout of the same branch fails).
// Adopt runs once before Climb, in its own worktree and branch, so CI wiring
// never touches a thread branch.

const SLUG = /^[a-z0-9][a-z0-9-]{0,40}$/
const SAFE_PATH = /^[A-Za-z0-9._/-]+$/
const WORKTREE = /^\/[A-Za-z0-9._/-]+$/
const MAX_THREADS = 8
const MAX_ROUNDS = 12

const THREAD_SCHEMA = {
  type: 'object',
  required: ['slug', 'journey', 'metric', 'direction'],
  properties: {
    slug: { type: 'string', description: 'kebab-case, at most 41 chars' },
    journey: { type: 'string', description: 'the user-visible path this thread speeds up' },
    metric: { type: 'string', description: 'the deterministic count to ratchet' },
    direction: { type: 'string', enum: ['lower', 'higher'] },
    benchmark: { type: 'string', description: 'existing command that prints the count, or empty when one must be built' },
  },
}

const SURVEY_SCHEMA = {
  type: 'object',
  required: ['threads'],
  properties: { threads: { type: 'array', items: THREAD_SCHEMA } },
}

const CLIMB_SCHEMA = {
  type: 'object',
  required: ['status', 'worktree_path', 'change'],
  properties: {
    status: { type: 'string', enum: ['improved', 'no-gain', 'stopped', 'blocked'] },
    worktree_path: { type: 'string' },
    before: { type: 'number' },
    after: { type: 'number' },
    change: { type: 'string' },
    commit: { type: 'string' },
    stop_reason: { type: 'string' },
    reverted: { type: 'boolean', description: 'true only after you reverted the refuted commit named in the prompt' },
    benchmark: { type: 'string', description: 'the benchmark command, when you built or changed it' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['confirmed', 'note'],
  properties: {
    confirmed: { type: 'boolean' },
    note: { type: 'string' },
  },
}

const ADOPT_SCHEMA = {
  type: 'object',
  required: ['status', 'note'],
  properties: {
    status: { type: 'string', enum: ['wired', 'already-gated', 'skipped', 'failed'] },
    branch: { type: 'string' },
    note: { type: 'string' },
  },
}

const PUBLISH_SCHEMA = {
  type: 'object',
  required: ['status'],
  properties: {
    status: { type: 'string', enum: ['opened', 'updated', 'skipped', 'failed'] },
    pr_url: { type: 'string' },
    note: { type: 'string' },
  },
}

// ── args ─────────────────────────────────────────────────────────────────

function coerceArgs(a) {
  if (typeof a === 'string') return { goal: a }
  return a && typeof a === 'object' && !Array.isArray(a) ? a : {}
}

function errorText(e) {
  return e && e.message ? e.message : String(e)
}

function clampInt(value, fallback, max) {
  return Number.isInteger(value) && value > 0 ? Math.min(value, max) : fallback
}

function cleanThreads(list) {
  const seen = new Set()
  const kept = []
  for (const t of list) {
    if (!t || !SLUG.test(t.slug || '') || seen.has(t.slug)) {
      log(`Dropped thread with unsafe or duplicate slug: ${JSON.stringify(t && t.slug)}`)
      continue
    }
    seen.add(t.slug)
    kept.push({
      slug: t.slug,
      journey: String(t.journey || ''),
      metric: String(t.metric || ''),
      direction: t.direction === 'higher' ? 'higher' : 'lower',
      benchmark: String(t.benchmark || ''),
    })
  }
  if (kept.length > MAX_THREADS) log(`Keeping the first ${MAX_THREADS} of ${kept.length} threads; the rest are dropped.`)
  return kept.slice(0, MAX_THREADS)
}

const opts = coerceArgs(args)
const goal = typeof opts.goal === 'string' ? opts.goal.trim() : ''
const explicit = Array.isArray(opts.threads) ? opts.threads : null
const threadCount = clampInt(opts.threads, 3, MAX_THREADS)
const rounds = clampInt(opts.rounds, 4, MAX_ROUNDS)
const dryLimit = clampInt(opts.dryLimit, 3, MAX_ROUNDS)
const ratchetDir = typeof opts.ratchetDir === 'string' && SAFE_PATH.test(opts.ratchetDir) && !opts.ratchetDir.startsWith('/') && !opts.ratchetDir.includes('..')
  ? opts.ratchetDir.replace(/\/+$/, '')
  : 'perf/ratchet'
const publish = opts.publish === true

// ── prompts ──────────────────────────────────────────────────────────────

function surveyPrompt() {
  return [
    'Split a performance goal into narrow hill-climb threads. This is a read-only pass. Do not edit files.',
    '',
    `Goal: ${goal}`,
    `Return at most ${threadCount} threads.`,
    '',
    'Read ~/.claude/skills/hill-climb/SKILL.md and references/metrics.md first.',
    'Find the user journeys the goal names. Find existing benchmarks, profilers, and telemetry in the repository.',
    'Each thread has ONE journey and ONE deterministic count (not wall-clock time). Threads must not edit the same hot path.',
    'Set benchmark to an existing command that prints the count on its last stdout line, or to an empty string when the thread must build one.',
    'Rank threads by expected user impact.',
  ].join('\n')
}

function threadContext(t) {
  return [
    `Thread: ${t.slug}`,
    `Journey: ${t.journey}`,
    `Metric: ${t.metric} (better = ${t.direction})`,
    `Benchmark: ${t.benchmark || 'none yet; build one per references/metrics.md'}`,
    `Ratchet file: ${ratchetDir}/${t.slug}.json (this thread only)`,
    goal ? `Overall goal: ${goal}` : '',
  ].filter(Boolean).join('\n')
}

function climbPrompt(t, round) {
  const branch = `hill-climb/${t.slug}`
  const where = t.worktree
    ? [
        `Work in the existing worktree at ${t.worktree}. Set your working directory there first.`,
        `If that path no longer exists (an unchanged worktree is reaped), recreate it: \`git worktree add ${t.worktree} ${branch}\` when the branch exists, else \`git worktree add -b ${branch} ${t.worktree}\`.`,
        `Halt with status blocked unless \`git rev-parse --show-toplevel\` equals ${t.worktree} and the branch is ${branch}.`,
        `This round has no isolation, so your shell can start in the main checkout. Run every git command as \`git -C ${t.worktree}\`. Use absolute paths under ${t.worktree} for every file edit and command.`,
      ]
    : [
        `You run in a fresh worktree. Check whether branch ${branch} exists with \`git rev-parse --verify --quiet refs/heads/${branch}\`.`,
        `If it exists, run \`git checkout ${branch}\`. Halt with status blocked if git refuses because another worktree holds the branch.`,
        `If it does not exist, run \`git checkout -b ${branch}\`.`,
        'Report the worktree path from `git rev-parse --show-toplevel`.',
      ]
  const refuted = t.refuted
    ? [
        '',
        `The previous round claimed a gain in commit ${t.refuted.commit || '(unknown)'}, and the verifier refuted it: ${t.refuted.note}`,
        'Revert that commit and its ratchet tighten before you try anything else. Log it as a false lead.',
        'Set reverted to true only after the revert is committed. Otherwise leave reverted false.',
      ]
    : []
  const history = t.history.length
    ? ['', 'Earlier rounds:', ...t.history.map((h) => `- round ${h.round}: ${h.status}${h.change ? ` — ${h.change}` : ''}`)]
    : []
  return [
    `You run round ${round} of a /hill-climb thread inside the hill-climb-threads workflow.`,
    '',
    threadContext(t),
    '',
    ...where,
    ...refuted,
    ...history,
    '',
    `Invoke the hill-climb skill through the Skill tool with args "${t.slug}". Run exactly ONE iteration.`,
    'Commit locally on the thread branch only. Do not push, open a PR, or merge.',
    'Do not edit files outside this thread\'s hot path, its tests, its benchmark, and its ratchet file.',
    'CI wiring for the ratchet is already done by the workflow. It is outside this thread\'s scope. Skip the CI step.',
    `The workflow owns the dry-streak stop (${dryLimit} dry round(s)). Do not write STOP for diminishing returns.`,
    'If you build or change the benchmark, return its command in benchmark.',
    '',
    'Return status improved only when the benchmark beat the ratchet threshold, the gates passed, and you committed the change with the tightened ratchet file.',
    'Return no-gain when you reverted the attempt. Return stopped when the skill wrote STOP; put its reason in stop_reason. Return blocked on any setup failure.',
  ].join('\n')
}

function verifyPrompt(t, climb) {
  return [
    'You are a skeptic. Re-check a claimed hill-climb gain. Default to confirmed=false when the evidence is unclear.',
    'Do not edit, commit, or revert anything.',
    '',
    threadContext(t),
    `Worktree: ${t.worktree}. Set your working directory there first.`,
    `Claimed: ${climb.before} -> ${climb.after} in commit ${climb.commit || '(unknown)'}: ${climb.change}`,
    '',
    'Steps:',
    '1. Read the commit diff. Confirm it does not remove a check, a test, or behavior to win the number.',
    '2. Run the benchmark through `python3 ~/.claude/skills/hill-climb/scripts/ratchet.py measure --runs 5 -- <benchmark>`.',
    `3. Run \`~/.claude/skills/hill-climb/scripts/ratchet.py check --file ${ratchetDir}/${t.slug}.json\` with the measured value.`,
    '4. Run the repository test gate that covers the changed files.',
    '',
    'Set confirmed=true only when the measurement is deterministic, it matches the claim, the gate passes, and tests pass.',
  ].join('\n')
}

function adoptPrompt() {
  return [
    'Wire the hill-climb ratchet gate into CI. Do this once for the whole run.',
    '',
    `Ratchet files: every ${ratchetDir}/*.json file. Threads create them later, so the gate covers the whole directory.`,
    'Read the Adopt section of ~/.claude/skills/hill-climb/SKILL.md and follow it. Do not run the climb iteration steps.',
    '',
    'If CI already runs ratchet.py check over this directory, change nothing and return already-gated.',
    'If the repository has no CI, change nothing and return skipped.',
    'If branch hill-climb-adopt already exists, change nothing and return already-gated with a note that names the unmerged branch.',
    'Commit the change on the new branch hill-climb-adopt in this worktree. Do not push, open a PR, or touch any hill-climb/<slug> branch.',
    'Return the branch name and a one-line note that says what you wired.',
  ].join('\n')
}

function publishPrompt(t) {
  const gains = t.history.filter((h) => h.status === 'improved').map((h) => `- ${h.change} (${h.before} -> ${h.after})`)
  return [
    `Publish hill-climb thread ${t.slug} as one draft pull request.`,
    `Worktree: ${t.worktree}. Branch: hill-climb/${t.slug}. Set your working directory there first.`,
    '',
    'Verified gains:',
    ...gains,
    '',
    'Invoke the plate skill through the Skill tool. Open a DRAFT pull request. Do not merge.',
    'The body must state the metric, the before and after values, the ratchet file, and every flag the thread added.',
  ].join('\n')
}

// ── run ──────────────────────────────────────────────────────────────────

if (!goal && !explicit) {
  log('No goal and no threads given. Pass a goal string or {goal, threads}.')
  return { error: 'missing goal', threads: [] }
}

let threads
if (explicit) {
  threads = cleanThreads(explicit)
} else {
  phase('Survey')
  const survey = await agent(surveyPrompt(), { label: 'survey', phase: 'Survey', agentType: 'explorer', schema: SURVEY_SCHEMA })
  threads = cleanThreads((survey && survey.threads) || []).slice(0, threadCount)
}

if (!threads.length) {
  log('No usable threads. Nothing to climb.')
  return { goal, threads: [] }
}
log(`Climbing ${threads.length} thread(s), up to ${rounds} round(s) each, stop after ${dryLimit} dry round(s).`)

phase('Adopt')
const adopt = await agent(adoptPrompt(), { label: 'adopt', phase: 'Adopt', isolation: 'worktree', schema: ADOPT_SCHEMA })
  .catch((e) => {
    log(`Adopt failed: ${errorText(e)}`)
    return { status: 'failed', note: errorText(e) }
  })
log(`Adopt: ${adopt.status} — ${adopt.note}`)

for (const t of threads) Object.assign(t, { worktree: null, dry: 0, history: [], refuted: null, outcome: 'rounds-exhausted' })

async function climb(t) {
  for (let round = 1; round <= rounds; round++) {
    if (budget.total && budget.remaining() < 50_000) {
      t.outcome = 'budget'
      log(`${t.slug}: budget low, stopping before round ${round}.`)
      return t
    }
    const result = await agent(climbPrompt(t, round), {
      label: `climb:${t.slug}#${round}`,
      phase: 'Climb',
      schema: CLIMB_SCHEMA,
      ...(t.worktree ? {} : { isolation: 'worktree' }),
    }).catch((e) => {
      log(`${t.slug}: climb agent failed in round ${round}: ${errorText(e)}`)
      return null
    })
    if (!result) {
      t.outcome = 'agent-failed'
      return t
    }
    if (!t.worktree) {
      if (!WORKTREE.test(result.worktree_path)) {
        t.outcome = 'blocked: invalid worktree path'
        log(`${t.slug}: climb returned an invalid worktree path ${JSON.stringify(result.worktree_path)}; stopping thread.`)
        return t
      }
      t.worktree = result.worktree_path
    } else if (result.worktree_path !== t.worktree) {
      t.outcome = 'blocked: worktree path changed'
      log(`${t.slug}: climb returned worktree ${JSON.stringify(result.worktree_path)}, expected ${t.worktree}; stopping thread.`)
      return t
    }
    if (result.reverted === true) t.refuted = null
    if (!t.benchmark && typeof result.benchmark === 'string' && result.benchmark.trim()) t.benchmark = result.benchmark.trim()

    let status = result.status
    if (status === 'improved') {
      const verdict = await agent(verifyPrompt(t, result), {
        label: `verify:${t.slug}#${round}`,
        phase: 'Verify',
        schema: VERIFY_SCHEMA,
      }).catch((e) => {
        log(`${t.slug}: verify agent failed in round ${round}: ${errorText(e)}`)
        return null
      })
      if (!verdict || !verdict.confirmed) {
        status = 'refuted'
        t.refuted = { commit: result.commit, note: verdict ? verdict.note : 'verifier failed to return' }
      }
    }
    t.history.push({ round, status, change: result.change, before: result.before, after: result.after, commit: result.commit })
    log(`${t.slug} round ${round}: ${status}${result.change ? ` — ${result.change}` : ''}`)

    if (status === 'stopped' || status === 'blocked') {
      t.outcome = result.stop_reason ? `${status}: ${result.stop_reason}` : status
      return t
    }
    t.dry = status === 'improved' ? 0 : t.dry + 1
    if (t.dry >= dryLimit) {
      t.outcome = 'diminishing-returns'
      return t
    }
  }
  return t
}

await parallel(threads.map((t) => () => climb(t)))

// A refuted gain stays committed on the branch until a later round reports
// reverted=true. Nothing reverts it automatically, so a thread that ends with a
// pending refutation is never published and the result reports pendingRefutation.
const publishable = threads.filter((t) => !t.refuted && t.history.some((h) => h.status === 'improved'))
const skipped = threads.filter((t) => !publishable.includes(t))
if (skipped.length) log(`Not publishable (no verified gain or a pending refutation): ${skipped.map((t) => t.slug).join(', ')}`)

const published = {}
if (publish && publishable.length) {
  phase('Publish')
  const results = await parallel(publishable.map((t) => () =>
    agent(publishPrompt(t), { label: `publish:${t.slug}`, phase: 'Publish', schema: PUBLISH_SCHEMA })
      .then((r) => ({ slug: t.slug, ...(r || { status: 'failed', note: 'publish agent returned nothing' }) }))
      .catch((e) => {
        log(`${t.slug}: publish agent failed: ${errorText(e)}`)
        return { slug: t.slug, status: 'failed', note: errorText(e) }
      })))
  for (const r of results) published[r.slug] = r
}

return {
  goal,
  ratchetDir,
  adopt,
  threads: threads.map((t) => ({
    slug: t.slug,
    metric: t.metric,
    branch: `hill-climb/${t.slug}`,
    worktree: t.worktree,
    outcome: t.outcome,
    gains: t.history.filter((h) => h.status === 'improved').length,
    pendingRefutation: Boolean(t.refuted),
    history: t.history,
    publish: published[t.slug] || null,
  })),
}
