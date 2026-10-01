export const meta = {
  name: 'cheese-factory-next',
  description:
    'Prototype: cheese-factory on linked wheypoints. Opus curd bosses direct factory coders, agent-scoped hooks gate every handback, and forks park their curd until the user answers (ADR-011..014).',
  whenToUse: 'Prototype only. The live pipeline stays cheese-factory until the open forks in the spec are settled.',
  phases: [
    { title: 'Resolve', detail: 'resolve the spec and its typed curd plan' },
    { title: 'Graph', detail: 'create or reuse the run record, one forked record per curd, and blocked_by edges' },
    { title: 'Answers', detail: 'on resume only: resolve each answered fork with the user words' },
    { title: 'Curds', detail: 'per curd: boss turn -> coder or reviewer -> boss turn, until finish, fork, halt, or the turn cap' },
    { title: 'Integrate', detail: 'merge clean curd branches into one integration branch' },
    { title: 'Review', detail: 'one global press -> age pass over the integrated diff' },
    { title: 'Plate', detail: 'plate clean curds in the spec landing shape; never merge' },
  ],
}

// Tracked source: claude/workflows/cheese-factory-next.js (prototype).
// Spec: specs/cheese-factory-linked-wheypoints.md (durable corpus).
// ADRs: .hallouminate/wiki/adr/cheese-factory-workflow.md ADR-011..014.
//
// The script owns only scheduling. Agents receive one pinned Wheypoint ref
// and resolve it first. The factory handback gate (agent-scoped hooks on
// curd-boss, factory-coder, and factory-reviewer) writes each handback as a
// revision and returns the new pinned ref through updatedInput.
//
// Args: { spec: string, answers?: { [curdSlug]: [{ entry_id, decision, quote }] } }
//   A bare string arg is the spec. A run that parks forks returns
//   { status: 'gated', forks }. Resume it with resumeFromRunId and answers.

const input = typeof args === 'string' ? { spec: args } : (args || {})
const SPEC_ARG = typeof input.spec === 'string' ? input.spec.trim() : ''
const ANSWERS = input.answers && typeof input.answers === 'object' ? input.answers : {}
const MAX_BOSS_TURNS = 12
const SLUG_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/
const REF_RE = /^wheypoint:[a-z0-9][a-z0-9._-]{0,63}\/[a-z0-9][a-z0-9._-]{0,63}@rev-[0-9a-f]{12}$/
const STOP_RE = /^(gated|halt)\b/i

const WORKFLOW_DIRECTIVE = 'You run inside the cheese-factory-next workflow. Do not invoke /cheese, /cook, /cure, or /plate unless this prompt tells you to. Do not chain to another phase.'

// ---- schemas (the harness subset: type, required, properties, items, enum, description, pattern) ----

const STR = { type: 'string' }
const STR_LIST = { type: 'array', items: STR }

const RESOLVE_SCHEMA = {
  type: 'object',
  required: ['mode'],
  properties: {
    mode: { type: 'string', enum: ['resolved', 'missing'] },
    usage: STR,
    spec_path: STR,
    slug: STR,
    landing_shape: { type: 'string', enum: ['single', 'orthogonal_flat', 'stacked_linear', 'diamond_stack'] },
    curds: {
      type: 'array',
      items: { type: 'object', required: ['slug', 'brief', 'depends_on'], properties: { slug: STR, brief: STR, depends_on: STR_LIST } },
    },
  },
}

const GRAPH_SCHEMA = {
  type: 'object',
  required: ['run_ref', 'curds'],
  properties: {
    run_ref: STR,
    curds: { type: 'array', items: { type: 'object', required: ['slug', 'ref'], properties: { slug: STR, ref: STR } } },
  },
}

const ANSWERS_SCHEMA = {
  type: 'object',
  required: ['curds'],
  properties: { curds: { type: 'array', items: { type: 'object', required: ['slug', 'ref'], properties: { slug: STR, ref: STR } } } },
}

