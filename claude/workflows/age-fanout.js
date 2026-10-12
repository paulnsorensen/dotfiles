export const meta = {
  name: 'age-fanout',
  description:
    "Shared child workflow implementing /age's scale-triggered fan-out (Seams 2-4: Packet, Review, Reconcile) for parent workflows (cheese-factory, move-my-cheese) via workflow('age-fanout', args). Zero copied review semantics -- agent prompts point at the deployed skill files, which agents read at runtime.",
  phases: [
    { title: 'Packet', detail: 'one explorer agent assembles the shared review packet per references/packet.md and parses the dimension list off dimensions.md headings' },
    { title: 'Review', detail: 'one opus reviewer per dimension, fanned out in parallel, reads only its dimension rubric and reviews the diff read-only' },
    { title: 'Reconcile', detail: 'one opus reviewer applies the dimension-boundaries table, dedups, and writes the findings report; with route_curds it returns a flat findings list and does not attribute findings to curds' },
  ],
}

// Tracked source: claude/workflows/age-fanout.js in the dotfiles repo.
// Shared child workflow implementing /age's scale-triggered fan-out (Seams
// 2-4) for parent workflows (cheese-factory, move-my-cheese) via
// workflow('age-fanout', args). Zero copied review semantics: every agent
// prompt below POINTS at the deployed skill files
// (~/.claude/skills/age/SKILL.md, references/dimensions.md,
// references/packet.md), which the dispatched agents read at runtime rather
// than this workflow duplicating rubric or output-format text.
//
// Args: { worktree_path: string, range: string, slug: string, route_curds?:
//   [{slug, branch}] } — worktree_path, range, and slug are required and
//   validated before any agent() call; invalid args return
//   { status: 'blocked', error } with zero agents dispatched. route_curds is
//   optional and, when present, makes Reconcile return a flat findings list
//   that the caller routes to curds by file.
//
// Return: { status: 'ok'|'blocked', artifact, has_medium_plus_findings,
//   has_cheap_lows, dimensions: [...], error? }. With route_curds the return
//   adds a flat findings list (severity, fix_cost_now per item) and omits
//   per_curd; without it the return carries per_curd: null.
//
// Every dimension must return a review. A worker that is lost or blocked
// gets one retry. A dimension that still has no review blocks the run, so a
// parent falls back to one full reviewer and never reads partial coverage as
// a clean pass.

const NO_CHAIN_DIRECTIVE = 'Do not chain forward to the next phase even though your auto-mode contract documents that. Write your handoff slug and stop. The parent workflow orchestrating /age-fanout is driving the chain. Run in the foreground — do not background yourself, spawn detached processes, or defer work to a later session. If you cannot complete the phase within your context window, write a partial slug with status: halt: <reason> and stop; do not silently timeout.'

const input = typeof args === 'string' ? (() => { try { return JSON.parse(args) } catch (e) { log(`args was a string but not valid JSON (${e.message})`); return {} } })() : args || {}

// SLUG_RE / SAFE_REF_RE match cheese-factory.js / move-my-cheese.js verbatim.
const SLUG_RE = /^[a-z0-9][a-z0-9._-]*$/
const SAFE_REF_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/
// SAFE_REF_RE extended to allow one ".." or "..." range separator: a diff
// range like "origin/main...HEAD" is otherwise indistinguishable from the
// ref-shape SAFE_REF_RE already accepts (dots are legal ref characters), so
// this is the same char class without move-my-cheese's extra `..` exclusion.
const RANGE_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/
const PATH_RE = /^[A-Za-z0-9._/-]+$/
// Verbatim slug of a `### heading` in ~/.claude/skills/age/references/dimensions.md's
// "## Per-dimension rubrics" section (e.g. "correctness", "deslop") -- the
// packet phase must return exactly these, byte-matched, so the Review
// phase's `### ${dim}` heading lookup resolves.
const DIM_SLUG_PATTERN = '^[a-z][a-z-]*$'
const DIM_SLUG_RE = new RegExp(DIM_SLUG_PATTERN)

