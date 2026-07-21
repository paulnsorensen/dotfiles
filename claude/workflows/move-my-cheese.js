export const meta = {
  name: 'move-my-cheese',
  description:
    'PR rescue fan-out: recon open PRs, restack via /plate (+/melt on conflicts), fix CI, then a token-efficient incremental /age — if a PR was already aged, only the changes since the recorded marker are reviewed — cure medium+ findings, push, and stamp the aged marker.',
  phases: [
    { title: 'Discover', detail: 'haiku lists open PRs when none are given; workflow returns candidates with no further dispatch' },
    { title: 'Recon', detail: 'one haiku batch agent builds the manifest: merge state, CI, head sha, aged-marker sha/patch-id per PR' },
    { title: 'Rescue', detail: 'sonnet coder per PR in an isolated worktree: /plate restack (+/melt on conflicts), fix real CI failures, commit' },
    { title: 'Age', detail: 'opus reviewer: skip if diff patch-id unchanged since last age; incremental <aged-sha>..HEAD when ancestor; else full /age vs base' },
    { title: 'Cure', detail: 'sonnet coder runs /cure --auto --stake medium+ only when age reports medium+ findings' },
    { title: 'Re-age', detail: 'opus reviewer re-checks once after cure; still medium+ marks the PR dirty' },
    { title: 'Finalize', detail: 'haiku pushes to the PR branch (never force), upserts the aged-marker comment, re-runs infra-flake CI' },
    { title: 'Report', detail: 'per-PR status: fresh | clean | dirty | failed | skipped, with unresolved-thread counts for /affinage' },
  ],
}

// Tracked source: claude/workflows/move-my-cheese.js in the dotfiles repo.
// Modern descendant of archive/claude-commands/{move-my-cheese,cheese-convoy}.md:
// convoy's parallel dispatch + move-my-cheese's per-PR rescue, minus convoy's
// combine/consolidate phases (dropped by design — workflows cannot pause for a
// mid-run approval gate). Restacking is delegated to /plate, conflict melting
// to /melt, review to /age, fixes to /cure.
//
// Args: { prs?: number[] | number | string, all?: boolean, includeDrafts?: boolean }
//   - no prs: Discover lists open PRs (authored by me unless all:true) and the
//     workflow returns them as candidates, dispatching no further agent.
//   - prs given: rescue exactly those.
//
// Incremental aging: each aged PR carries one marker comment
//   <!-- move-my-cheese:aged sha=<head-sha> patch=<patch-id> dirty=<0|1> -->
// Recon reads it; Age compares the current full-diff patch-id (git diff
// origin/<base>...HEAD | git patch-id --stable) against the marker:
//   marker dirty=1           -> full /age (skip/incremental would hide the
//                               unresolved medium+ findings; a dirty head is
//                               also never triaged as fresh)
//   same patch-id            -> skip aging entirely (restack-only changes)
//   marker sha ancestor HEAD -> incremental /age <sha>..HEAD
//   otherwise                -> full /age origin/<base>...HEAD
// Finalize re-stamps the marker at the pushed HEAD with the chain's verdict.

const NO_CHAIN_DIRECTIVE = 'Do not chain forward to the next phase even though your auto-mode contract documents that. Write your handoff slug and stop. The move-my-cheese orchestrator is driving the chain. Run in the foreground — do not background yourself, spawn detached processes, or defer work to a later session. If you cannot complete the phase within your context window, write a partial slug with status: halt: <reason> and stop; do not silently timeout.'

const MARKER_PREFIX = 'move-my-cheese:aged'

// PR branch/base names are interpolated into agent prompts that contain shell
// commands — reject anything that is not a plain git-ref shape before dispatch.
const SAFE_REF_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/
const isSafeRef = (ref) => typeof ref === 'string' && SAFE_REF_RE.test(ref) && !ref.includes('..')

const parsed = typeof args === 'string'
  ? (() => { try { return JSON.parse(args) } catch { return args } })()
  : args
const input = parsed == null ? {}
  : (typeof parsed === 'object' && !Array.isArray(parsed)) ? parsed
    : { prs: parsed }

