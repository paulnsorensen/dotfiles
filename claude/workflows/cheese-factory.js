export const meta = {
  name: 'cheese-factory',
  description:
    'Spec-driven easy-cheese pipeline on linked wheypoints: resolve a spec and its curd plan, run an opus boss loop per curd in dependency waves, park forks for the user, then press, integrate, age, cure, and re-age before plating clean branches. Never merges.',
  phases: [
    { title: 'Resolve', detail: 'cheap agent resolves the spec and its curd plan, or lists candidates with no further dispatch' },
    { title: 'Graph', detail: 'create or reuse one run record and one forked Wheypoint record per curd, with blocked_by edges' },
    { title: 'Curds', detail: 'per curd, in dependency waves: opus boss turn -> coder (/cook) or reviewer (/age) -> boss turn, until finish, fork, halt, or the turn cap' },
    { title: 'Press', detail: 'after every curd finishes: /press --auto on each finished curd branch' },
    { title: 'Integrate', detail: 'merge pressed curd branches into integration/<spec> in wave order; a conflict excludes that curd' },
    { title: 'Age', detail: 'barrier /age over the integrated diff (age-fanout child workflow when large); medium+ findings route to curds' },
    { title: 'Cure', detail: '/cure --auto --stake medium+ on each flagged curd branch' },
    { title: 'Re-age', detail: 'once, when a cure committed: re-merge, then re-review scoped to the prior findings' },
    { title: 'Plate', detail: 'plate clean curd branches in the spec landing shape; never merge; report per-curd status' },
  ],
}

// Tracked source: claude/workflows/cheese-factory.js in the dotfiles repo.
// Spec: specs/cheese-factory-linked-wheypoints.md (durable corpus). ADRs:
// .hallouminate/wiki/adr/cheese-factory-workflow.md.
//
// The script owns scheduling only: waves, boss turns, parking, and barriers.
// Mold owns the curd plan; /cook, /age, /press, /cure, and /plate own phase
// meaning. Every curd has a Wheypoint record forked from the run record.
// Agents get only its unpinned ref and resolve the current revision first.
// The global factory handback gate (claude/hooks/factory-handback-gate.js)
// checks each handback that names a factory ref and writes it as a revision.
//
// Args: { spec?: string /* slug | path */, answers?: { [curdSlug]: string } }
//   A bare (non-JSON) string arg is the spec.
//   - no spec: Resolve lists candidate specs and the workflow returns them.
//   - a fork parks its curd; the run returns { status: 'gated', forks } after
//     the Curds barrier. Relaunch with resumeFromRunId and args.answers keyed
//     by curd slug. Unchanged agent calls replay from the cache, so only the
//     parked curds' boss turns run again.

const NO_CHAIN_DIRECTIVE = 'You run inside the /cheese-factory workflow, which drives the chain. Do not chain forward to the next phase even when your auto-mode contract documents that. Run in the foreground; do not background yourself or defer work. If you cannot finish inside your context, hand back needs-context with the exact remaining work.'

const input = typeof args === 'string'
  ? (() => {
      try {
        const parsed = JSON.parse(args)
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed
        if (typeof parsed === 'string' && parsed.length) return { spec: parsed.trim() }
      } catch { /* not JSON — fall through */ }
      return { spec: args.trim() }
    })()
  : args || {}
const SPEC_ARG = typeof input.spec === 'string' && input.spec.length ? input.spec : null
const ANSWERS = input.answers && typeof input.answers === 'object' && !Array.isArray(input.answers) ? input.answers : {}
const MAX_BOSS_TURNS = 12

const SLUG_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/
const SPEC_ARG_RE = /^(?:~\/|\/)?[a-zA-Z0-9._][a-zA-Z0-9._/-]*$/ // slug, relative, absolute, or ~/ path ('..' rejected separately)
const STOP_RE = /^(gated|halt)\b/i
if (SPEC_ARG !== null && (!SPEC_ARG_RE.test(SPEC_ARG) || SPEC_ARG.includes('..'))) {
  return { error: `Invalid spec arg: ${SPEC_ARG}` }
}
const branchFor = (slug) => `curd/${slug}`
const absPath = (value) => typeof value === 'string' && /^\/[^\n\r]*$/.test(value.trim())
const WHEYPOINT = 'python3 ~/.claude/skills/wheypoint/scripts/wheypoint.pyz'

// ---- schemas (the harness subset: type, required, properties, items, enum, description, pattern) ----