const FORK_SCHEMA = {
  type: 'object',
  required: ['question', 'options'],
  properties: {
    question: STR,
    options: { type: 'array', items: { type: 'object', required: ['option', 'breaks'], properties: { option: STR, breaks: STR, evidence: STR_LIST } } },
    prior_leaning: STR,
  },
}

const BOSS_SCHEMA = {
  type: 'object',
  required: ['action', 'wheypoint_ref'],
  properties: {
    action: { type: 'string', enum: ['dispatch_coder', 'dispatch_review', 'raise_fork', 'finish'] },
    wheypoint_ref: STR,
    brief: STR,
    fork: FORK_SCHEMA,
    record_status: STR,
  },
}

const HANDBACK_SCHEMA = {
  type: 'object',
  required: ['status', 'next', 'wheypoint_ref', 'orientation'],
  properties: {
    status: STR,
    next: STR,
    wheypoint_ref: STR,
    orientation: STR,
    worktree_path: STR,
    record_status: STR,
    findings: { type: 'array', items: { type: 'object', required: ['severity', 'claim'], properties: { severity: STR, file: STR, claim: STR } } },
  },
}

const INTEGRATE_SCHEMA = {
  type: 'object',
  required: ['worktree_path', 'merged', 'conflicted'],
  properties: { worktree_path: STR, merged: STR_LIST, conflicted: STR_LIST },
}

const PHASE_SCHEMA = { type: 'object', required: ['status'], properties: { status: STR, artifact: STR, orientation: STR } }

const PLATE_SCHEMA = {
  type: 'object',
  required: ['results'],
  properties: { results: { type: 'array', items: { type: 'object', required: ['slug', 'status'], properties: { slug: STR, status: STR, pr_url: STR } } } },
}

// ---- prompts ----

function resolvePrompt() {
  return `Resolve the cheese-factory-next spec "${SPEC_ARG}".
1. Run \`python3 ~/.claude/skills/mold/scripts/mold.pyz artifact-path specs ${SPEC_ARG}\` and read \`path\`. Accept an absolute or ~/ path as the path itself.
2. When the file does not exist, return {"mode":"missing","usage":"<one line: the path you tried>"}.
3. Read the spec. Take the curds from its validated CurdPlan when the spec carries one; otherwise take the proposal in its ## Curds section.
4. Return mode "resolved", spec_path, slug, landing_shape from the frontmatter landing.shape, and curds [{slug, brief, depends_on}] with depends_on as sibling slugs.
${WORKFLOW_DIRECTIVE}`
}

function graphPrompt(resolved) {
  return `Create or reuse the linked Wheypoint graph for this cheese-factory-next run. Work in the current checkout; never edit source files.
Wheypoint: \`python3 ~/.claude/skills/wheypoint/scripts/wheypoint.pyz\`.
1. Run record work id: "factory-${resolved.slug}". When \`show\` reports no record, run \`checkpoint --work-id factory-${resolved.slug} --orientation "Factory run for ${resolved.slug}." --decision "Run started." --rationale "cheese-factory-next" --next hold --context ${resolved.spec_path} --link xdg-or-repo-ref-of-the-spec --kind implements\`.
2. For each curd, the work id is "factory-${resolved.slug}--<slug>". When it has no record, run \`fork factory-${resolved.slug} factory-${resolved.slug}--<slug> --orientation "<brief>"\`. When it exists, reuse it.
3. For each depends_on entry, run \`link <curd work id> wheypoint:<project>/factory-${resolved.slug}--<dep> --kind blocked_by\` once.
4. Run \`show\` for each record and return pinned refs: run_ref and curds [{slug, ref}] where ref is "wheypoint:<project_key>/<work_id>@<revision_id>".
Curds: ${JSON.stringify(resolved.curds)}
${WORKFLOW_DIRECTIVE}`
}