const isValidPath = (p) => typeof p === 'string' && PATH_RE.test(p)
const isValidRange = (r) => typeof r === 'string' && RANGE_RE.test(r)
const isValidSlug = (s) => typeof s === 'string' && SLUG_RE.test(s)
const isValidRef = (r) => typeof r === 'string' && SAFE_REF_RE.test(r)
const isValidRouteCurds = (rc) => {
  if (rc === undefined) return true
  if (!Array.isArray(rc)) return false
  return rc.every((c) => c && typeof c === 'object' && isValidSlug(c.slug) && isValidRef(c.branch))
}

const errors = []
if (!isValidPath(input.worktree_path)) errors.push('worktree_path missing or contains invalid characters')
if (!isValidRange(input.range)) errors.push('range missing or invalid')
if (!isValidSlug(input.slug)) errors.push('slug missing or invalid')
if (!isValidRouteCurds(input.route_curds)) errors.push('route_curds malformed')
if (errors.length) {
  log(`Invalid args: ${errors.join('; ')}`)
  return { status: 'blocked', error: errors.join('; ') }
}

const WORKTREE_PATH = input.worktree_path
const RANGE = input.range
const SLUG = input.slug
const ROUTE_CURDS = input.route_curds || null

// ---- schemas ----
const PACKET_SCHEMA = {
  type: 'object',
  required: ['skill_files_ok', 'dimensions', 'packet_path'],
  properties: {
    skill_files_ok: { type: 'boolean' },
    blocked_reason: { type: 'string' },
    dimensions: { type: 'array', items: { type: 'string', pattern: DIM_SLUG_PATTERN } },
    packet_path: { type: 'string' },
  },
}

const REVIEW_STATUSES = ['ok', 'blocked']

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['status', 'findings'],
  properties: {
    status: { type: 'string', enum: REVIEW_STATUSES },
    blocked_reason: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          dimension: { type: 'string' },
          severity: { type: 'string', enum: ['blocker', 'high', 'medium', 'low'] },
          file: { type: 'string' },
          line: { type: 'integer' },
          claim: { type: 'string' },
          why_it_matters: { type: 'string' },
          fix_direction: { type: 'string' },
          also_relevant_to: { type: 'array', items: { type: 'string' } },
        },
      },
    },
  },
}

const RECONCILE_SCHEMA = {
  type: 'object',
  required: ['status', 'has_medium_plus_findings', 'has_cheap_lows', 'artifact', ...(ROUTE_CURDS ? ['findings'] : [])],
  properties: {
    status: { type: 'string', enum: REVIEW_STATUSES },
    blocked_reason: { type: 'string' },
    has_medium_plus_findings: { type: 'boolean' },
    has_cheap_lows: { type: 'boolean' },
    artifact: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        ...(ROUTE_CURDS ? { required: ['severity', 'fix_cost_now', 'file'] } : {}),
        properties: {
          dimension: { type: 'string' },
          severity: { type: 'string', enum: ['blocker', 'high', 'medium', 'low'] },
          fix_cost_now: { type: 'string', enum: ['contained', 'sprawling', 'n/a'] },
          file: { type: 'string' },
          line: { type: 'integer' },
          claim: { type: 'string' },
          why_it_matters: { type: 'string' },
          fix_direction: { type: 'string' },
        },
      },
    },
  },
}

// ---- prompts ----
// The reviewer contract loads the age skill by default. These prompts name the
// skill's reference files, so the reviewer reads them and skips the Skill tool.
const AGE_FILES_DIRECTIVE = 'The files named below are the age skill references. Read them directly. Do not load the age skill or any other skill through the Skill tool.'
// Code matches each finding's file against git diff --name-only output, so route mode needs paths in that exact form.
const REPO_RELATIVE_PATH = '<repo-relative path, no leading ./, no absolute prefix>'
const BLOCKED_DIRECTIVE = 'When you cannot do this review, return status blocked with blocked_reason. Never return status ok for a review you did not run.'

