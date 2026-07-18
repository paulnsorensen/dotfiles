
export const meta = {
  name: 'sliced-bread-audit',
  description:
    'Deep slice-by-slice audit of a Sliced Bread codebase: map the slices, pipeline one fable evaluator per slice straight into verification (batch citation-check plus an adversarial refuter on blocker/high), run a concurrent cross-slice dependency pass, and open labeled GitHub issues for confirmed findings in batches.',
  whenToUse:
    'Audit a repo (or subtree) against Sliced Bread architecture and code quality with findings landing as GitHub issues. Requires gh auth in the target repo. Pass {dry_run: true} to preview without filing issues.',
  phases: [
    { title: 'Map', detail: 'discover slices; in parallel, gh setup (labels + existing audit issues)' },
    { title: 'Evaluate', detail: 'one fable evaluator per slice (pipelined into Verify) + concurrent cross-slice pass', model: 'fable' },
    { title: 'Verify', detail: 'per-slice sonnet batch citation-check; one adversarial fable refuter per blocker/high' },
    { title: 'File', detail: 'dedupe against existing issues, cap, file gh issues in batches of 10' },
  ],
}

// Tracked source: claude/workflows/sliced-bread-audit.js in the dotfiles repo.
// Deployed to ~/.claude/workflows/ by `dots sync` (exact_workflows assembly in
// .sync-lib.sh). Invoked as `/sliced-bread-audit [scope]` or with object args:
//   { scope?: string, min_severity?: 'blocker'|'high'|'medium'|'low',
//     dry_run?: boolean, max_issues?: number }
//
// The architecture rubric below is inlined from
// ~/.claude/reference/sliced-bread.md so evaluators work in any repo without
// depending on that file being readable.

// ── args ────────────────────────────────────────────────────────────────
const opts = typeof args === 'string' ? { scope: args } : args && typeof args === 'object' ? args : {}
const SCOPE = (opts.scope || '.').trim() || '.'
const MIN_SEVERITY = opts.min_severity || 'medium'
const DRY_RUN = opts.dry_run === true
const MAX_ISSUES = opts.max_issues === undefined ? 25 : opts.max_issues

const SEV_RANK = { blocker: 3, high: 2, medium: 1, low: 0 }
if (!(MIN_SEVERITY in SEV_RANK)) {
  return { error: `min_severity must be one of blocker|high|medium|low, got: ${MIN_SEVERITY}` }
}
if (!(Number.isInteger(MAX_ISSUES) && MAX_ISSUES > 0)) {
  return { error: `max_issues must be a positive integer, got: ${MAX_ISSUES}` }
}

// ── rubric (inlined Sliced Bread rules) ─────────────────────────────────
const RUBRIC = [
  'SLICED BREAD ARCHITECTURE RUBRIC (vertical slices; each slice exposes a crust/index public API):',
  'Dependency direction (arrows may ONLY point this way):',
  '  app/ -> domains/*  |  adapters/ -> domains/*  |  domains/* -> domains/common/',
  '  NEVER: domains/* -> adapters/*, domains/* -> app/*, adapters/* -> app/*, common/ -> sibling domains.',
  'Checks:',
  '  1. import-direction — do all arrows point inward (toward domains)? Any inversion is a blocker.',
  '  2. crust-integrity — external consumers import ONLY from the slice index/barrel file, never internals (e.g. from domains.pricing.discount_calculator instead of from domains.pricing).',
  '  3. model-purity — domain files import only stdlib, common/, and sibling slice PUBLIC APIs. A domain file importing an HTTP client / ORM / queue is a violation; the fix is a port (Protocol) implemented by an adapter.',
  '  4. growth-justification — every directory/abstraction has 2+ concrete uses. Abstract base with one impl, EventBus with one event, registry with one plugin = premature abstraction.',
  '  5. event-usage — events exist for reverse dependencies (B reacts to A without A knowing B). Cycles between slices must resolve via events, not mutual imports. Events must not be general-purpose messaging.',
  'Also audit general quality: correctness (broken behaviour, silent failures, edge cases), security (tainted input, secrets, unsafe parsing), complexity (long functions, parameter sprawl, redundant state), deslop (dead code, duplicated logic, AI residue), tests (weak assertions, mocked SUT).',
].join('\n')