function answersPrompt(graph) {
  return `Apply the user's fork answers to the cheese-factory-next curd records. Never edit source files.
Wheypoint: \`python3 ~/.claude/skills/wheypoint/scripts/wheypoint.pyz\`.
For each curd below, run \`checkpoint --work-id <work_id> --resolve <entry_id> --rationale "<decision>" --directive "<decision>" --quote "<quote>" --next hold\` once per answer. Copy each quote verbatim.
Answers by curd: ${JSON.stringify(ANSWERS)}
Current refs: ${JSON.stringify(graph.curds)}
Return curds [{slug, ref}] with every ref pinned to the revision after your writes.
${WORKFLOW_DIRECTIVE}`
}

function bossPrompt(curd, ref, worktree, last) {
  const answers = ANSWERS[curd.slug]
  return `Curd "${curd.slug}". Ref: ${ref}.
Curd brief: ${curd.brief}
Worktree: ${worktree || 'none yet; the first coder creates it'}
Last worker result: ${last ? JSON.stringify(last) : 'none; this is the first turn'}
${answers ? `Fork answers from the user: ${JSON.stringify(answers)}` : ''}
Decide the next action for this curd and hand it back.
${WORKFLOW_DIRECTIVE}`
}

function coderPrompt(curd, ref, worktree, brief) {
  return `Curd "${curd.slug}". Ref: ${ref}.
Brief: ${brief}
${worktree ? `Worktree: ${worktree}. Change to it first; it holds branch curd/${curd.slug}.` : `You run in a fresh isolated worktree. Create branch curd/${curd.slug} first.`}
${WORKFLOW_DIRECTIVE}`
}

function reviewerPrompt(curd, ref, worktree) {
  return `Curd "${curd.slug}". Ref: ${ref}.
Worktree: ${worktree}. Review \`git diff origin/main...curd/${curd.slug}\`.
${WORKFLOW_DIRECTIVE}`
}

function integratePrompt(slug, clean) {
  return `Integrate the clean curd branches for run "${slug}" in this isolated worktree.
1. \`git checkout -B integration/${slug} origin/main\`.
2. Merge each branch in order with \`git merge --no-ff <branch>\`. On a conflict, run \`git merge --abort\`, record the slug as conflicted, and continue.
Branches: ${JSON.stringify(clean.map((c) => `curd/${c.slug}`))}
Do not push. Do not edit files.
${WORKFLOW_DIRECTIVE}
Return {"worktree_path":"<toplevel>","merged":[slugs],"conflicted":[slugs]}.`
}

function reviewPrompt(worktree) {
  return `cd ${worktree}. Run \`/press --auto\`, then \`/age origin/main...HEAD --auto\`. Do not run /cure.
${WORKFLOW_DIRECTIVE}
Return {"status":"<handback status>","artifact":"<age report path>","orientation":"<one line>"}.`
}

function platePrompt(clean, shape) {
  return `Run /plate for these clean curd branches: ${JSON.stringify(clean.map((c) => `curd/${c.slug}`))}.
Use landing shape "${shape}" from the spec. Never merge.
Return {"results":[{"slug":"...","status":"...","pr_url":"..."}]}.`
}

// ---- pure helpers ----

function validPlan(curds) {
  if (!Array.isArray(curds) || curds.length === 0) return 'the plan has no curds'
  const slugs = new Set()
  for (const c of curds) {
    if (!SLUG_RE.test(c.slug)) return `curd slug "${c.slug}" is not a valid id`
    if (slugs.has(c.slug)) return `curd slug "${c.slug}" repeats`
    slugs.add(c.slug)
  }
  for (const c of curds) {
    for (const d of c.depends_on) if (!slugs.has(d)) return `curd "${c.slug}" depends on unknown "${d}"`
  }
  return null
}