const STR = { type: 'string' }
const STR_LIST = { type: 'array', items: STR }

const RESOLVE_SCHEMA = {
  type: 'object',
  required: ['mode'],
  properties: {
    mode: { type: 'string', enum: ['candidates', 'resolved', 'missing'] },
    candidates: STR_LIST,
    usage: STR,
    spec_path: STR,
    slug: STR,
    landing_shape: STR,
    curds: {
      type: 'array',
      items: { type: 'object', required: ['slug', 'brief', 'depends_on'], properties: { slug: STR, brief: STR, depends_on: STR_LIST } },
    },
  },
}

const GRAPH_SCHEMA = { type: 'object', required: ['project'], properties: { project: STR } }

const HANDBACK_FIELDS = { wheypoint_ref: STR, orientation: STR, status: STR, next: STR, record_status: STR }

const BOSS_SCHEMA = {
  type: 'object',
  required: ['role', 'action', 'wheypoint_ref'],
  properties: {
    ...HANDBACK_FIELDS,
    role: { type: 'string', enum: ['boss'] },
    action: { type: 'string', enum: ['dispatch_coder', 'dispatch_review', 'raise_fork', 'finish'] },
    brief: STR,
    fork: {
      type: 'object',
      required: ['question', 'options'],
      properties: {
        question: STR,
        options: { type: 'array', items: { type: 'object', required: ['option', 'breaks'], properties: { option: STR, breaks: STR } } },
      },
    },
    resolves: { type: 'array', items: { type: 'object', required: ['entry_id', 'quote'], properties: { entry_id: STR, decision: STR, quote: STR } } },
  },
}

const CODER_SCHEMA = {
  type: 'object',
  required: ['role', 'status', 'next', 'wheypoint_ref', 'orientation', 'worktree_path'],
  properties: { ...HANDBACK_FIELDS, role: { type: 'string', enum: ['coder'] }, worktree_path: STR },
}

const FINDING = { type: 'object', properties: { dimension: STR, severity: STR, file: STR, line: { type: 'integer' }, claim: STR, fix_direction: STR } }

const REVIEWER_SCHEMA = {
  type: 'object',
  required: ['role', 'status', 'next', 'wheypoint_ref', 'orientation'],
  properties: { ...HANDBACK_FIELDS, role: { type: 'string', enum: ['reviewer'] }, findings: { type: 'array', items: FINDING } },
}

const PHASE_SCHEMA = { type: 'object', required: ['status'], properties: { status: STR, artifact: STR, orientation: STR, committed: { type: 'boolean' } } }

const INTEGRATE_SCHEMA = {
  type: 'object',
  required: ['worktree_path', 'merged', 'conflicted', 'files_changed', 'lines_changed'],
  properties: { worktree_path: STR, merged: STR_LIST, conflicted: STR_LIST, files_changed: { type: 'integer' }, lines_changed: { type: 'integer' } },
}

const AGE_BARRIER_SCHEMA = {
  type: 'object',
  required: ['status', 'has_medium_plus_findings'],
  properties: {
    status: STR,
    artifact: STR,
    has_medium_plus_findings: { type: 'boolean' },
    per_curd: { type: 'array', items: { type: 'object', properties: { slug: STR, has_medium_plus_findings: { type: 'boolean' }, findings: { type: 'array', items: FINDING } } } },
  },
}

const PLATE_SCHEMA = {
  type: 'object',
  required: ['results'],
  properties: { results: { type: 'array', items: { type: 'object', required: ['slug', 'status'], properties: { slug: STR, status: STR, pr_url: STR } } } },
}

// ---- pure helpers ----

function planProblem(curds) {
  if (!Array.isArray(curds) || curds.length === 0) return 'the plan has no curds'
  const slugs = new Set()
  for (const c of curds) {
    if (typeof c.slug !== 'string' || !SLUG_RE.test(c.slug)) return `curd slug "${c.slug}" is not a valid id`
    if (slugs.has(c.slug)) return `curd slug "${c.slug}" repeats`
    slugs.add(c.slug)
  }
  for (const c of curds) {
    for (const d of c.depends_on) if (!slugs.has(d)) return `curd "${c.slug}" depends on unknown "${d}"`
  }
  return null
}

