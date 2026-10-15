export const meta = {
  name: 'hill-climb-threads',
  description: 'Run several narrow /hill-climb threads in parallel worktrees: each thread iterates measure -> change -> verify -> ratchet until diminishing returns, then optionally opens one draft PR per thread',
  whenToUse: 'A performance or efficiency goal with several independent journeys or metrics to drive down at once. Use /hill-climb under /loop for one thread.',
  phases: [
    { title: 'Survey', detail: 'one read-only agent splits the goal into narrow threads, each with one journey and one deterministic metric' },
    { title: 'Adopt', detail: 'once, one coder wires the ratchet check into CI for every ratchet file when CI does not already run it' },
    { title: 'Climb', detail: 'per thread, one /hill-climb iteration per round; each round is a coder in a fresh worktree that starts at the head of the round before' },
    { title: 'Verify', detail: 'a skeptic re-measures every claimed gain at its exact head and runs the ratchet gate; a refuted gain is reverted next round' },
    { title: 'Publish', detail: 'only when publish=true: one agent opens one draft PR per thread with a verified gain, via /plate' },
  ],
}

// Source: 'How we made claude.ai 3x faster' (Anthropic, 2026-09-23). The
// article ran 150+ narrow threads at once, one benchmark each, and ratcheted
// every verified gain into CI. This workflow is that horizontal shape; the
// per-iteration method lives in skills/hill-climb/SKILL.md, which each Climb
// coder reads with tilth_read (the coder type has no Skill tool).
// Wiki: architecture/hill-climb-ratchet.
//
// Args: { goal: string, threads?: number | ThreadSpec[], rounds?: number,
//         dryLimit?: number, ratchetDir?: string, publish?: boolean,
//         adopt?: false | AdoptResult }
//   A bare string arg is the goal. A string that starts with '{' is JSON args.
//   ThreadSpec = {slug, journey, metric, direction?, benchmark?, head?,
//   verified?, gains?}; an explicit list skips Survey. Pass result.resume back
//   as args to skip Survey and Adopt. With rounds:0 and publish:true, a rerun
//   publishes the verified carried threads and starts no climb.
//
// Each thread climbs in its own loop, so no barrier holds a fast thread
// behind a slow one. Each thread writes its own ratchet file
// (<ratchetDir>/<slug>.json), so thread branches do not conflict on one JSON
// file. Every round is isolated, because the worktree guard denies writes
// outside the own worktree of an agent. A round never checks out the thread
// branch, because git refuses a second checkout of one branch. It detaches at
// the head the workflow recorded and moves the branch with git update-ref.
// Adopt runs once before Climb, in its own worktree and branch, so CI wiring
// never touches a thread branch. Verify keeps the default agent type: the
// judge verify mode runs one check only (deferred to agents/registry.yaml).

const SLUG = /^[a-z0-9][a-z0-9-]{0,40}$/
const SAFE_PATH = /^[A-Za-z0-9._/-]+$/
const WORKTREE = /^\/[A-Za-z0-9._/-]+$/
const SHA = /^[0-9a-f]{40}$/
const COMMIT = /^[0-9a-f]{7,40}$/
const MAX_THREADS = 8
const MAX_ROUNDS = 12
const CARRIED_ADOPT = new Set(['wired', 'already-gated', 'skipped'])
const USAGE = 'Pass a goal string, or {goal, threads?: number | [{slug, journey, metric, direction?, benchmark?}], rounds?, dryLimit?, ratchetDir?, publish?, adopt?}. To publish an earlier run without another climb, pass {...result.resume, rounds:0, publish:true}.'

