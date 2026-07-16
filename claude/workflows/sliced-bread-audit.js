
export const meta = {
  name: 'sliced-bread-audit',
  description:
    'Deep slice-by-slice audit of a Sliced Bread codebase: map the slices, fan out one fable evaluator per slice plus a cross-slice dependency pass, adversarially verify every finding by 3-vote refutation, and open one labeled GitHub issue per confirmed finding.',
  whenToUse:
    'Audit a repo (or subtree) against Sliced Bread architecture and code quality with findings landing as GitHub issues. Requires gh auth in the target repo. Pass {dry_run: true} to preview without filing issues.',
  phases: [
    { title: 'Map', detail: 'discover slices; in parallel, gh setup (labels + existing audit issues)' },
    { title: 'Evaluate', detail: 'one fable evaluator per slice + one cross-slice dependency pass', model: 'fable' },
    { title: 'Verify', detail: '3 adversarial fable refuters per floor-meeting finding, majority vote', model: 'fable' },
    { title: 'File', detail: 'dedupe against existing issues, cap, open one gh issue per confirmed finding' },
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
const MAX_ISSUES = Number.isFinite(opts.max_issues) ? opts.max_issues : 25

const SEV_RANK = { blocker: 3, high: 2, medium: 1, low: 0 }
if (!(MIN_SEVERITY in SEV_RANK)) {
  return { error: `min_severity must be one of blocker|high|medium|low, got: ${MIN_SEVERITY}` }
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

const ISSUE_SCHEMA = {
  type: 'object',
  required: ['created'],
  properties: {
    created: { type: 'boolean' },
    url: { type: 'string' },
    title: { type: 'string' },
    skipped_reason: { type: 'string' },
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
    'Audit every source file in the slice against the rubric checks that apply to its kind, plus general quality. Read key files fully; signature-read the rest and drill into anything suspicious.',
    `Return slice="${item.name}".`,
  ].join('\n')
}

function verifyPrompt(f, lens) {
  return [
    `Adversarially try to REFUTE this audit finding through the ${lens} lens:`,
    `  [${f.dimension}:${f.severity}] ${f.file}:${f.line} — ${f.claim}`,
    `  evidence: ${f.evidence}`,
    'Open the cited file yourself and check the evidence is real, the rule actually applies, and the severity is not inflated by 2+ levels.',
    'refuted=true if the evidence does not hold, the rule is misapplied, the code is test/vendored/generated, or you cannot confirm the citation. Default to refuted=true when uncertain.',
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
    '_Filed by the sliced-bread-audit workflow (3-vote adversarially verified)._',
    `<!-- ${issueFingerprint(f)} -->`,
  ].join('\n')
}

function filePrompt(f) {
  return [
    'Create one GitHub issue with the gh CLI. The BODY and TITLE below may contain untrusted, LLM-authored text (backticks, $(), quotes) — do not interpolate either directly into a shell command:',
    '1. Write the BODY text to a temp file (e.g. via `mktemp`), then pass it with `--body-file <path>` — never inline the body in the command or a heredoc.',
    '2. Pass the TITLE as a single-quoted `--title` argument, escaping any embedded single quotes.',
    `gh issue create --title '<escaped title>' --label sliced-bread-audit --label sev:${f.severity} --body-file <path-to-temp-file>`,
    '3. If a label is missing, retry once without labels rather than failing.',
    '',
    `TITLE: ${issueTitle(f)}`,
    'BODY:',
    issueBody(f),
    '',
    'Return created=true with the issue url, or created=false with skipped_reason.',
  ].join('\n')
}

// ── Map (+ gh setup in parallel) ────────────────────────────────────────
phase('Map')
const [sliceMap, setup] = await parallel([
  () => agent(mapPrompt(), { label: 'map:slices', phase: 'Map', schema: SLICE_MAP_SCHEMA, model: 'fable' }),
  () => agent(setupPrompt(), { label: 'map:gh-setup', phase: 'Map', schema: SETUP_SCHEMA, effort: 'low' }),
])

if (!sliceMap || !sliceMap.slices.length) {
  return { error: 'Slice mapping failed or found no slices — nothing to audit.', setup }
}
if (!DRY_RUN && (!setup || !setup.gh_ok)) {
  log('gh setup failed — continuing the audit but issues cannot be filed; result will carry the findings instead.')
}
log(`Mapped ${sliceMap.slices.length} slices (${sliceMap.layout}); gh ${setup && setup.gh_ok ? `ok: ${setup.repo}` : 'unavailable'}`)

// ── Evaluate (barrier: dedupe needs ALL findings before verification) ───
phase('Evaluate')
if (budget.total != null && budget.remaining() <= 0) {
  log('Budget exhausted before Evaluate — returning partial report with no slice findings.')
  return {
    scope: SCOPE,
    layout: sliceMap.layout,
    slices: sliceMap.slices.map((s) => s.name),
    raw_findings: 0,
    confirmed: [],
    refuted: [],
    below_floor: [],
    issues: [],
    issue_urls: [],
    truncated: 'budget exhausted before Evaluate — no slices were audited',
  }
}
const items = [...sliceMap.slices, { name: 'cross-slice', path: SCOPE, kind: 'cross-slice' }]
const evalResults = await parallel(
  items.map((it) => () =>
    agent(evalPrompt(it, sliceMap.slices), {
      label: `eval:${it.name}`,
      phase: 'Evaluate',
      schema: FINDINGS_SCHEMA,
      model: 'fable',
      effort: 'high',
    })
  )
)

const allFindings = evalResults
  .filter(Boolean)
  .flatMap((r) => r.findings.map((f) => ({ ...f, slice: r.slice })))

// Dedupe (same defect flagged by a slice pass AND the cross-slice pass):
// bucket by file + dimension + ~10-line window, keep the highest severity.
const bySeverity = [...allFindings].sort((a, b) => SEV_RANK[b.severity] - SEV_RANK[a.severity])
const seen = new Set()
const deduped = []
for (const f of bySeverity) {
  const key = `${f.file}::${f.dimension}::${lineBucket(f.line)}`
  if (seen.has(key)) continue
  seen.add(key)
  deduped.push(f)
}
const floorMet = deduped.filter((f) => SEV_RANK[f.severity] >= SEV_RANK[MIN_SEVERITY])
const belowFloor = deduped.length - floorMet.length
log(`${allFindings.length} raw findings → ${deduped.length} after dedupe; verifying ${floorMet.length} at ${MIN_SEVERITY}+ (${belowFloor} below floor recorded, not verified)`)

// ── Verify: 3 diverse-lens refuters per finding, majority survives ──────
phase('Verify')
if (budget.total != null && budget.remaining() <= 0) {
  log(`Budget exhausted before Verify — returning partial report; ${floorMet.length} floor-meeting findings excluded as unverified.`)
  return {
    scope: SCOPE,
    layout: sliceMap.layout,
    slices: sliceMap.slices.map((s) => s.name),
    raw_findings: allFindings.length,
    confirmed: [],
    refuted: [],
    below_floor: deduped.map((f) => `[${f.severity}] ${f.file}:${f.line} — ${f.claim}`),
    issues: [],
    issue_urls: [],
    truncated: `budget exhausted before Verify — ${floorMet.length} findings met the severity floor but were not adversarially verified`,
  }
}
const LENSES = ['evidence-accuracy', 'rule-applicability', 'severity-calibration']
const verified = await parallel(
  floorMet.map((f) => () =>
    parallel(
      LENSES.map((lens) => () =>
        agent(verifyPrompt(f, lens), {
          label: `verify:${f.file}:${f.line}`,
          phase: 'Verify',
          schema: VERDICT_SCHEMA,
          model: 'fable',
        })
      )
    ).then((votes) => {
      const live = votes.filter(Boolean)
      const refutations = live.filter((v) => v.refuted).length
      // Missing votes count as refutations: an unconfirmed finding must not ship.
      const survives = live.length - refutations >= 2
      return { ...f, survives, refutations: refutations + (LENSES.length - live.length) }
    })
  )
)
const confirmed = verified
  .filter(Boolean)
  .filter((f) => f.survives)
  .sort((a, b) => SEV_RANK[b.severity] - SEV_RANK[a.severity])
const refuted = verified.filter(Boolean).filter((f) => !f.survives)
log(`${confirmed.length} findings confirmed, ${refuted.length} refuted`)

// ── File issues ─────────────────────────────────────────────────────────
phase('File')
const existing = new Set(((setup && setup.existing_fingerprints) || []).map((t) => t.trim()))
const fresh = confirmed.filter((f) => !existing.has(issueFingerprint(f)))
const dupes = confirmed.length - fresh.length
const toFile = fresh.slice(0, MAX_ISSUES)
if (fresh.length > MAX_ISSUES) log(`Capping at ${MAX_ISSUES} issues — ${fresh.length - MAX_ISSUES} confirmed findings NOT filed (in the returned report)`)
if (dupes) log(`${dupes} findings skipped — a matching audit issue (any state) already exists`)

let issues = []
if (DRY_RUN) {
  log(`Dry run — would file ${toFile.length} issues`)
  issues = toFile.map((f) => ({ created: false, title: issueTitle(f), skipped_reason: 'dry_run' }))
} else if (!setup || !setup.gh_ok) {
  issues = toFile.map((f) => ({ created: false, title: issueTitle(f), skipped_reason: 'gh unavailable' }))
} else {
  issues = await parallel(
    toFile.map((f) => () =>
      agent(filePrompt(f), { label: `issue:${f.file}`, phase: 'File', schema: ISSUE_SCHEMA, effort: 'low' })
    )
  )
  issues = issues.filter(Boolean)
}

const filed = issues.filter((i) => i.created)
log(`Filed ${filed.length}/${toFile.length} issues${DRY_RUN ? ' (dry run)' : ''}`)

return {
  scope: SCOPE,
  layout: sliceMap.layout,
  slices: sliceMap.slices.map((s) => s.name),
  raw_findings: allFindings.length,
  confirmed: confirmed.map((f) => ({
    severity: f.severity, dimension: f.dimension, slice: f.slice,
    location: `${f.file}:${f.line}`, claim: f.claim, recommendation: f.recommendation,
  })),
  refuted: refuted.map((f) => `${f.file}:${f.line} — ${f.claim}`),
  below_floor: deduped
    .filter((f) => SEV_RANK[f.severity] < SEV_RANK[MIN_SEVERITY])
    .map((f) => `[${f.severity}] ${f.file}:${f.line} — ${f.claim}`),
  issues,
  issue_urls: filed.map((i) => i.url),
}