// Topological waves, slug-sorted inside each wave; a cycle returns null.
function waves(curds) {
  const remaining = new Map(curds.map((c) => [c.slug, c]))
  const done = new Set()
  const out = []
  while (remaining.size) {
    const wave = [...remaining.values()].filter((c) => c.depends_on.every((d) => done.has(d)))
    if (wave.length === 0) return null
    wave.sort((a, b) => a.slug.localeCompare(b.slug))
    for (const c of wave) { remaining.delete(c.slug); done.add(c.slug) }
    out.push(wave)
  }
  return out
}

// ---- prompts ----

function resolvePrompt() {
  return `You are a cheap resolver agent for the /cheese-factory workflow. Use Bash. Never edit files.

${SPEC_ARG
  ? `A spec was given: "${SPEC_ARG}" (slug or path).
1. Resolve it with \`python3 ~/.claude/skills/mold/scripts/mold.pyz artifact-path specs ${SPEC_ARG}\` and read \`path\`. Accept an absolute or ~/ path as the path itself.
2. When the file does not exist, return {"mode":"missing","usage":"Usage: /cheese-factory <spec slug or path> — spec not found at <path you tried>"}.
3. Read the spec. Take the curds from its validated CurdPlan when it has one, else from its ## Curds section. When it has neither, return one curd whose slug is the spec slug and whose brief is "Implement the whole spec.".
4. Return {"mode":"resolved","spec_path":"<path>","slug":"<spec slug>","landing_shape":"<frontmatter landing.shape, or empty>","curds":[{"slug":"...","brief":"...","depends_on":["<sibling slug>", ...]}]}.`
  : `No spec was given. List candidate spec files in the durable spec corpus ($XDG_DATA_HOME/cheese/<project>/specs/ or ~/.local/share/cheese/<project>/specs/) and in legacy .cheese/specs/. Return {"mode":"candidates","candidates":["<slug-or-path>", ...]}.`}`
}

function graphPrompt(resolved) {
  const run = `factory-${resolved.slug}`
  return `Create or reuse the linked Wheypoint graph for this /cheese-factory run. Work in the current checkout. Never edit source files.
Wheypoint: \`${WHEYPOINT}\`. Read its SKILL.md before the first write.
1. Run record "${run}": when \`show ${run}\` reports no record, run \`checkpoint --work-id ${run} --orientation "Factory run for ${resolved.slug}." --decision "Run started." --rationale "cheese-factory" --next hold --context ${resolved.spec_path} --no-note\`.
2. For each curd, the work id is "${run}--<slug>". When it has no record, run \`fork ${run} ${run}--<slug> --orientation "<brief>"\`. Reuse a record that exists.
3. For each depends_on entry, run \`link ${run}--<slug> wheypoint:<project>/${run}--<dep> --kind blocked_by\` once.
Curds: ${JSON.stringify(resolved.curds)}
Return {"project":"<the project_key that show reports>"}.`
}

function bossPrompt(ctx, curd, worktree, last, answer) {
  return `You are the opus curd boss for curd "${curd.slug}" of a /cheese-factory run. You decide the next move. You never edit files, and you never spawn agents. The workflow script runs each decision you return.
Curd record: ${ctx.refFor(curd.slug)}. Spec: ${ctx.specPath}.
Curd brief: ${curd.brief}
Base: ${ctx.baseFor(curd)}. Branch: ${branchFor(curd.slug)}. Worktree: ${worktree || 'none yet; the first coder creates it'}.
Last worker result: ${last ? JSON.stringify(last) : 'none; this is the first turn'}
${answer ? `The user answered your open fork: "${answer}". Run show, find the gating entry, and list it in resolves with the user's words verbatim as quote.\n` : ''}
1. Run \`${WHEYPOINT} show ${ctx.workId(curd.slug)}\`. Read the working context, open questions, and decisions.
2. Select exactly one action:
   - dispatch_coder when implementation or fix work remains. The brief is one line that states Done means and Scope fence, with edit sites as path#start-end ranges when known.
   - dispatch_review when the last coder handed back next: age.
   - raise_fork when a choice changes an acceptance criterion, a public seam, or a non-goal, and the spec does not settle it. Give a one-line question and two to four options; each option names what it breaks.
   - finish when the last reviewer handed back next: done.
3. Never decide a consequential fork yourself. Raise it.
Hand back {"role":"boss","action":"...","wheypoint_ref":"<the pinned ref that show printed>","brief":"...","fork":{...},"resolves":[...]}. The factory handback gate checks it and writes it as one Wheypoint revision. When the gate denies the call, fix the named field and call again. On stale-parent, run show again and decide from the current revision.`
}