const THREAD_SCHEMA = {
  type: 'object',
  required: ['slug', 'journey', 'metric', 'direction', 'benchmark'],
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
  required: ['status', 'worktree_path', 'head', 'change', 'commit', 'stop_reason', 'reverted_commits', 'existing_commits', 'benchmark'],
  properties: {
    status: { type: 'string', enum: ['improved', 'no-gain', 'stopped', 'blocked'] },
    worktree_path: { type: 'string', description: 'output of git rev-parse --show-toplevel' },
    head: { type: 'string', description: 'output of git rev-parse HEAD after your last commit (40 hex)' },
    before: { type: 'number' },
    after: { type: 'number' },
    change: { type: 'string' },
    commit: { type: 'string', description: 'the commit of an improved gain, else empty' },
    stop_reason: { type: 'string', description: 'the reason for stopped or blocked, else empty' },
    reverted_commits: { type: 'array', items: { type: 'string' }, description: 'commits from the prompt that you reverted, with the revert committed' },
    existing_commits: { type: 'array', items: { type: 'string' }, description: 'commits already on the thread branch, when the prompt asks for them; else empty' },
    benchmark: { type: 'string', description: 'the benchmark command when you built or changed it, else empty' },
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
  required: ['status', 'branch', 'note'],
  properties: {
    status: { type: 'string', enum: ['wired', 'already-gated', 'skipped', 'failed'] },
    branch: { type: 'string', description: 'the branch with the CI change, else empty' },
    note: { type: 'string' },
  },
}

const PUBLISH_SCHEMA = {
  type: 'object',
  required: ['results'],
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        required: ['slug', 'status', 'pr_url', 'note'],
        properties: {
          slug: { type: 'string' },
          status: { type: 'string', enum: ['opened', 'updated', 'skipped', 'failed'] },
          pr_url: { type: 'string', description: 'empty when no PR exists' },
          note: { type: 'string' },
        },
      },
    },
  },
}

// ── args ─────────────────────────────────────────────────────────────────────

function coerceArgs(a) {
  if (typeof a === 'string') {
    if (a.trim().startsWith('{')) {
      try {
        return coerceArgs(JSON.parse(a))
      } catch {
        return { goal: a }
      }
    }
    return { goal: a }
  }
  return a && typeof a === 'object' && !Array.isArray(a) ? a : {}
}

function errorText(e) {
  return e && e.message ? e.message : String(e)
}

function clampInt(value, fallback, max) {
  return Number.isInteger(value) && value > 0 ? Math.min(value, max) : fallback
}

const isCommit = (c) => typeof c === 'string' && COMMIT.test(c)

function cleanGains(list) {
  return (Array.isArray(list) ? list : [])
    .filter((g) => g && typeof g === 'object')
    .map((g) => ({ change: String(g.change || ''), before: g.before, after: g.after }))
}

// A carried head that the earlier run did not verify can hold unverified
// commits, so pendingCarry blocks publish until round 1 verifies the branch.
function cleanThreads(list, cap) {
  const seen = new Set()
  const kept = []
  for (const t of list) {
    if (!t || typeof t.slug !== 'string' || !SLUG.test(t.slug) || seen.has(t.slug)) {
      log(`Dropped thread with unsafe or duplicate slug: ${JSON.stringify(t && t.slug)}`)
      continue
    }
    seen.add(t.slug)
    const head = typeof t.head === 'string' && SHA.test(t.head) ? t.head : null
    kept.push({
      slug: t.slug,
      journey: String(t.journey || ''),
      metric: String(t.metric || ''),
      direction: t.direction === 'higher' ? 'higher' : 'lower',
      benchmark: String(t.benchmark || ''),
      head,
      gains: head ? cleanGains(t.gains) : [],
      pendingCarry: Boolean(head) && t.verified !== true,
    })
  }
  if (kept.length > cap) {
    log(`Keeping the first ${cap} of ${kept.length} threads; dropped: ${kept.slice(cap).map((t) => t.slug).join(', ')}`)
  }
  return kept.slice(0, cap)
}

function cleanAdopt(a) {
  if (a === false) return { status: 'skipped', branch: '', note: 'adopt:false skipped Adopt' }
  if (a && typeof a === 'object' && CARRIED_ADOPT.has(a.status)) {
    return { status: a.status, branch: String(a.branch || ''), note: String(a.note || '') }
  }
  return null
}

const opts = coerceArgs(args)
const goal = typeof opts.goal === 'string' ? opts.goal.trim() : ''
const explicit = Array.isArray(opts.threads) ? opts.threads : null
const threadCount = clampInt(opts.threads, 3, MAX_THREADS)
const rounds = opts.rounds === 0 ? 0 : clampInt(opts.rounds, 4, MAX_ROUNDS)
const dryLimit = clampInt(opts.dryLimit, 3, MAX_ROUNDS)
const ratchetDir = typeof opts.ratchetDir === 'string' && SAFE_PATH.test(opts.ratchetDir) && !opts.ratchetDir.startsWith('/') && !opts.ratchetDir.includes('..')
  ? opts.ratchetDir.replace(/\/+$/, '')
  : 'perf/ratchet'
