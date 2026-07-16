export const meta = {
  name: 'curd-flock',
  description:
    'Fan worktree-isolated coders over N file-disjoint tasks, taste-test each against a read-only reviewer, and correct on revise (bounded rounds) — never merges or commits to main.',
  phases: [
    { title: 'Implement', detail: 'one coder per task in an isolated git worktree, branch from origin/main' },
    { title: 'Review', detail: 'read-only reviewer over each worktree diff (drift/readability/scope, production path, wired callers)' },
    { title: 'Correct', detail: 'bounded corrective coder pass in the same worktree on any revise verdict, then re-review once' },
    { title: 'Report', detail: 'barrier synthesis of per-task status + worktree/branch handoff' },
  ],
}

// Tracked source: claude/workflows/curd-flock.js in the dotfiles repo.
// Canonicalizes a worktree-isolated coder fan-out used ad-hoc in three prior
// one-off Workflow scripts (rennet-easy-wins, ship-three-ready-units,
// manifest-flock). Convergence: all three fan coder agent() calls with
// isolation:'worktree' over file-disjoint tasks and never push/PR/commit to
// main from inside the workflow — durability is the returned branch, not a
// remote ref. This script follows rennet-easy-wins's shape most closely (the
// only one of the three with a review + bounded-correction loop) and adds the
// re-review-after-correction step and the corrective-round cap explicitly.
//
// Args: { tasks: [{ slug, brief, files? }], correctiveRounds? }
//   - tasks MUST be file-disjoint (declare `files` to get the overlap check —
//     it's advisory: an overlap logs a warning but does not block the run).
//   - correctiveRounds defaults to 1: on a 'revise' verdict, one corrective
//     coder pass runs in the SAME worktree, then the reviewer re-checks once;
//     if still 'revise' and rounds remain, repeat up to the cap.
//
// This workflow never merges, commits to main, pushes, or opens a PR — it
// hands back worktree paths + branch names for the orchestrator to carry
// forward (matches ship-three-ready-units' and rennet-easy-wins' contract of
// leaving publish/push decisions to the caller).

const input = typeof args === 'string' ? (() => { try { return JSON.parse(args) } catch (e) { log(`args was a string but not valid JSON (${e.message}) — treating as no tasks`); return {} } })() : args || {}
const TASKS = Array.isArray(input.tasks) ? input.tasks : []
const CORRECTIVE_ROUNDS = Number.isInteger(input.correctiveRounds) && input.correctiveRounds >= 0 ? input.correctiveRounds : 1

if (!TASKS.length) {
  log('No tasks provided. Usage: /curd-flock with args = { tasks: [{ slug, brief, files? }], correctiveRounds? }')
  return { error: 'No tasks provided.' }
}

// ---- file-disjoint check (advisory — logs, never blocks) ----
function warnOnFileOverlap(tasks) {
  for (let i = 0; i < tasks.length; i++) {
    const a = tasks[i]
    if (!Array.isArray(a.files) || !a.files.length) continue
    for (let j = i + 1; j < tasks.length; j++) {
      const b = tasks[j]
      if (!Array.isArray(b.files) || !b.files.length) continue
      const overlap = a.files.filter((f) => b.files.includes(f))
      if (overlap.length) {
        log(`WARNING: tasks '${a.slug}' and '${b.slug}' declare overlapping files: ${overlap.join(', ')} — tasks must be file-disjoint`)
      }
    }
  }
}
warnOnFileOverlap(TASKS)

// ---- duplicate-slug guard (fail-fast — same branch would collide) ----
function findDuplicateSlugs(tasks) {
  const seen = new Set()
  const dupes = new Set()
  for (const t of tasks) {
    if (seen.has(t.slug)) dupes.add(t.slug)
    seen.add(t.slug)
  }
  return [...dupes]
}
const duplicateSlugs = findDuplicateSlugs(TASKS)
if (duplicateSlugs.length) {
  log(`Duplicate task slug(s): ${duplicateSlugs.join(', ')} — slugs must be unique (branch curd/<slug> would collide)`)
  return { error: `Duplicate task slug(s): ${duplicateSlugs.join(', ')}` }
}

// ---- shared git/isolation contract handed to every coder ----
const ISO = (branch) => `
## Isolation contract (read first)
- You are running in a FRESH, ISOLATED git worktree dedicated to this one task. Other tasks run concurrently in their own worktrees — never reach outside your scope.
- First command: \`git checkout -B ${branch} origin/main\` — start from a clean origin/main base on your own branch.
- Work ONLY this task. Do NOT implement sibling tasks. Do NOT touch files outside the declared scope.
- Do NOT push. Do NOT open a PR. Do NOT run \`git fetch\`/\`pull\`. Commit locally on ${branch} only.
- Final commit: \`git add -A && git commit\` with a Conventional Commits subject. No flair, no emojis in the commit message.
- Honesty (Rule 9): if a gate fails or you skipped something, say so in your digest — never report done on partial work.
`