function coderPrompt(ctx, curd, worktree, brief) {
  const branch = branchFor(curd.slug)
  const deps = curd.depends_on.map(branchFor)
  const start = worktree
    ? `cd ${worktree} first. It holds ${branch}. Do not reset it or check out another branch.`
    : `You run in a fresh isolated worktree. First run \`git checkout -B ${branch} ${ctx.baseFor(curd)}\`${deps.length > 1 ? `, then \`git merge --no-ff\` each of ${JSON.stringify(deps.slice(1))}` : ''}.`
  return `You are a coder for curd "${curd.slug}" of a /cheese-factory run. Curd record: ${ctx.refFor(curd.slug)}.
${start}
Run \`${WHEYPOINT} show ${ctx.workId(curd.slug)}\` and read its working context first.
Brief: ${brief}
Run \`/cook --auto\` via the Skill tool with the brief as the task and ${ctx.specPath} as the governing spec. Do only the brief. Commit locally on ${branch}. Do not push, open a PR, or merge.
${NO_CHAIN_DIRECTIVE}
Hand back {"role":"coder","status":"ok | needs-context: <gap> | gated: <question> | halt: <reason>","next":"age | hold","wheypoint_ref":"<the pinned ref that show printed>","orientation":"<one line; for needs-context, the exact remaining work>","worktree_path":"<git rev-parse --show-toplevel>"}. The factory handback gate writes it as one Wheypoint revision. Never write a Wheypoint checkpoint yourself.`
}

function reviewerPrompt(ctx, curd, worktree) {
  const deps = curd.depends_on.map(branchFor)
  return `Review mode: severity-report
You review curd "${curd.slug}" of a /cheese-factory run. You are source-read-only. Curd record: ${ctx.refFor(curd.slug)}.
cd ${worktree} first. Run \`${WHEYPOINT} show ${ctx.workId(curd.slug)}\`.
Run \`/age origin/main...${branchFor(curd.slug)} --auto\` via the Skill tool.${deps.length ? ` The dependency branches ${JSON.stringify(deps)} were reviewed already; report only findings in this curd's own commits.` : ''} Do not invoke /cure.
${NO_CHAIN_DIRECTIVE}
Hand back {"role":"reviewer","status":"ok | gated: <question> | halt: <reason>","next":"done | cure | mold","wheypoint_ref":"<the pinned ref that show printed>","orientation":"<one line>","findings":[medium+ findings only]}. Use next: done when no medium+ finding remains, cure when one does, and mold when the diff shows the spec itself is wrong. The factory handback gate writes it as one Wheypoint revision.`
}

function pressPrompt(curd, worktree) {
  return `You are the Press phase for curd "${curd.slug}" of a /cheese-factory run. cd ${worktree} first; it holds ${branchFor(curd.slug)}.
Run \`/press --auto\` via the Skill tool. Commit locally on ${branchFor(curd.slug)}. Do not push.
${NO_CHAIN_DIRECTIVE}
Return {"status":"ok | ok-with-concerns: <reason> | gated: <question> | halt: <reason>","artifact":"...","orientation":"..."}.`
}

function mergePrompt(parentSlug, branches, worktree) {
  return `You are the Integrate barrier of a /cheese-factory run. ${worktree ? `cd ${worktree} first.` : 'You run in an isolated worktree; branches are shared with the repo.'}
1. \`git checkout -B integration/${parentSlug} origin/main\`.
2. Merge each branch in order with \`git merge --no-ff <branch>\`. On a conflict, run \`git merge --abort\`, record its slug as conflicted, and continue.
Branches (dependencies first): ${JSON.stringify(branches)}
3. Parse \`git diff --shortstat origin/main...HEAD\`: files_changed, and lines_changed = insertions + deletions.
Do not push. Do not edit files. ${NO_CHAIN_DIRECTIVE}
Return {"worktree_path":"<git rev-parse --show-toplevel>","merged":["<slug>", ...],"conflicted":["<slug>", ...],"files_changed":<n>,"lines_changed":<n>}.`
}

function ageBarrierPrompt(worktree, refs, priorFindings) {
  return `Review mode: severity-report
You run the ${priorFindings ? 'Re-age' : 'Age'} barrier of a /cheese-factory run. You are source-read-only. cd ${worktree} first; it holds the integration branch.
${priorFindings
    ? `A cure pass ran and the branch was re-merged. Re-review \`git diff origin/main...HEAD\` scoped to these prior findings, and judge each resolved or still present:\n${JSON.stringify(priorFindings)}`
    : 'Run `/age origin/main...HEAD --auto` via the Skill tool over the whole integrated diff.'}