const SEVERITY_GUIDE = [
  'Severity: blocker = inverted dependency arrow, security hole, or broken behaviour on a main path.',
  'high = cross-slice internal import, circular slice dependency, crust bypass with multiple consumers, real bug.',
  'medium = model-purity drift, premature abstraction, meaningful complexity/dead-code debt.',
  'low = naming, minor deslop, single-consumer crust bypass.',
  'Do NOT manufacture findings — an empty list is a valid outcome. Every finding needs file + line + quoted evidence.',
].join('\n')

// ── schemas ─────────────────────────────────────────────────────────────
const SLICE_MAP_SCHEMA = {
  type: 'object',
  required: ['slices', 'layout'],
  properties: {
    layout: { type: 'string', description: 'one line: how the repo maps (or fails to map) onto sliced-bread' },
    slices: {
      type: 'array',
      items: {
        type: 'object',
        required: ['name', 'path', 'kind'],
        properties: {
          name: { type: 'string' },
          path: { type: 'string' },
          kind: { type: 'string', enum: ['domain', 'app', 'adapter', 'common', 'infra', 'other'] },
          summary: { type: 'string' },
          key_files: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    notes: { type: 'array', items: { type: 'string' } },
  },
}

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['slice', 'findings'],
  properties: {
    slice: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['dimension', 'severity', 'file', 'line', 'claim', 'evidence', 'recommendation'],
        properties: {
          dimension: {
            type: 'string',
            enum: [
              'import-direction', 'crust-integrity', 'model-purity', 'growth-justification',
              'event-usage', 'correctness', 'security', 'complexity', 'deslop', 'tests',
            ],
          },
          severity: { type: 'string', enum: ['blocker', 'high', 'medium', 'low'] },
          file: { type: 'string' },
          line: { type: 'integer' },
          claim: { type: 'string', description: 'one-sentence defect statement' },
          evidence: { type: 'string', description: 'quoted code or command output backing the claim' },
          recommendation: { type: 'string' },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['refuted', 'reasoning'],
  properties: {
    refuted: { type: 'boolean' },
    reasoning: { type: 'string' },
  },
}

const SETUP_SCHEMA = {
  type: 'object',
  required: ['gh_ok'],
  properties: {
    gh_ok: { type: 'boolean' },
    repo: { type: 'string' },
    existing_fingerprints: { type: 'array', items: { type: 'string' } },
    error: { type: 'string' },
  },
}

const CITATION_SCHEMA = {
  type: 'object',
  required: ['results'],
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        required: ['index', 'ok'],
        properties: {
          index: { type: 'integer' },
          ok: { type: 'boolean' },
          reason: { type: 'string' },
        },
      },
    },
  },
}

const BATCH_ISSUE_SCHEMA = {
  type: 'object',
  required: ['results'],
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        required: ['index', 'created'],
        properties: {
          index: { type: 'integer' },
          created: { type: 'boolean' },
          url: { type: 'string' },
          skipped_reason: { type: 'string' },
        },
      },
    },
  },
}

// ── prompt builders ─────────────────────────────────────────────────────
function mapPrompt() {
  return [
    `Map the codebase under \`${SCOPE}\` into Sliced Bread slices.`,
    'A slice is a vertical business-concept module. Look for domains/*/ (one slice each), app/, adapters/, and common/ (or the shared kernel). If the repo does not follow sliced-bread literally, partition by top-level source module and note that in `layout`.',
    'Explore with directory listings and signature-level reads only — do not read every file body. Exclude vendored deps, build output, and lockfiles.',
    'For each slice return name, path (relative), kind, a one-line summary, and up to 5 key files (entry points / index files).',
    'Keep the slice list to what is genuinely auditable: merge micro-dirs (<3 files) into their parent slice.',
  ].join('\n')
}