const rawPrs = input.prs ?? input.pr ?? null
let PRS = []
if (Array.isArray(rawPrs)) PRS = rawPrs.map(Number)
else if (typeof rawPrs === 'number') PRS = [rawPrs]
else if (typeof rawPrs === 'string') PRS = rawPrs.split(/[\s,]+/).filter(Boolean).map(Number)
if (PRS.some((n) => !Number.isInteger(n) || n <= 0)) {
  return { error: `Invalid PR number(s) in args: ${JSON.stringify(rawPrs)} — expected positive integers` }
}
const ALL_AUTHORS = input.all === true
const INCLUDE_DRAFTS = input.includeDrafts === true

// ---- schemas ----
const DISCOVER_SCHEMA = {
  type: 'object',
  required: ['prs'],
  properties: {
    prs: {
      type: 'array',
      items: {
        type: 'object',
        required: ['number', 'title', 'branch'],
        properties: {
          number: { type: 'integer' },
          title: { type: 'string' },
          branch: { type: 'string' },
          updated_at: { type: 'string' },
        },
      },
    },
  },
}

const RECON_SCHEMA = {
  type: 'object',
  required: ['prs'],
  properties: {
    prs: {
      type: 'array',
      items: {
        type: 'object',
        required: ['number', 'branch', 'base', 'state', 'is_draft', 'merge_state', 'ci', 'head_sha'],
        properties: {
          number: { type: 'integer' },
          title: { type: 'string' },
          branch: { type: 'string' },
          base: { type: 'string' },
          state: { type: 'string', description: 'OPEN | CLOSED | MERGED' },
          is_draft: { type: 'boolean' },
          merge_state: { type: 'string', description: 'gh mergeStateStatus: CLEAN | DIRTY | BEHIND | BLOCKED | UNSTABLE | UNKNOWN | ...' },
          ci: { type: 'string', enum: ['pass', 'fail', 'pending', 'none'] },
          failing_run_ids: { type: 'array', items: { type: 'integer' } },
          head_sha: { type: 'string' },
          aged_sha: { type: 'string', description: 'sha= from the move-my-cheese:aged marker comment, empty if none' },
          aged_patch: { type: 'string', description: 'patch= from the marker comment, empty if none' },
          aged_dirty: { type: 'boolean', description: 'dirty=1 in the marker comment — the last age left unresolved medium+ findings; false if absent' },
          unresolved_threads: { type: 'integer' },
          url: { type: 'string' },
        },
      },
    },
  },
}

const RESCUE_SCHEMA = {
  type: 'object',
  required: ['status', 'worktree_path'],
  properties: {
    status: { type: 'string', enum: ['ok', 'partial', 'blocked'] },
    worktree_path: { type: 'string' },
    restacked: { type: 'boolean' },
    melted: { type: 'boolean' },
    fixes: { type: 'array', items: { type: 'string' } },
    infra_flake_run_ids: { type: 'array', items: { type: 'integer' } },
    committed: { type: 'boolean' },
  },
}

const AGE_SCHEMA = {
  type: 'object',
  required: ['status', 'mode', 'worktree_path', 'has_medium_plus_findings'],
  properties: {
    status: { type: 'string' },
    mode: { type: 'string', enum: ['skipped-unchanged', 'incremental', 'full'] },
    scope: { type: 'string', description: 'the exact ref-range /age reviewed, e.g. abc123..HEAD' },
    slug: { type: 'string', description: 'the /age handoff slug, needed by /cure' },
    artifact: { type: 'string' },
    worktree_path: { type: 'string' },
    has_medium_plus_findings: { type: 'boolean' },
  },
}

const CURE_SCHEMA = {
  type: 'object',
  required: ['status', 'committed'],
  properties: { status: { type: 'string' }, artifact: { type: 'string' }, committed: { type: 'boolean' } },
}

const FINALIZE_SCHEMA = {
  type: 'object',
  required: ['pushed', 'head_sha'],
  properties: {
    pushed: { type: 'boolean' },
    head_sha: { type: 'string' },
    marker_updated: { type: 'boolean' },
    reruns_triggered: { type: 'array', items: { type: 'integer' } },
  },
}

// ---- prompts ----
function discoverPrompt() {
  return `You are a cheap discovery agent for the move-my-cheese workflow. Use Bash.

List open PRs for the current repo: \`gh pr list --state open ${ALL_AUTHORS ? '' : '--author @me '}--json number,title,headRefName,isDraft,updatedAt\`.

Filter out: ${INCLUDE_DRAFTS ? '' : 'draft PRs, '}PRs with "WIP" in the title.

Return {"prs":[{"number":<n>,"title":"...","branch":"<headRefName>","updated_at":"..."}, ...]} — nothing else.`
}

