export const meta = {
  name: 'cheese-factory',
  description:
    'Spec-driven easy-cheese pipeline: resolve a spec (or list candidates), decide fan-out vs single-pass, run cook->taste->press->age->cure->re-age per curd, then barrier-plate clean branches into (stacked) PRs.',
  phases: [
    { title: 'Resolve', detail: 'cheap agent resolves the spec + curd-count digest, or lists candidates with no further dispatch' },
    { title: 'Decompose', detail: 'opus decomposer produces curds; JS merges file-overlapping curds; mini-specs written per curd' },
    { title: 'Cook', detail: 'sonnet coder implements one curd in an isolated worktree via /cook --auto' },
    { title: 'Taste', detail: 'opus reviewer 5-lens gate over the cook diff; revise triggers a bounded corrective pass' },
    { title: 'Press', detail: 'sonnet coder hardens tests via /press --auto' },
    { title: 'Age', detail: 'opus reviewer runs /age --auto' },
    { title: 'Cure', detail: 'sonnet coder runs /cure --auto --stake medium+, only when age reports medium+ findings' },
    { title: 'Re-age', detail: 'opus reviewer re-checks once after cure; still medium+ marks the curd dirty' },
    { title: 'Plate', detail: 'one opus barrier stacks clean curd branches into (stacked) PRs; never merges' },
    { title: 'Report', detail: 'per-curd status, branch, PR url, and excluded-curd reasons' },
  ],
}

// Tracked source: claude/workflows/cheese-factory.js in the dotfiles repo.
// Replaces claude/workflows/curd-flock.js (deleted, no alias). Spec:
// specs/cheese-factory-workflow.md (durable corpus). See
// .hallouminate/wiki/adr/cheese-factory-workflow.md for ADR-001..005.
//
// Args: { spec?: string /* slug | path */, correctiveRounds? = 2 }
//   - no spec: Resolve lists durable-corpus candidates and the workflow
//     returns them, dispatching no further agent.
//   - spec given but missing on disk: Resolve fails loud with a usage
//     message; the workflow returns { error } and stops.
//   - correctiveRounds bounds the taste `revise` -> corrective-coder loop,
//     default 2, clamped to a max of 3 (curd-flock's clamp pattern).
//
// Handoff artifacts land repo-local in each curd worktree's `.cheese/` (they
// travel with the branch) — every phase agent must cd into the worktree
// before invoking a skill. Plate opens/updates PRs but never merges.

const NO_CHAIN_DIRECTIVE = 'Do not chain forward to the next phase even though your auto-mode contract documents that. Write your handoff slug and stop. The /cheese-factory orchestrator is driving the chain. Run in the foreground — do not background yourself, spawn detached processes, or defer work to a later session. If you cannot complete the phase within your context window, write a partial slug with status: halt: <reason> and stop; do not silently timeout.'

const input = typeof args === 'string' ? (() => { try { return JSON.parse(args) } catch (e) { log(`args was a string but not valid JSON (${e.message}) — treating as no spec`); return {} } })() : args || {}
const SPEC_ARG = typeof input.spec === 'string' && input.spec.length ? input.spec : null
const MAX_CORRECTIVE_ROUNDS = 3
let CORRECTIVE_ROUNDS = Number.isInteger(input.correctiveRounds) && input.correctiveRounds >= 0 ? input.correctiveRounds : 2
if (CORRECTIVE_ROUNDS > MAX_CORRECTIVE_ROUNDS) {
  log(`Requested correctiveRounds ${CORRECTIVE_ROUNDS} exceeds max ${MAX_CORRECTIVE_ROUNDS}; clamping to ${MAX_CORRECTIVE_ROUNDS}.`)
  CORRECTIVE_ROUNDS = MAX_CORRECTIVE_ROUNDS
}

const SLUG_RE = /^[a-z0-9][a-z0-9._-]*$/
const branchFor = (slug) => `curd/${slug}`