function setupPrompt() {
  return [
    'GitHub setup for an audit that files issues. Steps:',
    '1. `gh repo view --json nameWithOwner -q .nameWithOwner` — if this fails, return gh_ok=false with the error.',
    DRY_RUN
      ? '2. Dry run — do NOT create labels or mutate anything.'
      : '2. Ensure these labels exist (create quietly if missing, ignore already-exists errors): `sliced-bread-audit`, `sev:blocker`, `sev:high`, `sev:medium`, `sev:low`.',
    '3. List fingerprints from ALL existing audit issues (open AND closed, so closed findings are not re-filed): `gh issue list --label sliced-bread-audit --state all --limit 200 --json body -q \'.[].body\'` piped through `grep -oE \'<!-- sba:[^>]+ -->\'`, then strip the `<!--`/`-->` wrapper from each match. An empty list or a no-such-label error both mean existing_fingerprints=[].',
    'Return gh_ok, repo, existing_fingerprints.',
  ].join('\n')
}

function evalPrompt(item, sliceIndex) {
  const siblings = sliceIndex.filter((s) => s.name !== item.name).map((s) => `${s.name} (${s.path}, ${s.kind})`).join('; ')
  const shared = [
    RUBRIC,
    SEVERITY_GUIDE,
    `Other slices in this codebase (for spotting cross-slice reaches): ${siblings || 'none mapped'}.`,
    'Search and read via the available code tools (tilth via ToolSearch if present, else grep/read). Cite exact file:line for every finding; quote the offending code in `evidence`.',
  ]
  if (item.kind === 'cross-slice') {
    return [
      `Cross-slice dependency audit of \`${SCOPE}\`.`,
      ...shared,
      'Your job is ONLY the whole-graph properties no single-slice reviewer can see:',
      '- circular dependencies between slices (report as event-usage or import-direction),',
      '- systemic dependency-direction inversions,',
      '- common/ importing sibling domains, or common/ hoarding single-slice code,',
      '- crust bypasses counted across consumers (an internal import used from 3 slices is high, not low).',
      'Build the import graph by grepping import/require/use statements across slice roots. Do not re-audit intra-slice quality.',
      `Return slice="cross-slice".`,
    ].join('\n')
  }
  return [
    `Deep audit of the \`${item.name}\` slice at \`${item.path}\` (kind: ${item.kind}).`,
    ...shared,
    `Key files from the slice map: ${(item.key_files || []).join(', ') || 'none listed'}.`,
    'Audit every source file in the slice against the rubric checks that apply to its kind, plus general quality. Read key files fully; signature-read the rest and drill into anything suspicious.',
    `Return slice="${item.name}".`,
  ].join('\n')
}

function citationPrompt(findings) {
  return [
    'Citation check for audit findings. For EACH numbered finding, open the cited file and verify:',
    '(a) the quoted evidence actually appears within ~10 lines of the cited line, and',
    '(b) the path is production source — not test, vendored, generated, or build output.',
    'Return one results entry per finding, using the same 0-based index. ok=false with a short reason when either check fails or the file cannot be read. Do not judge severity or rule choice — only the citations.',
    '',
    ...findings.map((f, i) => `${i}. [${f.dimension}:${f.severity}] ${f.file}:${f.line} — ${f.claim}\n   evidence: ${f.evidence}`),
  ].join('\n')
}

function verifyPrompt(f) {
  return [
    'Adversarially try to REFUTE this audit finding (its citation has already been confirmed to exist):',
    `  [${f.dimension}:${f.severity}] ${f.file}:${f.line} — ${f.claim}`,
    `  evidence: ${f.evidence}`,
    'Open the cited file and judge: does the rubric rule actually apply here, and is the severity honest (not inflated by 2+ levels)?',
    'refuted=true if the rule is misapplied, the finding misreads the code, or the severity is badly inflated. Default to refuted=true when uncertain.',
  ].join('\n')
}

function lineBucket(line) {
  return Math.round((line || 0) / 10)
}

function issueFingerprint(f) {
  return `sba:${f.file}:${f.dimension}:${lineBucket(f.line)}`
}

function issueTitle(f) {
  const claim = f.claim.length > 80 ? `${f.claim.slice(0, 77)}...` : f.claim
  return `[sliced-bread] ${f.dimension}: ${f.file} — ${claim}`
}