const CODER_SCHEMA = {
  type: 'object',
  required: ['slug', 'branch', 'status', 'summary', 'files_changed', 'verification', 'committed', 'worktree_path'],
  properties: {
    slug: { type: 'string' },
    branch: { type: 'string' },
    status: { type: 'string', enum: ['done', 'blocked'] },
    summary: { type: 'string', description: 'what changed, 1-3 sentences' },
    files_changed: { type: 'array', items: { type: 'string' } },
    verification: { type: 'string', description: 'exact gate command + result, or why no automated gate applies' },
    committed: { type: 'boolean' },
    commit_sha: { type: 'string' },
    worktree_path: { type: 'string', description: 'absolute path of the worktree this task ran in — a corrective pass cds here instead of creating a new worktree' },
    notes: { type: 'string', description: 'caveats, anything a reviewer must know' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['slug', 'verdict', 'lenses', 'issues'],
  properties: {
    slug: { type: 'string' },
    verdict: { type: 'string', enum: ['pass', 'revise'] },
    lenses: {
      type: 'array',
      items: {
        type: 'object',
        required: ['lens', 'verdict'],
        properties: {
          lens: { type: 'string', enum: ['drift', 'readability', 'scope', 'production-path', 'wired-callers'] },
          verdict: { type: 'string', enum: ['pass', 'revise'] },
          note: { type: 'string' },
        },
      },
    },
    issues: { type: 'array', items: { type: 'string' } },
    recommendation: { type: 'string' },
  },
}

const CORRECT_SCHEMA = {
  type: 'object',
  required: ['slug', 'branch', 'status', 'summary', 'committed'],
  properties: {
    slug: { type: 'string' },
    branch: { type: 'string' },
    status: { type: 'string', enum: ['fixed', 'partial', 'blocked'] },
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    verification: { type: 'string' },
    committed: { type: 'boolean' },
    notes: { type: 'string' },
  },
}

const branchFor = (slug) => `curd/${slug}`

function buildCoderPrompt(t) {
  const branch = branchFor(t.slug)
  return `You are a TDD-disciplined coder implementing ONE file-disjoint task in a fan-out batch.

Task: ${t.slug}
Branch: ${branch}  (fork point: origin/main)
${t.files && t.files.length ? `Scope (edit ONLY these): ${t.files.join(', ')}\n` : ''}
Instruction (authoritative):
${t.brief}

${ISO(branch)}

## How to work
1. \`git checkout -B ${branch} origin/main\`.
2. Read the in-scope files (use tilth/serena MCP, not host Read/grep) before changing anything.
3. Make the minimal change that satisfies the instruction. No scope creep, no speculative extras — every changed line traces to the ask.
4. Verify with the project's relevant gate(s). Read the FULL output before claiming. If no automated gate applies, say so explicitly.
5. Commit on ${branch} (Conventional Commits, no flair). Do NOT push.
6. Report \`worktree_path\`: the absolute path of this worktree (\`git rev-parse --show-toplevel\`) — a corrective pass will cd into it later instead of creating a new worktree.
7. Return the structured digest. If anything was skipped or a gate failed, set status:blocked and explain — do not fake completion.`
}

function buildReviewerPrompt(t, branch, impl) {
  return `You are a read-only reviewer running a taste-test over one freshly-implemented task.

Branch under review: ${branch}
The diff is: \`git diff origin/main...${branch}\`  (read-only git only — NEVER checkout, edit, or modify anything; other branches are being built concurrently in other worktrees).

What it was supposed to do:
${t.brief}

Coder's self-report: ${JSON.stringify({ status: impl.status, summary: impl.summary, files_changed: impl.files_changed, verification: impl.verification, notes: impl.notes })}

## Lenses (judge each pass | revise)
- drift: the diff actually implements the task's intent (not an adjacent or weaker thing).
- readability: minimal, clean, matches surrounding code style; nothing speculative.
- scope: only files traceable to the task changed; no scope creep, no unrelated edits, no orphaned cruft.
- production-path: the change is reachable on the real code path (wired in), not merely asserted in prose or a test that manufactures the state.
- wired-callers: any changed signature/export has its callers updated; nothing left calling a stale shape.

Return the structured verdict (one entry per lens above). Overall verdict = revise if any lens is revise; else pass. Be specific in issues[] (cite file:line from the diff).`
}

function buildCorrectivePrompt(t, worktreePath, branch, review) {
  return `You are a coder applying a BOUNDED corrective pass to your own branch after a taste-test returned "revise".

Worktree: ${worktreePath}  (the SAME worktree the implementation ran in — already checked out on ${branch} with the prior commit)
${t.files && t.files.length ? `Scope (edit ONLY these): ${t.files.join(', ')}\n` : ''}
Original instruction:
${t.brief}

Taste-test findings to fix:
${JSON.stringify({ issues: review.issues, lenses: review.lenses, recommendation: review.recommendation })}

## How to work
1. \`cd ${worktreePath}\` — do NOT create a new worktree or checkout ${branch} elsewhere; it is already checked out here.
2. Address ONLY the taste-test findings — do not re-architect, do not expand scope.
3. Re-verify with the project's relevant gate(s). Read full output.
4. Commit the fix on ${branch} (Conventional Commits, no flair). Do NOT push.
5. Return the structured digest. status:fixed only if every finding is resolved; status:partial otherwise (explain what remains).`
}

// ---- run: implement -> review -> (bounded correct + re-review) per task, pipelined ----
phase('Implement')
log(`Fanning ${TASKS.length} task(s): ${TASKS.map((t) => t.slug).join(', ')} (correctiveRounds=${CORRECTIVE_ROUNDS})`)

const results = await pipeline(
  TASKS,

  (t) => {
    const branch = branchFor(t.slug)
    return agent(buildCoderPrompt(t), {
      label: `implement:${t.slug}`, phase: 'Implement', agentType: 'coder',
      isolation: 'worktree', schema: CODER_SCHEMA,
    }).then((impl) => ({ t, branch, impl }))
  },

  ({ t, branch, impl }) => {
    if (!impl || impl.status !== 'done' || !impl.committed) {
      return { t, branch, impl, review: { slug: t.slug, verdict: 'revise', lenses: [], issues: ['implement stage did not complete or did not commit'], recommendation: 'human follow-up' }, rounds: 0 }
    }
    return agent(buildReviewerPrompt(t, branch, impl), {
      label: `review:${t.slug}`, phase: 'Review', agentType: 'reviewer', effort: 'high', schema: REVIEW_SCHEMA,
    }).then((review) => ({ t, branch, impl, review, rounds: 0 }))
  },

  async ({ t, branch, impl, review, rounds }) => {
    let corrections = []
    let curReview = review
    let round = rounds
    while (curReview && curReview.verdict === 'revise' && round < CORRECTIVE_ROUNDS && impl && impl.status === 'done' && impl.committed) {
      const correction = await agent(buildCorrectivePrompt(t, impl.worktree_path, branch, curReview), {
        label: `correct:${t.slug}:r${round + 1}`, phase: 'Correct', agentType: 'coder',
        schema: CORRECT_SCHEMA,
      })
      corrections.push(correction)
      round++
      if (!correction || !correction.committed) {
        log(`${t.slug}: corrective round ${round} produced ${correction ? 'an uncommitted correction' : 'no correction'} — stopping corrective loop`)
        break
      }
      curReview = await agent(buildReviewerPrompt(t, branch, correction), {
        label: `review:${t.slug}:r${round}`, phase: 'Review', agentType: 'reviewer', effort: 'high', schema: REVIEW_SCHEMA,
      })
    }
    return { t, branch, impl, review: curReview, corrections, rounds: round }
  },
)

phase('Report')
const tasks = results.map((r) => {
  if (!r) return null
  const { t, branch, impl, review, corrections, rounds } = r
  let status
  if (!impl || impl.status !== 'done' || !impl.committed) status = 'failed'
  else if (!review || review.verdict === 'revise') status = 'failed'
  else status = rounds > 0 ? 'revised-clean' : 'clean'
  return {
    slug: t.slug,
    branch,
    status,
    corrective_rounds_used: rounds,
    impl: impl ? { status: impl.status, summary: impl.summary, files_changed: impl.files_changed, verification: impl.verification, committed: impl.committed } : null,
    review: review ? { verdict: review.verdict, lenses: review.lenses, issues: review.issues } : null,
    corrections: corrections && corrections.length ? corrections : undefined,
  }
})

const summary = { clean: 0, 'revised-clean': 0, failed: 0 }
for (const t of tasks) if (t) summary[t.status] = (summary[t.status] || 0) + 1
log(`Report: ${tasks.length} task(s) — clean:${summary.clean} revised-clean:${summary['revised-clean']} failed:${summary.failed}`)

return { tasks, summary }