// ---- schemas ----
const RESOLVE_SCHEMA = {
  type: 'object',
  required: ['mode'],
  properties: {
    mode: { type: 'string', enum: ['candidates', 'resolved', 'missing'] },
    candidates: { type: 'array', items: { type: 'string' } },
    spec_path: { type: 'string' },
    spec_text: { type: 'string' },
    usage: { type: 'string' },
    curd_count: {
      type: 'object',
      properties: {
        slug: { type: 'string' },
        candidate_curds: { type: 'integer' },
        blast_radius: { type: 'string' },
      },
    },
  },
}

const DECOMPOSE_SCHEMA = {
  type: 'object',
  required: ['curds'],
  properties: {
    curds: {
      type: 'array',
      items: {
        type: 'object',
        required: ['slug', 'brief', 'files'],
        properties: {
          slug: { type: 'string' },
          brief: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
        },
      },
    },
  },
}

const MINISPEC_SCHEMA = {
  type: 'object',
  required: ['curds'],
  properties: {
    curds: {
      type: 'array',
      items: {
        type: 'object',
        required: ['slug', 'spec_path'],
        properties: { slug: { type: 'string' }, spec_path: { type: 'string' } },
      },
    },
  },
}

const COOK_SCHEMA = {
  type: 'object',
  required: ['status', 'worktree_path'],
  properties: {
    status: { type: 'string' },
    artifact: { type: 'string' },
    worktree_path: { type: 'string' },
    orientation: { type: 'string' },
  },
}

const TASTE_SCHEMA = {
  type: 'object',
  required: ['verdict', 'lenses', 'issues'],
  properties: {
    verdict: { type: 'string', enum: ['pass', 'revise'] },
    lenses: { type: 'array', items: { type: 'object', required: ['lens', 'verdict'], properties: { lens: { type: 'string' }, verdict: { type: 'string' }, note: { type: 'string' } } } },
    issues: { type: 'array', items: { type: 'string' } },
    recommendation: { type: 'string' },
  },
}

const CORRECT_SCHEMA = {
  type: 'object',
  required: ['status', 'committed'],
  properties: { status: { type: 'string' }, summary: { type: 'string' }, committed: { type: 'boolean' } },
}

const PHASE_SCHEMA = {
  type: 'object',
  required: ['status'],
  properties: { status: { type: 'string' }, artifact: { type: 'string' }, orientation: { type: 'string' } },
}

const AGE_SCHEMA = {
  type: 'object',
  required: ['status', 'has_medium_plus_findings'],
  properties: { status: { type: 'string' }, artifact: { type: 'string' }, has_medium_plus_findings: { type: 'boolean' } },
}

const PLATE_SCHEMA = {
  type: 'object',
  required: ['results'],
  properties: {
    results: {
      type: 'array',
      items: { type: 'object', required: ['slug', 'status'], properties: { slug: { type: 'string' }, status: { type: 'string' }, pr_url: { type: 'string' } } },
    },
  },
}

// ---- pure helpers ----
function mergeOverlappingCurds(curds) {
  const groups = curds.map((c) => ({ slugs: [c.slug], briefs: [c.brief], files: new Set(c.files || []) }))
  let changed = true
  while (changed) {
    changed = false
    findPair:
    for (let i = 0; i < groups.length; i++) {
      for (let j = i + 1; j < groups.length; j++) {
        if ([...groups[i].files].some((f) => groups[j].files.has(f))) {
          groups[i].slugs.push(...groups[j].slugs)
          groups[i].briefs.push(...groups[j].briefs)
          for (const f of groups[j].files) groups[i].files.add(f)
          groups.splice(j, 1)
          changed = true
          break findPair
        }
      }
    }
  }
  return groups.map((g) => ({
    slug: g.slugs[0],
    brief: g.briefs.join('\n\n'),
    files: [...g.files],
    merged_from: g.slugs.length > 1 ? g.slugs : undefined,
  }))
}

function findInvalidSlugs(curds) {
  return curds.filter((c) => typeof c.slug !== 'string' || !c.slug.length || !SLUG_RE.test(c.slug)).map((c) => c.slug || '(missing slug)')
}

function findDuplicateSlugs(curds) {
  const seen = new Set(); const dupes = new Set()
  for (const c of curds) { if (seen.has(c.slug)) dupes.add(c.slug); seen.add(c.slug) }
  return [...dupes]
}