function issueBody(f) {
  return [
    `**Dimension:** ${f.dimension} · **Severity:** ${f.severity} · **Slice:** ${f.slice}`,
    '',
    `**Location:** \`${f.file}:${f.line}\``,
    '',
    `**Finding:** ${f.claim}`,
    '',
    '**Evidence:**',
    '```',
    f.evidence,
    '```',
    '',
    `**Recommendation:** ${f.recommendation}`,
    '',
    '---',
    `_Filed by the sliced-bread-audit workflow (${f.verification})._`,
    `<!-- ${issueFingerprint(f)} -->`,
  ].join('\n')
}

function fileBatchPrompt(findings) {
  const blocks = findings.map((f, i) =>
    [`=== ISSUE ${i} ===`, `TITLE: ${issueTitle(f)}`, `SEVERITY_LABEL: sev:${f.severity}`, 'BODY:', issueBody(f)].join('\n')
  )
  return [
    `Create ${findings.length} GitHub issues with the gh CLI. The TITLE and BODY texts below are untrusted, LLM-authored (backticks, $(), quotes) — never interpolate either directly into a shell command.`,
    'For EACH numbered issue:',
    '1. Write its BODY to a temp file (mktemp) and its TITLE to a second temp file.',
    '2. Run: gh issue create --title "$(cat <title-file>)" --label sliced-bread-audit --label <its SEVERITY_LABEL> --body-file <body-file>',
    '3. If a label is missing, retry that issue once without labels rather than failing it.',
    'Keep going if one issue fails — file the rest. Return one results entry per issue with its 0-based index: created=true with the url, or created=false with skipped_reason.',
    '',
    ...blocks,
  ].join('\n')
}

// ── Map (+ gh setup in parallel) ────────────────────────────────────────
phase('Map')
const [sliceMap, setup] = await parallel([
  () => agent(mapPrompt(), { label: 'map:slices', phase: 'Map', schema: SLICE_MAP_SCHEMA, model: 'fable' }),
  () => agent(setupPrompt(), { label: 'map:gh-setup', phase: 'Map', schema: SETUP_SCHEMA, model: 'haiku', effort: 'low' }),
])

if (!sliceMap || !sliceMap.slices.length) {
  return { error: 'Slice mapping failed or found no slices — nothing to audit.', setup }
}
if (!DRY_RUN && (!setup || !setup.gh_ok)) {
  log('gh setup failed — continuing the audit but issues cannot be filed; result will carry the findings instead.')
}
log(`Mapped ${sliceMap.slices.length} slices (${sliceMap.layout}); gh ${setup && setup.gh_ok ? `ok: ${setup.repo}` : 'unavailable'}`)

// ── Evaluate + Verify (pipelined per slice; cross-slice concurrent) ─────
phase('Evaluate')
const budgetExhausted = () => budget.total != null && budget.remaining() <= 0
if (budgetExhausted()) {
  log('Budget exhausted before Evaluate — returning partial report with no slice findings.')
  return {
    scope: SCOPE,
    layout: sliceMap.layout,
    slices: sliceMap.slices.map((s) => s.name),
    raw_findings: 0,
    confirmed: [],
    refuted: [],
    below_floor: [],
    floor_unverified: [],
    issues: [],
    issue_urls: [],
    truncated: 'budget exhausted before Evaluate — no slices were audited',
  }
}

const sortDesc = (fs) => [...fs].sort((a, b) => SEV_RANK[b.severity] - SEV_RANK[a.severity])
const bucketKey = (f) => `${f.file}::${f.dimension}::${lineBucket(f.line)}`
let skippedSlices = 0