function reconPrompt(prNumbers) {
  return `You are a cheap batch-recon agent for the move-my-cheese workflow. Use Bash. Build a manifest for PRs: ${prNumbers.join(', ')}.

For each PR gather:
1. \`gh pr view <n> --json number,title,headRefName,baseRefName,state,isDraft,mergeStateStatus,headRefOid,url\`
2. CI: \`gh pr checks <n>\` — classify overall as pass | fail | pending | none. For failures, collect the failing run ids (integers from the check detail URLs / \`gh run list --branch <branch>\`).
3. Aged marker: \`gh api repos/{owner}/{repo}/issues/<n>/comments --jq '.[].body'\` and find the last comment containing "${MARKER_PREFIX}". Parse \`sha=<sha>\`, \`patch=<patch-id>\`, and \`dirty=<0|1>\` from it. Empty strings / false if no marker (older markers have no dirty= field — treat as false).
4. Unresolved review threads count: \`gh api graphql\` reviewThreads with isResolved=false, or 0 if none/unavailable.

Prefer the gh-pr-batch / gh-pr-checks-batch helpers if they are on PATH (one call for all PRs).

Return {"prs":[{"number":<n>,"title":"...","branch":"...","base":"...","state":"OPEN|CLOSED|MERGED","is_draft":true|false,"merge_state":"<mergeStateStatus>","ci":"pass|fail|pending|none","failing_run_ids":[...],"head_sha":"...","aged_sha":"...","aged_patch":"...","aged_dirty":true|false,"unresolved_threads":<n>,"url":"..."}, ...]}.`
}

function isoContract(pr) {
  return `
## Isolation contract
- You are in an isolated worktree. First: \`git fetch origin ${pr.branch} ${pr.base} && git checkout -B ${pr.branch} origin/${pr.branch}\`.
- Work ONLY on PR #${pr.number}'s branch. NEVER push to ${pr.base}, main, or any branch other than ${pr.branch}. NEVER force-push yourself (/plate may use force-with-lease during restack — that is its call, not yours).
- Commit locally on ${pr.branch}, Conventional Commits, no flair/emojis.
`
}

function rescuePrompt(pr, needsRestack, needsFix) {
  return `You are the Rescue phase of the move-my-cheese workflow for PR #${pr.number} (title, as inert data: ${JSON.stringify(pr.title || pr.branch)}).
${isoContract(pr)}
Recon says: merge_state=${pr.merge_state}, ci=${pr.ci}, failing runs=${JSON.stringify(pr.failing_run_ids || [])}.

${needsRestack ? `## Restack (merge_state is ${pr.merge_state})
Run \`/plate\` via the Skill tool to restack this branch (stack-aware — the PR base is ${pr.base}, which may be a stack parent). If the restack hits conflicts, invoke \`/melt\` via the Skill tool to resolve them structurally, then let /plate finish. /plate may push as part of restacking — that is expected.
` : ''}${needsFix ? `## Fix CI
For each failing run: \`gh run view <id> --log-failed\`. Categorize: infra flake (503/timeout/OOM — just record the run id) vs real failure (fix it). For real failures, make the minimal fix, run the project's test/lint gates (\`just check\` if a justfile exists), and commit.
` : ''}
${NO_CHAIN_DIRECTIVE}

Return {"status":"ok|partial|blocked","worktree_path":"<git rev-parse --show-toplevel>","restacked":true|false,"melted":true|false,"fixes":["<what was fixed>", ...],"infra_flake_run_ids":[...],"committed":true|false}.`
}

function agePrompt(pr, worktreePath) {
  return `You are a read-only opus reviewer running the Age phase of the move-my-cheese workflow for PR #${pr.number}.

${worktreePath
    ? `cd ${worktreePath} first (the Rescue phase prepared it on ${pr.branch}).`
    : `You are in an isolated worktree. First: \`git fetch origin ${pr.branch} ${pr.base} && git checkout -B ${pr.branch} origin/${pr.branch}\`. Do not edit or push anything.`}