Curd branches: ${JSON.stringify(refs)}. Route each medium+ finding to the curd whose own commits introduced the line (\`git log <branch> --not <its dependency branches> -L\` or \`--name-only\` when unsure).
Do not invoke /cure. ${NO_CHAIN_DIRECTIVE}
Return {"status":"ok","artifact":"<age report path>","has_medium_plus_findings":true|false,"per_curd":[{"slug":"...","has_medium_plus_findings":true|false,"findings":[{"dimension":"...","severity":"blocker|high|medium","file":"...","line":<n>,"claim":"...","fix_direction":"..."}]}]}, one per_curd entry per curd branch.`
}

function curePrompt(curd, worktree, findings) {
  return `You are the Cure phase for curd "${curd.slug}" of a /cheese-factory run. cd ${worktree} first; it holds ${branchFor(curd.slug)} with its cook and press commits.
Run \`/cure --auto --stake medium+\` via the Skill tool with this finding list as its input:
${JSON.stringify(findings)}
Commit locally on ${branchFor(curd.slug)}. Do not push. ${NO_CHAIN_DIRECTIVE}
Return {"status":"ok | gated: <question> | halt: <reason>","committed":true|false,"artifact":"..."}.`
}

function platePrompt(entries, shape) {
  return `You are the Plate barrier of a /cheese-factory run.
Clean curd branches, each with its base: ${JSON.stringify(entries)}
Run /plate in landing shape "${shape}". A curd whose base is another curd branch stacks on that branch. Push and open or update PRs. Never merge.
Return {"results":[{"slug":"...","status":"...","pr_url":"..."}]}.`
}

// ---- curd boss loop ----

// answers[slug] is one answer string or a list; the k-th answer settles the
// curd's k-th fork.
const answersFor = (slug) => [].concat(ANSWERS[slug] ?? []).filter((a) => typeof a === 'string' && a.trim())

// One curd's boss loop. A fork parks the curd and returns its loop state.
// With useAnswers, a later call continues a parked loop from that state when
// the user answered the fork.
async function runCurd(ctx, curd, useAnswers, state = { turn: 0, worktree: null, last: null, forks: 0, pending: null }) {
  let { turn, worktree, last, forks, pending } = state
  const answers = useAnswers ? answersFor(curd.slug) : []
  const done = (st, extra = {}) => ({ slug: curd.slug, state: st, worktree, ...extra })
  // Settle the pending fork from the user's answer, or park on it.
  const settle = () => {
    if (forks >= answers.length) return done('parked', { fork: pending.fork, loop: { turn, worktree, last, forks, pending } })
    last = { ...pending, answer: answers[forks] }
    forks += 1
    pending = null
    return null
  }
  if (pending) {
    const parked = settle()
    if (parked) return parked
  }
  while (turn < MAX_BOSS_TURNS) {
    turn += 1
    const decision = await agent(bossPrompt(ctx, curd, worktree, last, last && last.answer), {
      label: `boss:${curd.slug}:t${turn}`, phase: 'Curds', agentType: 'generalist', model: 'opus', schema: BOSS_SCHEMA,
    })
    ctx.noteGate(decision)
    if (decision.action === 'finish') return done('finished')
    if (decision.action === 'raise_fork') {
      pending = { action: 'raise_fork', fork: decision.fork || null }
      const parked = settle()
      if (parked) return parked
      continue
    }
    const review = decision.action === 'dispatch_review'
    if (review && !worktree) return done('failed', { reason: 'boss asked for review before any coder ran' })
    if (!review && !(typeof decision.brief === 'string' && decision.brief.trim())) return done('failed', { reason: 'boss dispatched a coder without a brief' })

    const result = review
      ? await agent(reviewerPrompt(ctx, curd, worktree), { label: `review:${curd.slug}:t${turn}`, phase: 'Curds', agentType: 'reviewer', model: 'opus', schema: REVIEWER_SCHEMA })
      : await agent(coderPrompt(ctx, curd, worktree, decision.brief), {
          label: `code:${curd.slug}:t${turn}`, phase: 'Curds', agentType: 'coder', model: 'sonnet', schema: CODER_SCHEMA,
          ...(worktree ? {} : { isolation: 'worktree' }),
        })
    ctx.noteGate(result)
    if (!review && !worktree) {
      if (!absPath(result.worktree_path)) return done('failed', { reason: 'first coder did not report an absolute worktree_path' })
      worktree = result.worktree_path.trim()
    }
    if (/^halt\b/i.test(result.status)) return done('halted', { reason: result.status })
    last = { action: decision.action, status: result.status, next: result.next, orientation: result.orientation, findings: result.findings || [] }
    if (/^gated\b/i.test(result.status)) {
      pending = { ...last, fork: { question: result.status.replace(/^gated:\s*/i, ''), options: [] } }
      const parked = settle()
      if (parked) return parked
    }
  }
  return done('stalled', { reason: `no finish after ${MAX_BOSS_TURNS} boss turns` })
}