// ---- prompts ----
function resolvePrompt() {
  return `You are a cheap resolver agent for the /cheese-factory workflow. Use Bash.

${SPEC_ARG
  ? `A spec was given: "${SPEC_ARG}" (slug or path).
1. Resolve it: \`SPEC=$(python3 ~/.claude/skills/mold/scripts/mold.pyz artifact-path specs ${SPEC_ARG})\`, falling back to treating the arg as a literal path if it already looks like one.
2. If the resolved file does not exist, return {"mode":"missing","usage":"Usage: /cheese-factory { spec: <slug-or-path> } — spec not found at <resolved path>"}.
3. Otherwise read the spec's full text, then run: \`python3 ~/.claude/skills/mold/scripts/mold.pyz curd-count "$SPEC" --blast-radius medium\` (omit --blast-radius if the spec states one and use that instead). Return {"mode":"resolved","spec_path":"<resolved path>","spec_text":"<full spec text>","curd_count":{"slug":"...","candidate_curds":<n>,"blast_radius":"..."}}.`
  : `No spec was given. Scan the durable spec corpus ($XDG_DATA_HOME/cheese/<project>/specs/ or ~/.local/share/cheese/<project>/specs/) plus legacy .cheese/specs/ for candidate spec files. Return {"mode":"candidates","candidates":["<slug-or-path>", ...]}.`}

Return only the structured JSON described above.`
}

function decomposePrompt(specText) {
  return `You are an opus decomposer for the /cheese-factory workflow. Read the spec below and split it into file-disjoint curds — independently implementable units of work.

Spec:
${specText}

Return {"curds":[{"slug":"<kebab-slug>","brief":"<what this curd must do>","files":["<path>", ...]}, ...]}. Each slug must match ${SLUG_RE} and be unique. List every file each curd is expected to touch so overlaps can be detected.`
}

function miniSpecPrompt(parentSlug, curds) {
  return `You are a coder agent for the /cheese-factory workflow. Use Bash and your write tool.

For each curd below, resolve its mini-spec path with \`python3 ~/.claude/skills/mold/scripts/mold.pyz artifact-path specs ${parentSlug}--<slug>\` and write the mini-spec there using mold's agent-invoked mini-spec schema (see skills/mold/SKILL.md § Agent-invoked mini-spec mode), deriving the mini-spec content from the curd's brief and files:

${JSON.stringify(curds.map((c) => ({ slug: c.slug, brief: c.brief, files: c.files })))}

Return {"curds":[{"slug":"<slug>","spec_path":"<resolved path>"}, ...]} — one entry per curd, in the same order.`
}

function isoContract(branch) {
  return `
## Isolation contract
- First command: \`git checkout -B ${branch} origin/main\` (or, if the worktree already exists on ${branch} from an earlier phase, just confirm you're on it — recreate with \`git worktree add <path> ${branch}\` if it was reaped).
- Work ONLY this curd's scope. Do NOT touch sibling curds' files. Do NOT push, open a PR, or merge — /cheese-factory's plate barrier handles publication after every curd chain finishes.
- Commit locally on ${branch} only, Conventional Commits, no flair/emojis.
`
}

function cookPrompt(curd) {
  const branch = branchFor(curd.slug)
  return `You are the Cook phase of the /cheese-factory pipeline for curd "${curd.slug}".
${isoContract(branch)}
Run \`/cook ${curd.spec_path} --auto\` via the Skill tool.

${NO_CHAIN_DIRECTIVE}

Report the resolved worktree path (\`git rev-parse --show-toplevel\`) and your /cook handoff slug fields. Return {"status":"...","artifact":"...","worktree_path":"...","orientation":"..."}.`
}

function tastePrompt(curd, branch) {
  return `You are a read-only opus reviewer running the Taste phase (5-lens gate) for curd "${curd.slug}".

Diff under review: \`git diff origin/main...${branch}\` (read-only — do not check out or edit anything).

## Lenses (judge each pass | revise)
- drift: the diff implements the curd's intent, not an adjacent or weaker thing.
- readability: minimal, clean, matches surrounding style.
- scope: only files traceable to the curd changed.
- production-path: reachable on the real code path, not just asserted in prose/tests.
- wired-callers: any changed signature/export has its callers updated.

Return {"verdict":"pass"|"revise","lenses":[{"lens":"...","verdict":"...","note":"..."}],"issues":["..."],"recommendation":"..."}. Overall verdict is revise if any lens is revise.`
}