## Token-efficient scope decision (do this BEFORE invoking /age)
Last aged marker: sha=${JSON.stringify(pr.aged_sha || '')}, patch=${JSON.stringify(pr.aged_patch || '')}, dirty=${pr.aged_dirty ? '1' : '0'}.
${pr.aged_dirty
    ? `The previous age left unresolved medium+ findings (dirty=1) — do NOT skip and do NOT scope incrementally, or those findings would never resurface. Run full: \`/age origin/${pr.base}...HEAD --auto\` via the Skill tool. Mode "full".`
    : `1. Compute the current full-diff patch-id: \`git diff origin/${pr.base}...HEAD | git patch-id --stable | cut -d' ' -f1\`.
2. If it equals the marker patch-id → the reviewable content is unchanged since the last age (e.g. restack only). Do NOT invoke /age. Return mode "skipped-unchanged" with has_medium_plus_findings false.
3. Else if the marker sha is non-empty and \`git merge-base --is-ancestor ${pr.aged_sha || '<sha>'} HEAD\` succeeds → incremental: run \`/age ${pr.aged_sha || '<sha>'}..HEAD --auto\` via the Skill tool. Mode "incremental".
4. Else → full: run \`/age origin/${pr.base}...HEAD --auto\` via the Skill tool. Mode "full".`}

${NO_CHAIN_DIRECTIVE} In particular: do NOT invoke /cure yourself even if /age --auto documents that chain.

Read the resulting age report and determine whether any finding is medium severity or above. Return {"status":"ok","mode":"skipped-unchanged|incremental|full","scope":"<exact ref-range reviewed, empty if skipped>","slug":"<age handoff slug, empty if skipped>","artifact":"<.cheese/age/... path, empty if skipped>","worktree_path":"<git rev-parse --show-toplevel>","has_medium_plus_findings":true|false}.`
}

function curePrompt(pr, worktreePath, ageResult) {
  return `You are the Cure phase of the move-my-cheese workflow for PR #${pr.number}. cd ${worktreePath} first (branch ${pr.branch}).

Run \`/cure ${ageResult.slug} --auto --stake medium+\` via the Skill tool to apply the medium+ findings from the age report at ${ageResult.artifact}.

Commit locally on ${pr.branch}. Do NOT push — the Finalize phase pushes. ${NO_CHAIN_DIRECTIVE}

Return {"status":"ok|partial|blocked","artifact":"...","committed":true|false}.`
}

function reagePrompt(pr, worktreePath, scope) {
  return `You are a read-only opus reviewer running the Re-age phase of the move-my-cheese workflow for PR #${pr.number}, after a cure pass. cd ${worktreePath} first.

Run \`/age ${scope} --auto\` via the Skill tool (same scope the Age phase reviewed; HEAD now includes the cure commits).

${NO_CHAIN_DIRECTIVE} In particular: do NOT invoke /cure yourself.

Read the resulting age report. Return {"status":"ok","mode":"incremental","scope":${JSON.stringify(scope)},"slug":"<age handoff slug>","artifact":"...","worktree_path":"<git rev-parse --show-toplevel>","has_medium_plus_findings":true|false}.`
}

function isDirtyChain({ age, cure, reage }) {
  if (!age) return false
  if (reage) return reage.has_medium_plus_findings === true
  return age.has_medium_plus_findings === true && !(cure && cure.committed)
}

function finalizePrompt(pr, worktreePath, infraFlakeRunIds, isDirty) {
  return `You are the cheap Finalize phase of the move-my-cheese workflow for PR #${pr.number}. Use Bash. cd ${worktreePath} first (branch ${pr.branch}).

1. Push if ahead: \`git fetch origin ${pr.branch}\`; if HEAD has commits not on origin/${pr.branch}, \`git push origin HEAD:${pr.branch}\` (plain push — NEVER force, NEVER another branch).
2. Upsert the aged marker comment on the PR:
   - sha: \`git rev-parse HEAD\`
   - patch: \`git diff origin/${pr.base}...HEAD | git patch-id --stable | cut -d' ' -f1\` (fetch origin/${pr.base} first)
   - body: \`<!-- ${MARKER_PREFIX} sha=<sha> patch=<patch> dirty=${isDirty ? 1 : 0} -->\` followed by a one-line human note ("move-my-cheese: aged at <sha short>${isDirty ? ', medium+ findings remain' : ''}").
   - Find an existing comment containing "${MARKER_PREFIX}" via \`gh api repos/{owner}/{repo}/issues/${pr.number}/comments\`; PATCH it if found (\`gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id> -f body=...\`), else \`gh pr comment ${pr.number} --body ...\`.
3. Re-run infra-flake CI runs: ${JSON.stringify(infraFlakeRunIds)} — for each: \`gh run rerun <id> --failed\`.

Return {"pushed":true|false,"head_sha":"...","marker_updated":true|false,"reruns_triggered":[...]}.`
}