// Topological waves; a cycle returns null.
function waves(curds) {
  const remaining = new Map(curds.map((c) => [c.slug, c]))
  const done = new Set()
  const out = []
  while (remaining.size) {
    const wave = [...remaining.values()].filter((c) => c.depends_on.every((d) => done.has(d)))
    if (wave.length === 0) return null
    wave.sort((a, b) => a.slug.localeCompare(b.slug))
    for (const c of wave) remaining.delete(c.slug)
    for (const c of wave) done.add(c.slug)
    out.push(wave)
  }
  return out
}

// The gate returns a new pinned ref. An unchanged or malformed ref means the
// agent-scoped hook did not run, so the handback was never written (U-2).
function gateWrote(sent, returned) {
  return typeof returned === 'string' && REF_RE.test(returned) && returned !== sent
}

// ---- curd loop ----

async function runCurd(curd) {
  let ref = curd.ref
  let worktree = null
  let last = null
  for (let turn = 1; turn <= MAX_BOSS_TURNS; turn++) {
    const decision = await agent(bossPrompt(curd, ref, worktree, last), {
      label: `boss:${curd.slug}:t${turn}`, phase: 'Curds', agentType: 'curd-boss', schema: BOSS_SCHEMA,
    })
    if (!decision) return { slug: curd.slug, state: 'failed', ref, reason: 'boss agent returned nothing' }
    if (!gateWrote(ref, decision.wheypoint_ref)) {
      return { slug: curd.slug, state: 'failed', ref, reason: 'handback gate did not write the boss decision (U-2)' }
    }
    ref = decision.wheypoint_ref
    if (decision.action === 'finish') return { slug: curd.slug, state: 'clean', ref, worktree }
    if (decision.action === 'raise_fork') return { slug: curd.slug, state: 'parked', ref, worktree, fork: decision.fork }

    const review = decision.action === 'dispatch_review'
    if (review && !worktree) return { slug: curd.slug, state: 'failed', ref, reason: 'boss asked for review before any coder ran' }
    const opts = review
      ? { label: `review:${curd.slug}:t${turn}`, phase: 'Curds', agentType: 'factory-reviewer', schema: HANDBACK_SCHEMA }
      : { label: `code:${curd.slug}:t${turn}`, phase: 'Curds', agentType: 'factory-coder', schema: HANDBACK_SCHEMA, ...(worktree ? {} : { isolation: 'worktree' }) }
    const result = await agent(review ? reviewerPrompt(curd, ref, worktree) : coderPrompt(curd, ref, worktree, decision.brief), opts)
    if (!result) return { slug: curd.slug, state: 'failed', ref, worktree, reason: `${review ? 'reviewer' : 'coder'} returned nothing` }
    if (!gateWrote(ref, result.wheypoint_ref)) {
      return { slug: curd.slug, state: 'failed', ref, worktree, reason: 'handback gate did not write the worker result (U-2)' }
    }
    ref = result.wheypoint_ref
    if (!review && typeof result.worktree_path === 'string' && result.worktree_path.startsWith('/')) worktree = worktree || result.worktree_path
    if (STOP_RE.test(result.status)) {
      const state = /^gated/i.test(result.status) ? 'parked' : 'halted'
      return { slug: curd.slug, state, ref, worktree, reason: result.status }
    }
    last = { action: decision.action, status: result.status, next: result.next, orientation: result.orientation, findings: result.findings || [] }
  }
  return { slug: curd.slug, state: 'stalled', ref, worktree, reason: `no finish after ${MAX_BOSS_TURNS} boss turns` }
}

// ---- run ----

if (!SPEC_ARG) return { error: 'Usage: /cheese-factory-next <spec slug or path> — no spec given.' }

phase('Resolve')
const resolved = await agent(resolvePrompt(), { label: 'resolve', phase: 'Resolve', model: 'haiku', schema: RESOLVE_SCHEMA })
if (!resolved || resolved.mode !== 'resolved') return { error: (resolved && resolved.usage) || 'spec not resolved' }
const planProblem = validPlan(resolved.curds)
if (planProblem) return { error: `invalid curd plan: ${planProblem}` }
const plannedWaves = waves(resolved.curds)
if (!plannedWaves) return { error: 'invalid curd plan: depends_on forms a cycle' }