function correctivePrompt(curd, worktreePath, branch, taste) {
  return `You are a coder applying a bounded corrective pass in worktree ${worktreePath} (already on ${branch}) for curd "${curd.slug}" after the Taste phase returned "revise".

Findings to fix:
${JSON.stringify({ issues: taste.issues, lenses: taste.lenses })}

Address ONLY these findings — no scope expansion. Commit on ${branch} (no push). Return {"status":"fixed"|"partial"|"blocked","summary":"...","committed":true|false}.`
}

function pressPrompt(curd, worktreePath) {
  return `You are the Press phase for curd "${curd.slug}". cd ${worktreePath} first.

Run \`/press ${curd.slug} --auto\` via the Skill tool.

${NO_CHAIN_DIRECTIVE}

Return {"status":"...","artifact":"...","orientation":"..."}.`
}

function agePrompt(curd, worktreePath, label) {
  return `You are the ${label} phase for curd "${curd.slug}". cd ${worktreePath} first.

Run \`/age ${curd.slug} --auto\` via the Skill tool.

${NO_CHAIN_DIRECTIVE}

Read the resulting age report and determine whether any finding is medium severity or above. Return {"status":"...","artifact":"...","has_medium_plus_findings":true|false}.`
}

function curePrompt(curd, worktreePath) {
  return `You are the Cure phase for curd "${curd.slug}". cd ${worktreePath} first.

Run \`/cure ${curd.slug} --auto --stake medium+\` via the Skill tool.

${NO_CHAIN_DIRECTIVE}

Return {"status":"...","artifact":"...","orientation":"..."}.`
}

function platePrompt(cleanCurds, singlePass) {
  return `You are the Plate barrier for the /cheese-factory workflow. Run once, after every curd chain has finished.

Clean curd branches (slug-sorted): ${JSON.stringify(cleanCurds.map((c) => ({ slug: c.slug, branch: branchFor(c.slug) })))}

${singlePass
  ? 'Single-pass mode: run /plate for an ordinary single PR on the one branch above.'
  : 'Fan-out mode: run /plate to stack these branches into a stacked-PR chain in slug-sorted order, stating the order in the PR bodies.'}

Push and open/update PRs. NEVER merge.

Return {"results":[{"slug":"...","status":"...","pr_url":"..."}]}.`
}

// ---- Resolve ----
phase('Resolve')
const resolved = await agent(resolvePrompt(), { label: 'resolve', phase: 'Resolve', model: 'haiku', schema: RESOLVE_SCHEMA })

if (resolved.mode === 'missing') {
  log(`Spec not resolved: ${resolved.usage || 'spec not found'}`)
  return { error: resolved.usage || `Spec not found: ${SPEC_ARG}` }
}

if (resolved.mode === 'candidates') {
  const candidates = resolved.candidates || []
  log(`No spec given — ${candidates.length} candidate(s) found.`)
  return { candidates }
}

const parentSpecPath = resolved.spec_path
const parentSlug = resolved.curd_count && resolved.curd_count.slug ? resolved.curd_count.slug : 'spec'
if (!SLUG_RE.test(parentSlug)) {
  log(`Invalid parent slug from resolver: ${parentSlug}`)
  return { error: `Invalid parent slug: ${parentSlug}` }
}
const candidateCurds = resolved.curd_count ? resolved.curd_count.candidate_curds : 0

// ---- Decompose (only when candidate_curds >= 2) ----
let curds
let singlePass = false