// ---- Discover ----
if (!PRS.length) {
  phase('Discover')
  const discovered = await agent(discoverPrompt(), { label: 'discover', phase: 'Discover', model: 'haiku', schema: DISCOVER_SCHEMA })
  log(`No PRs given — ${discovered.prs.length} open candidate(s) found.`)
  return { candidates: discovered.prs, usage: 'Re-invoke with { prs: [<numbers>] } to rescue.' }
}

// ---- Recon ----
phase('Recon')
if (PRS.length > 5) log(`Rescuing ${PRS.length} PRs — that is a lot of parallel worktree agents; consider batching.`)
const recon = await agent(reconPrompt(PRS), { label: 'recon', phase: 'Recon', model: 'haiku', schema: RECON_SCHEMA })

const manifest = new Map(recon.prs.map((p) => [p.number, p]))
const missing = PRS.filter((n) => !manifest.has(n))
if (missing.length) log(`Recon returned no data for PR(s): ${missing.join(', ')} — reporting them as failed.`)

// ---- JS triage ----
const skipped = []
const fresh = []
const dispatch = []
for (const n of PRS) {
  const pr = manifest.get(n)
  if (!pr) { skipped.push({ number: n, status: 'failed', reason: 'recon returned no data' }); continue }
  if (!isSafeRef(pr.branch) || !isSafeRef(pr.base)) { skipped.push({ number: n, status: 'skipped', reason: `unsafe branch/base ref name: ${JSON.stringify({ branch: pr.branch, base: pr.base })}` }); continue }
  const mergeState = (pr.merge_state || '').toUpperCase()
  if (pr.state !== 'OPEN') { skipped.push({ number: n, status: 'skipped', reason: `state is ${pr.state}` }); continue }
  if (pr.is_draft && !INCLUDE_DRAFTS) { skipped.push({ number: n, status: 'skipped', reason: 'draft (pass includeDrafts:true to include)' }); continue }
  if (mergeState === 'BLOCKED') { skipped.push({ number: n, status: 'skipped', reason: 'merge state BLOCKED — needs a human decision' }); continue }
  if (pr.ci === 'pass' && mergeState === 'CLEAN' && pr.aged_sha && pr.aged_sha === pr.head_sha && !pr.aged_dirty) {
    fresh.push({ number: n, status: 'fresh', reason: 'CI green, mergeable, head already aged' })
    continue
  }
  dispatch.push({
    ...pr,
    needsRestack: mergeState === 'DIRTY' || mergeState === 'BEHIND',
    needsFix: pr.ci === 'fail',
  })
}

log(`Triage: ${dispatch.length} to rescue, ${fresh.length} fresh, ${skipped.length} skipped.`)