// ---- Resolve ----
phase('Resolve')
const resolved = await agent(resolvePrompt(), { label: 'resolve', phase: 'Resolve', model: 'haiku', schema: RESOLVE_SCHEMA })
if (resolved.mode === 'missing') return { error: resolved.usage || `Spec not found: ${SPEC_ARG}` }
if (resolved.mode === 'candidates') {
  const candidates = resolved.candidates || []
  log(`No spec given — ${candidates.length} candidate(s) found.`)
  return { candidates }
}
if (!SLUG_RE.test(resolved.slug || '')) return { error: `Invalid spec slug: ${resolved.slug}` }
const problem = planProblem(resolved.curds)
if (problem) return { error: `invalid curd plan: ${problem}` }
const plannedWaves = waves(resolved.curds)
if (!plannedWaves) return { error: 'invalid curd plan: depends_on forms a cycle' }
const curdBySlug = new Map(resolved.curds.map((c) => [c.slug, c]))
const ordered = plannedWaves.flat()

// ---- Graph ----
phase('Graph')
const graph = await agent(graphPrompt(resolved), { label: 'graph', phase: 'Graph', agentType: 'generalist', model: 'sonnet', schema: GRAPH_SCHEMA })
if (!SLUG_RE.test(graph.project || '')) return { error: `graph agent returned an invalid project key: ${graph.project}` }

let gateSilent = false
const ctx = {
  specPath: resolved.spec_path,
  workId: (slug) => `factory-${resolved.slug}--${slug}`,
  refFor: (slug) => `wheypoint:${graph.project}/factory-${resolved.slug}--${slug}`,
  baseFor: (curd) => (curd.depends_on.length ? branchFor(curd.depends_on[0]) : 'origin/main'),
  // The gate adds record_status when it writes a revision. Without it the
  // records lag the run; the script still schedules from the handbacks.
  noteGate: (handback) => {
    if (!gateSilent && handback && !handback.record_status) {
      gateSilent = true
      log('factory handback gate did not report a revision; Wheypoint records may lag this run.')
    }
  },
}

// ---- Curds (dependency waves; a curd waits for its dependencies to finish) ----
phase('Curds')
log(`Running ${resolved.curds.length} curd(s) in ${plannedWaves.length} wave(s): ${plannedWaves.map((w) => w.map((c) => c.slug).join(', ')).join(' | ')}`)
const results = new Map()
// One scheduling pass in wave order. It runs each curd that has no result
// yet, was blocked, or (with useAnswers) is parked with a user answer.
async function schedule(useAnswers) {
  for (const wave of plannedWaves) {
    const ready = []
    for (const curd of wave) {
      const prior = results.get(curd.slug)
      const rerun = !prior || prior.state === 'blocked' || (useAnswers && prior.state === 'parked' && answersFor(curd.slug).length > prior.loop.forks)
      if (!rerun) continue
      const blocker = curd.depends_on.find((d) => results.get(d).state !== 'finished')
      if (blocker) results.set(curd.slug, { slug: curd.slug, state: 'blocked', reason: `depends on ${blocker} (${results.get(blocker).state})` })
      else ready.push(curd)
    }
    const out = await parallel(ready.map((curd) => () => {
      const prior = results.get(curd.slug)
      return runCurd(ctx, curd, useAnswers, prior && prior.state === 'parked' ? prior.loop : undefined)
    }))
    ready.forEach((curd, i) => results.set(curd.slug, out[i] || { slug: curd.slug, state: 'failed', reason: 'curd loop threw' }))
  }
}
// Pass 1 never reads answers, so a resumed run replays the original calls
// from the cache. Pass 2 continues answered forks and their dependents.
await schedule(false)
if (Object.keys(ANSWERS).length) await schedule(true)