if (candidateCurds >= 2) {
  phase('Decompose')
  const decomposed = await agent(decomposePrompt(resolved.spec_text), { label: 'decompose:plan', phase: 'Decompose', model: 'opus', schema: DECOMPOSE_SCHEMA })
  const merged = mergeOverlappingCurds(decomposed.curds)

  if (merged.length < 2) {
    log(`Decomposition merged down to ${merged.length} curd(s) — running single-pass against the parent spec.`)
    singlePass = true
    curds = [{ slug: parentSlug, spec_path: parentSpecPath, brief: null, files: [] }]
  } else {
    const invalidSlugs = findInvalidSlugs(merged)
    if (invalidSlugs.length) {
      log(`Invalid curd slug(s) from decomposer: ${invalidSlugs.join(', ')}`)
      return { error: `Invalid curd slug(s): ${invalidSlugs.join(', ')}` }
    }
    const duplicateSlugs = findDuplicateSlugs(merged)
    if (duplicateSlugs.length) {
      log(`Duplicate curd slug(s) from decomposer: ${duplicateSlugs.join(', ')}`)
      return { error: `Duplicate curd slug(s): ${duplicateSlugs.join(', ')}` }
    }

    const miniSpecs = await agent(miniSpecPrompt(parentSlug, merged), { label: 'decompose:write-minispecs', phase: 'Decompose', agentType: 'coder', model: 'opus', schema: MINISPEC_SCHEMA })
    const pathBySlug = new Map(miniSpecs.curds.map((c) => [c.slug, c.spec_path]))
    curds = merged.map((c) => ({ ...c, spec_path: pathBySlug.get(c.slug) }))
  }
} else {
  singlePass = true
  curds = [{ slug: parentSlug, spec_path: parentSpecPath, brief: null, files: [] }]
}

// ---- Per-curd chain (pipelined) ----
phase('Cook')
log(`Running ${curds.length} curd chain(s)${singlePass ? ' (single-pass)' : ''}: ${curds.map((c) => c.slug).join(', ')}`)

const chainResults = await pipeline(
  curds,

  (curd) => agent(cookPrompt(curd), { label: `cook:${curd.slug}`, phase: 'Cook', agentType: 'coder', isolation: 'worktree', model: 'sonnet', schema: COOK_SCHEMA })
    .then((cook) => ({ curd, branch: branchFor(curd.slug), cook, failure: null }))
    .catch((e) => ({ curd, branch: branchFor(curd.slug), cook: null, failure: { stage: 'cook', message: e.message } })),

  async ({ curd, branch, cook, failure }) => {
    if (failure) return { curd, branch, cook, taste: null, tasteRounds: 0, failure }
    if (!cook || cook.status !== 'ok' || !cook.worktree_path) {
      return { curd, branch, cook, taste: null, tasteRounds: 0, failure: { stage: 'cook', message: 'cook did not report status ok with a worktree_path' } }
    }
    let taste
    try {
      taste = await agent(tastePrompt(curd, branch), { label: `taste:${curd.slug}`, phase: 'Taste', agentType: 'reviewer', model: 'opus', schema: TASTE_SCHEMA })
    } catch (e) {
      return { curd, branch, cook, taste: null, tasteRounds: 0, failure: { stage: 'taste', message: e.message } }
    }
    let round = 0
    while (taste.verdict === 'revise' && round < CORRECTIVE_ROUNDS) {
      let correction
      try {
        correction = await agent(correctivePrompt(curd, cook.worktree_path, branch, taste), { label: `correct:${curd.slug}:r${round + 1}`, phase: 'Taste', agentType: 'coder', model: 'sonnet', schema: CORRECT_SCHEMA })
      } catch (e) {
        return { curd, branch, cook, taste, tasteRounds: round, failure: { stage: 'taste-correct', message: e.message } }
      }
      round++
      if (!correction.committed) {
        log(`${curd.slug}: corrective round ${round} produced an uncommitted correction — stopping the taste loop.`)
        break
      }
      try {
        taste = await agent(tastePrompt(curd, branch), { label: `taste:${curd.slug}:r${round}`, phase: 'Taste', agentType: 'reviewer', model: 'opus', schema: TASTE_SCHEMA })
      } catch (e) {
        return { curd, branch, cook, taste, tasteRounds: round, failure: { stage: 'taste', message: e.message } }
      }
    }
    return { curd, branch, cook, taste, tasteRounds: round, failure: null }
  },

  async ({ curd, branch, cook, taste, tasteRounds, failure }) => {
    if (failure || !taste || taste.verdict === 'revise') return { curd, branch, cook, taste, tasteRounds, press: null, failure: failure || { stage: 'taste', message: 'taste did not reach pass within correctiveRounds' } }
    let press
    try {
      press = await agent(pressPrompt(curd, cook.worktree_path), { label: `press:${curd.slug}`, phase: 'Press', agentType: 'coder', model: 'sonnet', schema: PHASE_SCHEMA })
    } catch (e) {
      return { curd, branch, cook, taste, tasteRounds, press: null, failure: { stage: 'press', message: e.message } }
    }
    return { curd, branch, cook, taste, tasteRounds, press, failure: null }
  },

  async ({ curd, branch, cook, taste, tasteRounds, press, failure }) => {
    if (failure) return { curd, branch, cook, taste, press, age: null, cure: null, reage: null, failure }
    let age
    try {
      age = await agent(agePrompt(curd, cook.worktree_path, 'Age'), { label: `age:${curd.slug}`, phase: 'Age', agentType: 'reviewer', model: 'opus', schema: AGE_SCHEMA })
    } catch (e) {
      return { curd, branch, cook, taste, press, age: null, cure: null, reage: null, failure: { stage: 'age', message: e.message } }
    }

    if (!age.has_medium_plus_findings) {
      return { curd, branch, cook, taste, press, age, cure: null, reage: null, failure: null }
    }

    let cure
    try {
      cure = await agent(curePrompt(curd, cook.worktree_path), { label: `cure:${curd.slug}`, phase: 'Cure', agentType: 'coder', model: 'sonnet', schema: PHASE_SCHEMA })
    } catch (e) {
      return { curd, branch, cook, taste, press, age, cure: null, reage: null, failure: { stage: 'cure', message: e.message } }
    }

    let reage
    try {
      reage = await agent(agePrompt(curd, cook.worktree_path, 'Re-age'), { label: `reage:${curd.slug}`, phase: 'Re-age', agentType: 'reviewer', model: 'opus', schema: AGE_SCHEMA })
    } catch (e) {
      return { curd, branch, cook, taste, press, age, cure, reage: null, failure: { stage: 'reage', message: e.message } }
    }

    return { curd, branch, cook, taste, press, age, cure, reage, failure: null }
  },
)