function packetPrompt(worktreePath, range, slug) {
  // Explorer agents carry Bash, so the packet is assembled and written via
  // shell redirection rather than a write tool.
  return `You are the Packet phase for /age-fanout. Use Bash.

cd ${worktreePath} first.

First verify these files exist and are readable: \`~/.claude/skills/age/SKILL.md\`, \`~/.claude/skills/age/references/dimensions.md\`, \`~/.claude/skills/age/references/packet.md\`. If any is missing or unreadable, stop here and return {"skill_files_ok":false,"blocked_reason":"<which file, and why>","dimensions":[],"packet_path":""} -- do not guess a dimension list or improvise a packet from memory.

Assemble the shared context packet per \`~/.claude/skills/age/references/packet.md\` for the diff range \`${range}\`, and write it to \`.cheese/age/${slug}-packet.md\` (via Bash redirection).

Then parse the dimension list from \`~/.claude/skills/age/references/dimensions.md\`: find its \`## Per-dimension rubrics\` section and list exactly the \`###\` heading text beneath it, verbatim and lowercase, one entry per heading -- do not invent, rename, expand, or title-case any heading. These strings feed directly into a \`### <dim>\` heading lookup in the Review phase, so they must byte-match the heading text exactly. If that section is absent or its headings don't parse cleanly, return {"skill_files_ok":false,"blocked_reason":"<what went wrong>","dimensions":[],"packet_path":""} instead of guessing.

Return {"skill_files_ok":true,"dimensions":["<dim>", ...],"packet_path":".cheese/age/${slug}-packet.md"}.`
}

function reviewPrompt(dim, worktreePath, range, packetPath) {
  return `Review mode: severity-report

You are a read-only reviewer for dimension "${dim}" in the /age-fanout Review phase. Use Bash for read-only inspection only — do not edit, commit, or push anything.

cd ${worktreePath} first.

${AGE_FILES_DIRECTIVE}

Read the packet at ${packetPath}, and read ONLY the "${dim}" section of \`~/.claude/skills/age/references/dimensions.md\` (its \`### ${dim}\` heading through the next heading). If "${dim}" is "deslop", also read the matching de-slop language reference for every language present in the diff.

Review only \`git diff ${range}\`. For each finding, compute its full severity per the rubric you just read — base tier, then the location bump and compounding bump described in dimensions.md's severity-computation section, capped at blocker. Tag \`also_relevant_to\` with any other dimension a finding also touches, per that dimension's own rubric. Do NOT dedup against other workers' findings — the orchestrator reconciles those.

${BLOCKED_DIRECTIVE}

${NO_CHAIN_DIRECTIVE}

Return {"status":"ok","findings":[{"dimension":"${dim}","severity":"blocker|high|medium|low","file":"${ROUTE_CURDS ? REPO_RELATIVE_PATH : '<path>'}","line":<int>,"claim":"<what's wrong>","why_it_matters":"<impact>","fix_direction":"<how to fix>","also_relevant_to":["<dim>", ...]}]}.`
}

function reconcilePrompt(worktreePath, slug, findings, routeCurds, packetPath, range) {
  return `Review mode: severity-report

You are the Reconcile phase for /age-fanout, curd "${slug}". cd ${worktreePath} first.

${AGE_FILES_DIRECTIVE}

Context packet: ${packetPath}. Diff range reviewed: \`${range}\`.

Worker findings (JSON, not yet deduped):
${JSON.stringify(findings)}

Apply the "§ Dimension boundaries" table (verbatim) from \`~/.claude/skills/age/references/dimensions.md\` to (a) any file:line flagged by 2 or more workers, and (b) every \`also_relevant_to\` tag. Dedup findings describing the same defect. Write the findings report with tilth_write to the absolute path \`${worktreePath}/.cheese/age/${slug}.md\`. A \`cd\` does not carry into tilth_write, so never use a relative path. Use the format described in \`~/.claude/skills/age/SKILL.md § Output\`, including the handoff slug at the top per that section's template — read it there rather than assuming the shape. Ground the report's Orientation and Confidence sections in the context packet and the diff range above.

${routeCurds ? `Return a flat "findings" array: every deduped finding, each with severity (blocker|high|medium|low) and fix_cost_now (contained|sprawling|n/a), plus dimension, file, line, claim, why_it_matters, and fix_direction. Write each file as a ${REPO_RELATIVE_PATH}; rewrite any worker path that is absolute or starts with ./ into that form. Downstream code consumes these objects, so keep file/line/fix_direction intact. Do not attribute findings to curds.

` : ''}Set has_cheap_lows to true when any low finding has fix-cost-now: contained.

${BLOCKED_DIRECTIVE} Return status ok only after the report file exists.

Return {"status":"ok","has_medium_plus_findings":true|false,"has_cheap_lows":true|false,"artifact":".cheese/age/${slug}.md"${routeCurds ? ',"findings":[{"dimension":"...","severity":"blocker|high|medium|low","fix_cost_now":"contained|sprawling|n/a","file":"' + REPO_RELATIVE_PATH + '","line":<int>,"claim":"...","why_it_matters":"...","fix_direction":"..."}]' : ''}}.`
}