// Verify one batch of findings: severity-sorted batch citation-check (one low
// agent), then one adversarial refuter per blocker/high. Mediums and lows ship
// on a confirmed citation alone; budget exhaustion degrades blockers-first.
async function verifyFindings(findings, label) {
  const below = findings.filter((f) => SEV_RANK[f.severity] < SEV_RANK[MIN_SEVERITY])
  const floor = sortDesc(findings.filter((f) => SEV_RANK[f.severity] >= SEV_RANK[MIN_SEVERITY]))
  const out = { confirmed: [], refuted: [], below, unverified: [] }
  if (!floor.length) return out
  if (budgetExhausted()) {
    out.unverified = floor
    return out
  }
  const cite = await agent(citationPrompt(floor), {
    label: `cite:${label}`,
    phase: 'Verify',
    schema: CITATION_SCHEMA,
    model: 'sonnet',
    effort: 'low',
  })
  if (!cite) {
    // Citation agent died — nothing ships unchecked.
    out.unverified = floor
    return out
  }
  const byIndex = new Map((cite.results || []).map((r) => [r.index, r]))
  const cited = []
  floor.forEach((f, i) => {
    const r = byIndex.get(i)
    if (r && r.ok) cited.push(f)
    else out.refuted.push({ ...f, refute_reason: r && r.reason ? `citation: ${r.reason}` : 'citation unconfirmed' })
  })
  out.confirmed.push(
    ...cited.filter((f) => SEV_RANK[f.severity] < SEV_RANK.high).map((f) => ({ ...f, verification: 'citation-checked' }))
  )
  const contested = cited.filter((f) => SEV_RANK[f.severity] >= SEV_RANK.high)
  const votes = await parallel(
    contested.map((f) => async () => {
      if (budgetExhausted()) return { budget_skipped: true }
      return agent(verifyPrompt(f), {
        label: `refute:${f.file}:${f.line}`,
        phase: 'Verify',
        schema: VERDICT_SCHEMA,
        model: 'fable',
        effort: 'high',
      })
    })
  )
  contested.forEach((f, i) => {
    const v = votes[i]
    if (v && v.budget_skipped) out.unverified.push(f)
    else if (!v || v.refuted) {
      // A crashed refuter counts as a refutation: an unconfirmed blocker/high must not ship.
      out.refuted.push({
        ...f,
        refute_reason: v ? `refuter: ${(v.reasoning || '').slice(0, 140)}` : 'refuter crashed (conservative refute)',
      })
    } else out.confirmed.push({ ...f, verification: 'citation-checked + refuter-tested' })
  })
  return out
}

const crossItem = { name: 'cross-slice', path: SCOPE, kind: 'cross-slice' }
const [sliceResults, crossEval] = await parallel([
  () =>
    pipeline(
      sliceMap.slices,
      (s) => {
        if (budgetExhausted()) {
          skippedSlices++
          return null
        }
        return agent(evalPrompt(s, sliceMap.slices), {
          label: `eval:${s.name}`,
          phase: 'Evaluate',
          schema: FINDINGS_SCHEMA,
          model: 'fable',
          effort: 'high',
        })
      },
      (evalRes, s) => {
        if (!evalRes) return null
        const raw = evalRes.findings.map((f) => ({ ...f, slice: evalRes.slice }))
        return verifyFindings(raw, s.name).then((v) => ({ raw, ...v }))
      }
    ),
  () =>
    agent(evalPrompt(crossItem, sliceMap.slices), {
      label: 'eval:cross-slice',
      phase: 'Evaluate',
      schema: FINDINGS_SCHEMA,
      model: 'fable',
      effort: 'high',
    }),
])

const sliceOut = (sliceResults || []).filter(Boolean)
const sliceRaw = sliceOut.flatMap((r) => r.raw)
if (skippedSlices) log(`Budget exhausted mid-Evaluate — ${skippedSlices} slices not audited.`)

// Cross-slice findings: keep only those strictly more severe than every slice
// finding in the same bucket (the File-stage fingerprint dedupe keeps the
// higher-severity duplicate, so nothing is lost by dropping the rest here).
const bucketBest = new Map()
for (const f of sliceRaw) {
  const k = bucketKey(f)
  bucketBest.set(k, Math.max(bucketBest.get(k) ?? -1, SEV_RANK[f.severity]))
}
const crossRaw = crossEval ? crossEval.findings.map((f) => ({ ...f, slice: 'cross-slice' })) : []
const crossFresh = crossRaw.filter((f) => (bucketBest.get(bucketKey(f)) ?? -1) < SEV_RANK[f.severity])
const crossVerified = await verifyFindings(crossFresh, 'cross-slice')