const parked = ordered.map((c) => results.get(c.slug)).filter((r) => r.state === 'parked')
if (parked.length) {
  log(`${parked.length} curd(s) parked on a fork; returning for user answers.`)
  return {
    status: 'gated',
    forks: parked.map((r) => ({ slug: r.slug, record: ctx.refFor(r.slug), fork: r.fork })),
    curds: ordered.map((c) => { const r = results.get(c.slug); return { slug: r.slug, state: r.state, reason: r.reason } }),
    resume: 'Relaunch with resumeFromRunId and the same args plus answers = { <slug>: "<answer>" }; give a list when a curd parks again, one answer per fork in order.',
  }
}

// ---- Press (barrier: every curd has finished) ----
const exclude = (slug, state, reason) => results.set(slug, { ...results.get(slug), state, reason })
let finished = ordered.filter((c) => results.get(c.slug).state === 'finished')
if (finished.length) {
  phase('Press')
  const pressed = await parallel(finished.map((c) => () =>
    agent(pressPrompt(c, results.get(c.slug).worktree), { label: `press:${c.slug}`, phase: 'Press', agentType: 'coder', model: 'sonnet', schema: PHASE_SCHEMA })))
  finished.forEach((c, i) => {
    const p = pressed[i]
    if (!p) exclude(c.slug, 'failed', 'press: agent error')
    else if (STOP_RE.test(p.status)) exclude(c.slug, 'dirty', `press: ${p.status}`)
  })
}

// A curd whose dependency left the run carries that dependency's commits.
const cascade = () => {
  for (const c of ordered) {
    const r = results.get(c.slug)
    if (!['finished', 'clean'].includes(r.state)) continue
    const bad = c.depends_on.find((d) => !['finished', 'clean'].includes(results.get(d).state))
    if (bad) exclude(c.slug, 'blocked', `depends on ${bad} (${results.get(bad).state})`)
  }
}
cascade()
finished = ordered.filter((c) => results.get(c.slug).state === 'finished')

// ---- Integrate ----
let integrate = null
if (finished.length) {
  phase('Integrate')
  try {
    integrate = await agent(mergePrompt(resolved.slug, finished.map((c) => branchFor(c.slug)), null), { label: 'integrate', phase: 'Integrate', agentType: 'coder', model: 'sonnet', isolation: 'worktree', schema: INTEGRATE_SCHEMA })
  } catch (e) {
    log(`Integrate failed (${e.message}).`)
  }
  if (!integrate) for (const c of finished) exclude(c.slug, 'failed', 'integrate: barrier integration failed')
  else for (const slug of integrate.conflicted || []) if (curdBySlug.has(slug)) exclude(slug, 'failed', 'integrate: merge conflict')
  cascade()
}
let integrated = ordered.filter((c) => results.get(c.slug).state === 'finished')
const refsOf = (list) => list.map((c) => ({ slug: c.slug, branch: branchFor(c.slug), depends_on: c.depends_on.map(branchFor) }))

// ---- Age (barrier: whole integrated diff; fan-out when large) ----
let ageResult = null
if (integrate && integrated.length) {
  phase('Age')
  // Thresholds from /age SKILL.md § scale threshold (>15 files / ~25 KB ≈ 800 lines).
  if (integrate.files_changed > 15 || integrate.lines_changed > 800) {
    try {
      const fan = await workflow('age-fanout', { worktree_path: integrate.worktree_path, range: 'origin/main...HEAD', slug: resolved.slug, route_curds: refsOf(integrated) })
      if (!fan || fan.status !== 'ok') throw new Error((fan && fan.error) || 'age-fanout returned non-ok')
      ageResult = fan
    } catch (e) {
      log(`age-fanout unavailable (${e.message}) — falling back to a single-reviewer barrier age.`)
    }
  }
  if (!ageResult) {
    try {
      ageResult = await agent(ageBarrierPrompt(integrate.worktree_path, refsOf(integrated), null), { label: 'age:barrier', phase: 'Age', agentType: 'reviewer', model: 'opus', schema: AGE_BARRIER_SCHEMA })
    } catch (e) {
      log(`Barrier age failed (${e.message}).`)
    }
  }
  if (!ageResult) for (const c of integrated) exclude(c.slug, 'failed', 'age: barrier age failed')
}