// ---- Packet ----
phase('Packet')
let packet
try {
  packet = await agent(packetPrompt(WORKTREE_PATH, RANGE, SLUG), { label: 'packet', phase: 'Packet', agentType: 'explorer', model: 'sonnet', schema: PACKET_SCHEMA })
} catch (e) {
  log(`Packet phase failed: ${e.message}`)
  return { status: 'blocked', error: `packet phase failed: ${e.message}` }
}

if (!packet.skill_files_ok) {
  log(`Packet phase reported the age skill file contract is broken: ${packet.blocked_reason || 'unspecified'}`)
  return { status: 'blocked', error: packet.blocked_reason || 'age skill files missing or unreadable' }
}

if (!Array.isArray(packet.dimensions) || packet.dimensions.length === 0) {
  log('Packet phase returned no dimensions.')
  return { status: 'blocked', error: 'packet phase returned no dimensions' }
}

// Authoritative in-script guard, kept alongside the schema `pattern` above: some agent-runtime schema validators silently ignore `pattern`, so this check enforces the slug shape regardless of what the runtime validated.
const invalidDimensions = packet.dimensions.filter((d) => !DIM_SLUG_RE.test(d))
if (invalidDimensions.length) {
  log(`Packet phase returned non-slug dimension(s): ${invalidDimensions.join(', ')}`)
  return { status: 'blocked', error: `invalid dimension slug(s): ${invalidDimensions.join(', ')}` }
}

const dimensions = packet.dimensions

// ---- Review (fanned out, one worker per dimension) ----
phase('Review')
// A lost (null or thrown) or blocked worker gets one retry; a second miss leaves the dimension uncovered.
async function reviewDimension(dim) {
  for (const attempt of [1, 2]) {
    const label = attempt === 1 ? `review:${dim}` : `review:${dim}:retry`
    let result = null
    try {
      result = await agent(reviewPrompt(dim, WORKTREE_PATH, RANGE, packet.packet_path), { label, phase: 'Review', agentType: 'reviewer', model: 'opus', schema: REVIEW_SCHEMA })
    } catch (e) {
      log(`review:${dim} attempt ${attempt} failed: ${e.message}`)
    }
    if (result && result.status === 'ok') return result
    if (result) log(`review:${dim} attempt ${attempt} blocked: ${result.blocked_reason || 'no reason given'}`)
  }
  return null
}

const reviewResults = await parallel(dimensions.map((dim) => () => reviewDimension(dim)))

const uncovered = dimensions.filter((_, i) => !reviewResults[i])
if (uncovered.length) {
  log(`No review for ${uncovered.length} of ${dimensions.length} dimension(s) after a retry: ${uncovered.join(', ')}.`)
  return { status: 'blocked', error: `dimensions not reviewed: ${uncovered.join(', ')}` }
}

const allFindings = reviewResults.flatMap((r) => r.findings || [])

// ---- Reconcile ----
phase('Reconcile')
let reconcile
try {
  reconcile = await agent(reconcilePrompt(WORKTREE_PATH, SLUG, allFindings, ROUTE_CURDS, packet.packet_path, RANGE), { label: 'reconcile', phase: 'Reconcile', agentType: 'reviewer', model: 'opus', schema: RECONCILE_SCHEMA })
} catch (e) {
  log(`Reconcile phase failed: ${e.message}`)
  return { status: 'blocked', error: `reconcile phase failed: ${e.message}` }
}
if (!reconcile || reconcile.status !== 'ok') {
  const reason = (reconcile && reconcile.blocked_reason) || 'reconcile returned no report'
  log(`Reconcile phase blocked: ${reason}`)
  return { status: 'blocked', error: `reconcile blocked: ${reason}` }
}

return {
  status: 'ok',
  // The prompt fixes the report path, so the reconciler cannot redirect it.
  artifact: `.cheese/age/${SLUG}.md`,
  has_medium_plus_findings: reconcile.has_medium_plus_findings,
  has_cheap_lows: reconcile.has_cheap_lows === true,
  dimensions,
  ...(ROUTE_CURDS ? { findings: reconcile.findings } : { per_curd: null }),
}