const confirmedAll = sortDesc([...sliceOut.flatMap((r) => r.confirmed), ...crossVerified.confirmed])
const refutedAll = [...sliceOut.flatMap((r) => r.refuted), ...crossVerified.refuted]
const belowAll = [...sliceOut.flatMap((r) => r.below), ...crossVerified.below]
const unverifiedAll = [...sliceOut.flatMap((r) => r.unverified), ...crossVerified.unverified]
log(
  `${sliceRaw.length + crossRaw.length} raw findings → ${confirmedAll.length} confirmed, ${refutedAll.length} refuted, ${unverifiedAll.length} unverified, ${belowAll.length} below floor`
)

// ── File issues ─────────────────────────────────────────────────────────
phase('File')
// Intra-run fingerprint dedupe (slice × slice collisions): confirmedAll is
// severity-sorted, so first-seen keeps the highest severity.
const fpSeen = new Set()
const uniqueConfirmed = confirmedAll.filter((f) => {
  const fp = issueFingerprint(f)
  if (fpSeen.has(fp)) return false
  fpSeen.add(fp)
  return true
})
const existing = new Set(((setup && setup.existing_fingerprints) || []).map((t) => t.trim()))
const fresh = uniqueConfirmed.filter((f) => !existing.has(issueFingerprint(f)))
const dupes = uniqueConfirmed.length - fresh.length
const toFile = fresh.slice(0, MAX_ISSUES)
if (fresh.length > MAX_ISSUES) log(`Capping at ${MAX_ISSUES} issues — ${fresh.length - MAX_ISSUES} confirmed findings NOT filed (in the returned report)`)
if (dupes) log(`${dupes} findings skipped — a matching audit issue (any state) already exists`)

const FILE_CHUNK = 10
let issues = []
if (DRY_RUN) {
  log(`Dry run — would file ${toFile.length} issues`)
  issues = toFile.map((f) => ({ created: false, title: issueTitle(f), skipped_reason: 'dry_run' }))
} else if (!setup || !setup.gh_ok) {
  issues = toFile.map((f) => ({ created: false, title: issueTitle(f), skipped_reason: 'gh unavailable' }))
} else if (toFile.length) {
  const chunks = []
  for (let i = 0; i < toFile.length; i += FILE_CHUNK) chunks.push(toFile.slice(i, i + FILE_CHUNK))
  const batches = await parallel(
    chunks.map((c, ci) => () =>
      agent(fileBatchPrompt(c), { label: `issues:batch-${ci + 1}`, phase: 'File', schema: BATCH_ISSUE_SCHEMA, model: 'haiku', effort: 'low' })
    )
  )
  // Iterate the chunk, not the agent's results array, so a partial results
  // array cannot silently drop findings from the Filed X/Y accounting.
  issues = batches.flatMap((b, ci) =>
    chunks[ci].map((f, fi) => {
      const r = b && (b.results || []).find((x) => x.index === fi)
      if (!r) return { created: false, title: issueTitle(f), skipped_reason: b ? 'no result from filing agent' : 'filing agent failed' }
      return { created: r.created === true, url: r.url, title: issueTitle(f), skipped_reason: r.skipped_reason }
    })
  )
}

const filed = issues.filter((i) => i.created)
log(`Filed ${filed.length}/${toFile.length} issues${DRY_RUN ? ' (dry run)' : ''}`)

return {
  scope: SCOPE,
  layout: sliceMap.layout,
  slices: sliceMap.slices.map((s) => s.name),
  raw_findings: sliceRaw.length + crossRaw.length,
  confirmed: uniqueConfirmed.map((f) => ({
    severity: f.severity, dimension: f.dimension, slice: f.slice, verification: f.verification,
    location: `${f.file}:${f.line}`, claim: f.claim, recommendation: f.recommendation,
  })),
  refuted: refutedAll.map((f) => `${f.file}:${f.line} — ${f.claim} (${f.refute_reason})`),
  below_floor: belowAll.map((f) => `[${f.severity}] ${f.file}:${f.line} — ${f.claim}`),
  floor_unverified: unverifiedAll.map((f) => `[${f.severity}] ${f.file}:${f.line} — ${f.claim}`),
  issues,
  issue_urls: filed.map((i) => i.url),
  ...(skippedSlices ? { truncated: `budget exhausted — ${skippedSlices} slices were not audited` } : {}),
}