// ---- Per-PR chain (pipelined) ----
let chainResults = []
if (dispatch.length) {
  phase('Rescue')
  chainResults = await pipeline(
    dispatch,

    // Rescue — only when restack/fix is needed; otherwise skip straight to Age.
    async (pr) => {
      if (!pr.needsRestack && !pr.needsFix) return { pr, rescue: null, failure: null }
      try {
        const rescue = await agent(rescuePrompt(pr, pr.needsRestack, pr.needsFix), { label: `rescue:${pr.number}`, phase: 'Rescue', agentType: 'coder', isolation: 'worktree', model: 'sonnet', schema: RESCUE_SCHEMA })
        if (rescue.status === 'blocked') return { pr, rescue, failure: { stage: 'rescue', message: 'rescue reported blocked' } }
        return { pr, rescue, failure: null }
      } catch (e) {
        return { pr, rescue: null, failure: { stage: 'rescue', message: e.message } }
      }
    },

    // Age — incremental when the marker allows it.
    async ({ pr, rescue, failure }) => {
      if (failure) return { pr, rescue, age: null, failure }
      const worktreePath = rescue ? rescue.worktree_path : null
      try {
        const age = await agent(agePrompt(pr, worktreePath), {
          label: `age:${pr.number}`,
          phase: 'Age',
          agentType: 'reviewer',
          model: 'opus',
          schema: AGE_SCHEMA,
          ...(worktreePath ? {} : { isolation: 'worktree' }),
        })
        return { pr, rescue, age, failure: null }
      } catch (e) {
        return { pr, rescue, age: null, failure: { stage: 'age', message: e.message } }
      }
    },

    // Cure + Re-age — only when age found medium+.
    async ({ pr, rescue, age, failure }) => {
      if (failure) return { pr, rescue, age, cure: null, reage: null, failure }
      if (!age.has_medium_plus_findings) return { pr, rescue, age, cure: null, reage: null, failure: null }
      let cure
      try {
        cure = await agent(curePrompt(pr, age.worktree_path, age), { label: `cure:${pr.number}`, phase: 'Cure', agentType: 'coder', model: 'sonnet', schema: CURE_SCHEMA })
      } catch (e) {
        return { pr, rescue, age, cure: null, reage: null, failure: { stage: 'cure', message: e.message } }
      }
      if (!cure.committed) {
        log(`PR #${pr.number}: cure produced no committed change — keeping age verdict (dirty).`)
        return { pr, rescue, age, cure, reage: null, failure: null }
      }
      try {
        const reage = await agent(reagePrompt(pr, age.worktree_path, age.scope), { label: `reage:${pr.number}`, phase: 'Re-age', agentType: 'reviewer', model: 'opus', schema: AGE_SCHEMA })
        return { pr, rescue, age, cure, reage, failure: null }
      } catch (e) {
        return { pr, rescue, age, cure, reage: null, failure: { stage: 'reage', message: e.message } }
      }
    },

    // Finalize — push, stamp the marker, rerun flaky CI.
    async ({ pr, rescue, age, cure, reage, failure }) => {
      if (failure) return { pr, rescue, age, cure, reage, finalize: null, failure }
      try {
        const finalize = await agent(
          finalizePrompt(pr, age.worktree_path, (rescue && rescue.infra_flake_run_ids) || [], isDirtyChain({ age, cure, reage })),
          { label: `finalize:${pr.number}`, phase: 'Finalize', model: 'haiku', schema: FINALIZE_SCHEMA },
        )
        return { pr, rescue, age, cure, reage, finalize, failure: null }
      } catch (e) {
        return { pr, rescue, age, cure, reage, finalize: null, failure: { stage: 'finalize', message: e.message } }
      }
    },
  )
}

// ---- Report ----
phase('Report')
const rescued = chainResults.filter(Boolean).map((r) => {
  const { pr, rescue, age, cure, reage, finalize, failure } = r
  let status
  let reason
  if (failure) { status = 'failed'; reason = `${failure.stage}: ${failure.message}` }
  else if (isDirtyChain({ age, cure, reage })) { status = 'dirty'; reason = 'medium+ findings remain after cure budget' }
  else status = 'clean'
  return {
    number: pr.number,
    title: pr.title,
    url: pr.url,
    status,
    reason,
    restacked: rescue ? rescue.restacked === true : false,
    melted: rescue ? rescue.melted === true : false,
    fixes: (rescue && rescue.fixes) || [],
    age_mode: age ? age.mode : null,
    age_scope: age ? age.scope : null,
    cured: Boolean(cure && cure.committed),
    pushed: Boolean(finalize && finalize.pushed),
    marker_updated: Boolean(finalize && finalize.marker_updated),
    ci_reruns: (finalize && finalize.reruns_triggered) || [],
    unresolved_threads: pr.unresolved_threads || 0,
  }
})

const results = [
  ...rescued,
  ...fresh.map((f) => ({ number: f.number, status: f.status, reason: f.reason })),
  ...skipped.map((s) => ({ number: s.number, status: s.status, reason: s.reason })),
]

const summary = { clean: 0, dirty: 0, fresh: 0, failed: 0, skipped: 0 }
for (const r of results) summary[r.status] = (summary[r.status] || 0) + 1
log(`Report: ${results.length} PR(s) — clean:${summary.clean} dirty:${summary.dirty} fresh:${summary.fresh} failed:${summary.failed} skipped:${summary.skipped}`)

const threadsPending = rescued.filter((r) => r.unresolved_threads > 0).map((r) => r.number)
if (threadsPending.length) log(`Unresolved review threads on PR(s) ${threadsPending.join(', ')} — run /affinage to triage them.`)

return { results, summary }