// ---- Plate (barrier — runs once after every chain finishes) ----
const withStatus = chainResults.map((r) => {
  if (!r) return null
  const { curd, branch, failure, reage } = r
  let status
  let excluded_reason
  if (failure) { status = 'failed'; excluded_reason = `${failure.stage}: ${failure.message}` }
  else if (reage && reage.has_medium_plus_findings) { status = 'dirty'; excluded_reason = 're-age still reports medium+ findings' }
  else status = 'clean'
  return { curd, branch, status, excluded_reason }
})

const cleanEntries = withStatus.filter((r) => r && r.status === 'clean')

phase('Plate')
let plateBySlug = new Map()
if (cleanEntries.length) {
  const plated = await agent(platePrompt(cleanEntries.map((r) => r.curd), singlePass), { label: 'plate', phase: 'Plate', agentType: 'coder', model: 'opus', schema: PLATE_SCHEMA })
  plateBySlug = new Map(plated.results.map((r) => [r.slug, r]))
} else {
  log('No clean curds — skipping plate.')
}

// ---- Report ----
phase('Report')
const curdsOut = withStatus.map((r) => {
  if (!r) return null
  const plate = plateBySlug.get(r.curd.slug)
  return {
    slug: r.curd.slug,
    branch: r.branch,
    status: r.status,
    pr_url: plate ? plate.pr_url : undefined,
    excluded_reason: r.excluded_reason,
  }
})

const summary = { clean: 0, dirty: 0, failed: 0 }
for (const c of curdsOut) if (c) summary[c.status] = (summary[c.status] || 0) + 1
log(`Report: ${curdsOut.length} curd(s) — clean:${summary.clean} dirty:${summary.dirty} failed:${summary.failed}`)

return { curds: curdsOut, summary }