// ---- Cure, then one Re-age ----
const flaggedBySlug = new Map(((ageResult && ageResult.per_curd) || []).filter((p) => p && p.has_medium_plus_findings).map((p) => [p.slug, p.findings || []]))
if (ageResult && ageResult.has_medium_plus_findings && flaggedBySlug.size === 0) {
  log('Barrier age reported medium+ findings without per-curd routing — integrated curds marked dirty.')
  for (const c of integrated) exclude(c.slug, 'dirty', 'age reported medium+ findings without per-curd routing')
}
const toCure = integrated.filter((c) => flaggedBySlug.has(c.slug) && results.get(c.slug).state === 'finished')
if (toCure.length) {
  phase('Cure')
  const cures = await parallel(toCure.map((c) => () =>
    agent(curePrompt(c, results.get(c.slug).worktree, flaggedBySlug.get(c.slug)), { label: `cure:${c.slug}`, phase: 'Cure', agentType: 'coder', model: 'sonnet', schema: PHASE_SCHEMA })))
  const cured = []
  toCure.forEach((c, i) => {
    const cure = cures[i]
    if (!cure || !cure.committed || STOP_RE.test(cure.status)) exclude(c.slug, 'dirty', `cure: ${cure ? (cure.committed ? cure.status : 'no fix committed') : 'agent error'}`)
    else cured.push(c)
  })
  cascade()
  if (cured.length) {
    phase('Re-age')
    integrated = ordered.filter((c) => results.get(c.slug).state === 'finished')
    let reage = null
    const remerge = await agent(mergePrompt(resolved.slug, integrated.map((c) => branchFor(c.slug)), integrate.worktree_path), { label: 're-merge', phase: 'Re-age', agentType: 'coder', model: 'sonnet', schema: INTEGRATE_SCHEMA })
      .catch((e) => { log(`Re-merge failed (${e.message}).`); return null })
    for (const slug of (remerge && remerge.conflicted) || []) if (curdBySlug.has(slug)) exclude(slug, 'dirty', 're-merge conflicted after cure')
    if (remerge) {
      reage = await agent(ageBarrierPrompt(integrate.worktree_path, refsOf(integrated), cured.flatMap((c) => flaggedBySlug.get(c.slug))), { label: 'age:reage', phase: 'Re-age', agentType: 'reviewer', model: 'opus', schema: AGE_BARRIER_SCHEMA })
        .catch((e) => { log(`Re-age failed (${e.message}).`); return null })
    }
    const stillFlagged = new Set(((reage && reage.per_curd) || []).filter((p) => p && p.has_medium_plus_findings).map((p) => p.slug))
    for (const c of cured) {
      if (results.get(c.slug).state !== 'finished') continue
      if (!reage) exclude(c.slug, 'dirty', 're-age did not run after cure')
      else if (stillFlagged.has(c.slug)) exclude(c.slug, 'dirty', 're-age still reports medium+ findings')
    }
    cascade()
  }
}

// ---- Plate and report ----
for (const c of ordered) if (results.get(c.slug).state === 'finished') exclude(c.slug, 'clean', undefined)
const clean = ordered.filter((c) => results.get(c.slug).state === 'clean')
phase('Plate')
let plateBySlug = new Map()
if (clean.length) {
  const shape = resolved.landing_shape || (clean.length === 1 ? 'single' : 'stacked_linear')
  const entries = clean.map((c) => ({ slug: c.slug, branch: branchFor(c.slug), base: ctx.baseFor(c) }))
  const plated = await agent(platePrompt(entries, shape), { label: 'plate', phase: 'Plate', agentType: 'coder', model: 'opus', schema: PLATE_SCHEMA })
  plateBySlug = new Map(plated.results.map((r) => [r.slug, r]))
} else {
  log('No clean curds — skipping plate.')
}

const curdsOut = ordered.map((c) => {
  const r = results.get(c.slug)
  const plate = plateBySlug.get(c.slug)
  return { slug: c.slug, branch: branchFor(c.slug), record: ctx.refFor(c.slug), status: r.state, pr_url: plate ? plate.pr_url : undefined, reason: r.reason }
})
const summary = {}
for (const c of curdsOut) summary[c.status] = (summary[c.status] || 0) + 1
log(`Report: ${curdsOut.length} curd(s) — ${Object.entries(summary).map(([k, v]) => `${k}:${v}`).join(' ')}`)

return {
  status: 'done',
  curds: curdsOut,
  summary,
  integration: integrate ? { merged: integrate.merged, conflicted: integrate.conflicted } : null,
}