phase('Graph')
let graph = await agent(graphPrompt(resolved), { label: 'graph', phase: 'Graph', schema: GRAPH_SCHEMA })
if (!graph || !graph.curds.every((c) => REF_RE.test(c.ref))) return { error: 'graph agent returned no pinned curd refs' }

if (Object.keys(ANSWERS).length) {
  phase('Answers')
  const applied = await agent(answersPrompt(graph), { label: 'answers', phase: 'Answers', schema: ANSWERS_SCHEMA })
  if (!applied || !applied.curds.every((c) => REF_RE.test(c.ref))) return { error: 'answers agent returned no pinned curd refs' }
  const fresh = new Map(applied.curds.map((c) => [c.slug, c.ref]))
  graph = { ...graph, curds: graph.curds.map((c) => ({ ...c, ref: fresh.get(c.slug) || c.ref })) }
}

phase('Curds')
const refBySlug = new Map(graph.curds.map((c) => [c.slug, c.ref]))
const results = new Map()
for (const wave of plannedWaves) {
  const ready = []
  for (const curd of wave) {
    const blocker = curd.depends_on.find((d) => results.get(d).state !== 'clean')
    if (blocker) results.set(curd.slug, { slug: curd.slug, state: 'blocked', ref: refBySlug.get(curd.slug), reason: `depends on ${blocker} (${results.get(blocker).state})` })
    else ready.push({ ...curd, ref: refBySlug.get(curd.slug) })
  }
  const done = await pipeline(ready, (curd) => runCurd(curd))
  ready.forEach((curd, i) => results.set(curd.slug, done[i] || { slug: curd.slug, state: 'failed', ref: curd.ref, reason: 'curd loop threw' }))
}

const all = resolved.curds.map((c) => results.get(c.slug))
const parked = all.filter((r) => r.state === 'parked')
if (parked.length) {
  log(`${parked.length} curd(s) parked on a fork; returning for user answers.`)
  return {
    status: 'gated',
    run_ref: graph.run_ref,
    forks: parked.map((r) => ({ slug: r.slug, ref: r.ref, fork: r.fork || null, reason: r.reason || null })),
    curds: all,
    resume: 'Relaunch with resumeFromRunId and args.answers = { <slug>: [{ entry_id, decision, quote }] }.',
  }
}

const clean = all.filter((r) => r.state === 'clean')
if (!clean.length) return { status: 'blocked', run_ref: graph.run_ref, curds: all }

phase('Integrate')
const integrated = await agent(integratePrompt(resolved.slug, clean), { label: 'integrate', phase: 'Integrate', agentType: 'coder', isolation: 'worktree', schema: INTEGRATE_SCHEMA })
if (!integrated) return { status: 'blocked', run_ref: graph.run_ref, curds: all, reason: 'integrate agent returned nothing' }
const merged = clean.filter((r) => integrated.merged.includes(r.slug))

phase('Review')
const reviewed = await agent(reviewPrompt(integrated.worktree_path), { label: 'review', phase: 'Review', agentType: 'reviewer', schema: PHASE_SCHEMA })
if (!reviewed || STOP_RE.test(reviewed.status)) {
  return { status: 'blocked', run_ref: graph.run_ref, curds: all, integration: integrated, review: reviewed, reason: 'global review stopped' }
}

phase('Plate')
const plated = await agent(platePrompt(merged, resolved.landing_shape || 'single'), { label: 'plate', phase: 'Plate', agentType: 'coder', schema: PLATE_SCHEMA })

return { status: 'done', run_ref: graph.run_ref, curds: all, integration: integrated, review: reviewed, plate: plated }