const publish = opts.publish === true
const carriedAdopt = cleanAdopt(opts.adopt)

// ── prompts ──────────────────────────────────────────────────────────────────────

const code = (s) => '`' + s + '`'

function surveyPrompt() {
  return [
    'Split a performance goal into narrow hill-climb threads. This is a read-only pass. Do not edit files.',
    '',
    `Goal: ${goal}`,
    `Return at most ${threadCount} threads.`,
    '',
    'Read ~/.claude/skills/hill-climb/SKILL.md and ~/.claude/skills/hill-climb/references/metrics.md with tilth_read first.',
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

// Round 1 lists the commits already on the branch, unless an earlier run
// verified the carried head.
const listsExisting = (t, round) => round === 1 && !(t.head && !t.pendingCarry)

function climbPrompt(t, round) {
  const branch = `hill-climb/${t.slug}`
  const start = t.head
    ? [
        `Run ${code(`git checkout --detach ${t.head}`)}.`,
        `Halt with status blocked unless ${code(`git rev-parse refs/heads/${branch}`)} prints ${t.head}.`,
      ]
    : [
        `Run ${code(`git branch ${branch}`)} when ${code(`git rev-parse --verify --quiet refs/heads/${branch}`)} prints nothing.`,
        `Run ${code(`git checkout --detach ${branch}`)}.`,
      ]
  const where = [
    'You run in a fresh worktree. Run every command and edit every file inside it.',
    ...start,
    `Never check out ${branch}. Git refuses a second checkout of one branch, and other rounds share it.`,
    `After each commit, run ${code(`git update-ref refs/heads/${branch} HEAD`)} so the next round starts from it.`,
    listsExisting(t, round)
      ? `List the commits already on the branch with ${code(`git log --format=%H <default-branch>..${branch}`)}. Return them in existing_commits, or an empty list when there are none.`
      : 'Return an empty existing_commits list.',
  ]
  const refuted = t.refuted.length
    ? [
        '',
        'These commits on the branch are not verified. Do not build on them:',
        ...t.refuted.map((r) => `- commit ${r.commit || '(unknown)'}: ${r.note}`),
        'Revert each commit and its ratchet tighten before you try anything else. Log each as a false lead.',
        'List a commit in reverted_commits only after its revert is committed.',
      ]
    : []
  const history = t.history.length
    ? ['', 'Ledger of earlier rounds in this run:', ...t.history.map((h) => `- round ${h.round}: ${h.status}${h.change ? ` — ${h.change}` : ''}`)]
    : []
  return [
    `You run round ${round} of a /hill-climb thread inside the hill-climb-threads workflow.`,
    '',
    threadContext(t),
    'The worktree is fresh. Treat the thread fields above as thread.md and the round list below as the ledger.',
    '',
    ...where,
    ...refuted,
    ...history,
    '',
    `Read ~/.claude/skills/hill-climb/SKILL.md with tilth_read. Follow its iteration steps for thread ${t.slug}. Run exactly ONE iteration.`,
    'Commit locally only. Do not push, open a PR, or merge.',
    ...(adopt.status === 'wired' || adopt.status === 'already-gated'
      ? ['CI wiring for the ratchet is already done by the workflow. It is outside the scope of this thread. Skip the CI step.']
      : [`CI wiring for the ratchet is not done (Adopt ${adopt.status}). It is outside the scope of this thread. Skip the CI step.`]),
    `The workflow owns the dry-streak stop (${dryLimit} dry round(s)). Do not write STOP for diminishing returns.`,
    'If you build or change the benchmark, return its command in benchmark.',
    '',
    'Scope fence: edit only the hot path of this thread, its tests, its benchmark, and its ratchet file. Do not touch CI or any other branch.',
    `Done means: one iteration ran, refs/heads/${branch} points at your last commit, and you returned head from ${code('git rev-parse HEAD')} and worktree_path from ${code('git rev-parse --show-toplevel')}.`,
    '',
    'Return status improved only when the benchmark beat the ratchet threshold, the gates passed, and you committed the change with the tightened ratchet file. Put that commit hash in commit.',
    'Return no-gain when you reverted the attempt. Return stopped when the skill wrote STOP; put its reason in stop_reason. Return blocked on any setup failure.',
  ].join('\n')
}

function verifyPrompt(t, claim) {
  return [
    'You are a skeptic. Re-check a claimed hill-climb gain. Default to confirmed=false when the evidence is unclear.',
    'Do not edit, commit, or revert anything.',
    '',
    threadContext(t),
    `Worktree: ${t.worktree}. Set your working directory there first.`,
    `Confirm ${code(`git -C ${t.worktree} rev-parse HEAD`)} prints ${t.head}. Set confirmed=false when it does not.`,
    `Claimed: ${claim.before} -> ${claim.after} in commit(s) ${claim.commit}: ${claim.change}`,
    '',
    'Steps:',
    '1. Read the commit diff. Confirm it does not remove a check, a test, or behavior to win the number.',
    '2. Run the benchmark through `python3 ~/.claude/skills/hill-climb/scripts/ratchet.py measure --runs 5 -- <benchmark>`.',
    `3. Run ${code(`python3 ~/.claude/skills/hill-climb/scripts/ratchet.py check --file ${ratchetDir}/${t.slug}.json`)} with the measured value.`,
    '4. Run the repository test gate that covers the changed files.',
    '',
    'Set confirmed=true only when the head matches, the measurement is deterministic, it matches the claim, the gate passes, and tests pass.',
  ].join('\n')
}

function adoptPrompt() {
  return [
    'Wire the hill-climb ratchet gate into CI. Do this once for the whole run.',
    '',
    `Ratchet files: every ${ratchetDir}/*.json file. Threads create them later, so the gate covers the whole directory.`,
    'Read the Adopt section of ~/.claude/skills/hill-climb/SKILL.md with tilth_read and follow it. Do not run the climb iteration steps.',
    '',
    'If CI already runs ratchet.py check over this directory, change nothing and return already-gated.',
    'If the repository has no CI, change nothing and return skipped.',
    'If branch hill-climb-adopt already exists, change nothing and return already-gated with a note that names the unmerged branch.',
    'Scope fence: edit only CI configuration and the files the Adopt section names. Do not push, open a PR, or touch any hill-climb/<slug> branch.',
    'Done means: the change is committed on the new branch hill-climb-adopt in this worktree, or nothing changed and the status says why.',
    'Return the branch name (empty when none) and a one-line note that says what you wired.',
  ].join('\n')
}

function publishPrompt(list) {
  const blocks = list.flatMap((t) => [
    `Thread ${t.slug}: branch hill-climb/${t.slug}, head ${t.head}, metric ${t.metric} (better = ${t.direction}), ratchet file ${ratchetDir}/${t.slug}.json.`,
    'Verified gains:',
    ...t.gains.map((g) => `- ${g.change} (${g.before} -> ${g.after})`),
    '',
  ])
  return [
    `Publish ${list.length} thread(s) of a hill-climb run, one DRAFT pull request each.`,
    'You run in a fresh worktree. Every thread branch already exists in the shared repository.',
    '',
    ...blocks,
    'For each thread:',
    '1. Confirm `git rev-parse refs/heads/<branch>` prints the head above. Report failed for the thread when it does not.',
    '2. Run `git checkout <branch>` in this worktree. Report failed for the thread when git refuses.',
    '3. Invoke the plate skill through the Skill tool. Open a DRAFT pull request. Do not merge.',
    'The body of each PR states the metric, the before and after values, the ratchet file, and every flag the thread added.',
    'Done means: results holds one entry per thread above, with its slug, status, pr_url (empty when none), and a note.',
  ].join('\n')
}

// ── run ───────────────────────────────────────────────────────────────────────

if (!goal && !explicit) {
  log(`No goal and no threads given. ${USAGE}`)
  return { error: 'missing goal', usage: USAGE, threads: [] }
}
if (rounds === 0 && !(explicit && publish)) {
  log(`rounds 0 only publishes carried threads. ${USAGE}`)
  return { error: 'rounds 0 needs explicit threads and publish:true', usage: USAGE, threads: [] }
}

let threads
if (explicit) {
  threads = cleanThreads(explicit, MAX_THREADS)
} else {
  phase('Survey')
  const survey = await agent(surveyPrompt(), { label: 'survey', phase: 'Survey', agentType: 'explorer', schema: SURVEY_SCHEMA })
    .catch((e) => {
      log(`Survey failed: ${errorText(e)}`)
      return null
    })
  threads = cleanThreads((survey && survey.threads) || [], threadCount)
}

if (!threads.length) {
  log('No usable threads. Nothing to climb.')
  return { goal, threads: [] }
}
log(rounds
  ? `Climbing ${threads.length} thread(s), up to ${rounds} round(s) each, stop after ${dryLimit} dry round(s).`
  : `rounds 0: publishing the verified threads of ${threads.length} carried thread(s) without a climb.`)

// Every agent names its model: an unset model inherits the parent model (often opus), and climb and verify fan out across threads and rounds.
const WORKER_MODEL = 'sonnet'
let adopt = carriedAdopt
if (adopt) {
  log(`Adopt: carried ${adopt.status}; no Adopt agent runs.`)
} else if (rounds === 0) {
  adopt = { status: 'skipped', branch: '', note: 'rounds 0 publishes only' }
} else {
  phase('Adopt')
  adopt = (await agent(adoptPrompt(), { label: 'adopt', phase: 'Adopt', agentType: 'coder', model: WORKER_MODEL, isolation: 'worktree', schema: ADOPT_SCHEMA })
    .catch((e) => {
      log(`Adopt failed: ${errorText(e)}`)
      return { status: 'failed', branch: '', note: errorText(e) }
    })) || { status: 'failed', branch: '', note: 'adopt agent returned nothing' }
  log(`Adopt: ${adopt.status} — ${adopt.note}`)
}

for (const t of threads) Object.assign(t, { worktree: null, dry: 0, history: [], refuted: [], outcome: rounds ? 'rounds-exhausted' : 'carried' })

const sameCommit = (a, b) => a && b && (a.startsWith(b) || b.startsWith(a))

async function verify(t, claim, label) {
  return agent(verifyPrompt(t, claim), { label, phase: 'Verify', model: WORKER_MODEL, schema: VERIFY_SCHEMA })
    .catch((e) => {
      log(`${t.slug}: verify agent ${label} failed: ${errorText(e)}`)
      return null
    })
}

async function climb(t) {
  for (let round = 1; round <= rounds; round++) {
    if (budget.total && budget.remaining() < 50_000) {
      t.outcome = 'budget'
      log(`${t.slug}: budget low, stopping before round ${round}.`)
      return t
    }
    const listed = listsExisting(t, round)
    const result = await agent(climbPrompt(t, round), {
      label: `climb:${t.slug}#${round}`,
      phase: 'Climb',
      agentType: 'coder',
      model: WORKER_MODEL,
      isolation: 'worktree',
      schema: CLIMB_SCHEMA,
    }).catch((e) => {
      log(`${t.slug}: climb agent failed in round ${round}: ${errorText(e)}`)
      return null
    })
    if (!result) {
      t.outcome = 'agent-failed'
      return t
    }
    if (result.status === 'blocked') {
      t.history.push({ round, status: 'blocked', change: result.change, before: result.before, after: result.after, commit: '' })
      t.outcome = result.stop_reason ? `blocked: ${result.stop_reason}` : 'blocked'
      log(`${t.slug} round ${round}: blocked${result.stop_reason ? ` — ${result.stop_reason}` : ''}`)
      return t
    }
    if (typeof result.worktree_path !== 'string' || !WORKTREE.test(result.worktree_path)) {
      t.outcome = 'blocked: invalid worktree path'
      log(`${t.slug}: climb returned an invalid worktree path ${JSON.stringify(result.worktree_path)}; stopping thread.`)
      return t
    }
    if (typeof result.head !== 'string' || !SHA.test(result.head)) {
      t.outcome = 'blocked: invalid head'
      log(`${t.slug}: climb returned an invalid head ${JSON.stringify(result.head)}; stopping thread.`)
      return t
    }
    const prevHead = t.head
    t.worktree = result.worktree_path
    t.head = result.head

    const existing = listed && Array.isArray(result.existing_commits) ? result.existing_commits.filter(isCommit) : []
    if (existing.length) {
      const verdict = await verify(t, {
        before: '(base)',
        after: '(branch head)',
        commit: existing.join(' '),
        change: 'commits from an earlier run of this thread',
      }, `verify-existing:${t.slug}`)
      if (verdict && verdict.confirmed) {
        log(`${t.slug}: the verifier confirmed ${existing.length} commit(s) from an earlier run.`)
      } else {
        // Carried gains describe the refuted commits, so they cannot survive a later revert.
        if (t.gains.length) log(`${t.slug}: dropped ${t.gains.length} carried gain(s) because the verifier refuted the commits behind them.`)
        t.gains = []
        for (const commit of existing) {
          if (!t.refuted.some((r) => sameCommit(r.commit, commit))) {
            t.refuted.push({ commit, note: `it predates this run and the verifier refuted it: ${verdict ? verdict.note : 'verifier failed to return'}` })
          }
        }
      }
    }
    if (listed) t.pendingCarry = false
    if (Array.isArray(result.reverted_commits)) {
      const reverted = result.reverted_commits.filter(isCommit)
      t.refuted = t.refuted.filter((r) => !reverted.some((c) => sameCommit(r.commit, c)))
    }
    if (typeof result.benchmark === 'string' && result.benchmark.trim()) t.benchmark = result.benchmark.trim()

    let status = result.status
    let commit = isCommit(result.commit) ? result.commit : ''
    if (status === 'improved' && !commit) {
      if (t.head !== prevHead) {
        commit = t.head
      } else {
        status = 'no-gain'
        log(`${t.slug} round ${round}: a claimed gain names no commit and the head did not move; counted as no-gain.`)
      }
    }
    if (status === 'improved' && t.refuted.length) {
      status = 'refuted'
      t.refuted.push({ commit, note: 'the workflow did not verify it because an earlier unverified commit is still on the branch' })
    } else if (status === 'improved') {
      const verdict = await verify(t, { ...result, commit }, `verify:${t.slug}#${round}`)
      if (verdict && verdict.confirmed) {
        t.gains.push({ change: String(result.change || ''), before: result.before, after: result.after })
      } else {
        status = 'refuted'
        t.refuted.push({ commit, note: `the verifier refuted it: ${verdict ? verdict.note : 'verifier failed to return'}` })
      }
    }
    t.history.push({ round, status, change: result.change, before: result.before, after: result.after, commit })
    log(`${t.slug} round ${round}: ${status}${result.change ? ` — ${result.change}` : ''}`)

    if (status === 'stopped') {
      t.outcome = result.stop_reason ? `stopped: ${result.stop_reason}` : 'stopped'
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

if (rounds) await parallel(threads.map((t) => () => climb(t)))

// A refuted commit, or an unverified commit from an earlier run, stays on the
// branch until a later round lists it in reverted_commits. Nothing reverts it
// automatically. A thread with any pending commit is never published.
const verified = (t) => Boolean(t.head) && !t.refuted.length && !t.pendingCarry && t.gains.length > 0
const publishable = threads.filter(verified)
const skipped = threads.filter((t) => !publishable.includes(t))
if (skipped.length) log(`Not publishable (no verified gain or a pending refutation): ${skipped.map((t) => t.slug).join(', ')}`)

const published = {}
if (publish && publishable.length) {
  phase('Publish')
  const reply = await agent(publishPrompt(publishable), { label: 'publish', phase: 'Publish', model: WORKER_MODEL, isolation: 'worktree', schema: PUBLISH_SCHEMA })
    .catch((e) => {
      log(`Publish agent failed: ${errorText(e)}`)
      return { error: errorText(e) }
    })
  const results = reply && Array.isArray(reply.results) ? reply.results : []
  for (const t of publishable) {
    const r = results.find((x) => x && x.slug === t.slug)
    const missing = !reply ? 'publish agent returned nothing' : reply.error || 'publish agent did not report this thread'
    published[t.slug] = r
      ? { status: r.status, pr_url: String(r.pr_url || ''), note: String(r.note || '') }
      : { status: 'failed', pr_url: '', note: missing }
  }
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
    head: t.head,
    outcome: t.outcome,
    gains: t.gains.length,
    pendingRefutation: t.refuted.length > 0 || t.pendingCarry,
    history: t.history,
    publish: published[t.slug] || null,
  })),
  // Pass resume back as args to skip Survey and Adopt; add rounds:0 and publish:true to publish without a climb.
  resume: {
    goal,
    ratchetDir,
    adopt,
    threads: threads.map((t) => ({
      slug: t.slug,
      journey: t.journey,
      metric: t.metric,
      direction: t.direction,
      benchmark: t.benchmark,
      head: t.head,
      verified: verified(t),
      gains: t.gains,
    })),
  },
}
