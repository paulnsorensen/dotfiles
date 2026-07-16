export const meta = {
  name: 'ultracook-fleet',
  description:
    'Parallelize the easy-cheese pipeline (cook→press→age→cure→age→cure→age) across an entire hallouminate roadmap. Each roadmap goal becomes a git branch + PR, driven by milknado as the execution engine.',
  whenToUse:
    'Run many approved specs through the full ultracook pipeline concurrently. Each roadmap goal must be file-disjoint. Requires milknado installed and a hallouminate roadmap under .hallouminate/wiki/roadmaps/<slug>/.',
  phases: [
    { title: 'Import', detail: 'Seed milknado ROADMAP + GOAL nodes from the hallouminate roadmap wiki' },
    { title: 'Partition', detail: 'One worktree+branch per goal; build isolated 7-phase TASK chains into each partition db' },
    { title: 'Run', detail: 'Spin off one detached milknado run per partition; drain concurrently' },
    { title: 'Monitor', detail: 'Poll each partition until all nodes DONE or FAILED' },
    { title: 'Harvest', detail: 'Export execution state back to the wiki; open one PR per partition branch' },
  ],
}

// Tracked source: claude/workflows/ultracook-fleet.js in the dotfiles repo.
// Deployed to ~/.claude/workflows/ as a symlink by claude/.sync (the `configs`
// array). Invoked as `/ultracook-fleet <roadmap-slug>`; `args` is the slug.
//
// Architecture (spec: ultracook-fleet):
//   - MCP calls (milknado MCP tools) live INSIDE agent() calls — MCP is
//     undefined in Workflow script scope (node-runner.js:9-14).
//   - The .js script owns deterministic fan-out, sequencing, and schema.
//   - Sub-coordinators are detached `milknado run --project-root <wt>` CLI
//     processes, launched via Bash inside agents.
//   - Each partition = one roadmap GOAL → isolated worktree/branch/db.
//   - 7 phase-nodes per partition in a linear prerequisite chain (leaf→root):
//     cook ← press ← age ← cure ← age ← cure ← age
//     (children = prerequisites in milknado; a node dispatches once children DONE)
//   - Phase skills run single-phase (non-auto); the milknado DAG sequences them.
//   - Workers root at their node worktree (engine.py:258 sets cwd=node wt).
//   - Harness-driven verify-until-green (loop.py:207-232); no worker self-verify.
//   - Zero milknado source patches required.

// ── schemas ───────────────────────────────────────────────────────────────────

const IMPORT_SCHEMA = {
  type: 'object',
  required: ['roadmap_node_id', 'goal_node_ids', 'goal_slugs', 'goal_descriptions'],
  properties: {
    roadmap_node_id: { type: 'integer' },
    goal_node_ids: { type: 'array', items: { type: 'integer' } },
    goal_slugs: { type: 'array', items: { type: 'string' } },
    goal_descriptions: { type: 'array', items: { type: 'string' } },
    created: { type: 'integer' },
    reused: { type: 'integer' },
  },
}

const PARTITION_SCHEMA = {
  type: 'object',
  required: ['goal_id', 'goal_slug', 'worktree_path', 'branch', 'phase_node_ids'],
  properties: {
    goal_id: { type: 'integer' },
    goal_slug: { type: 'string' },
    worktree_path: { type: 'string' },
    branch: { type: 'string' },
    phase_node_ids: {
      type: 'object',
      description: 'Map of phase name to node id: cook, press, age1, cure1, age2, cure2, age3',
    },
    error: { type: 'string' },
  },
}

const LAUNCH_SCHEMA = {
  type: 'object',
  required: ['goal_slug', 'launched', 'pid_or_detail'],
  properties: {
    goal_slug: { type: 'string' },
    launched: { type: 'boolean' },
    pid_or_detail: { type: 'string' },
    run_list_count: { type: 'integer' },
  },
}

const POLL_SCHEMA = {
  type: 'object',
  required: ['goal_slug', 'all_done', 'node_statuses'],
  properties: {
    goal_slug: { type: 'string' },
    all_done: { type: 'boolean' },
    any_failed: { type: 'boolean' },
    node_statuses: { type: 'object' },
    run_count: { type: 'integer' },
  },
}

const HARVEST_SCHEMA = {
  type: 'object',
  required: ['goal_slug', 'pr_url', 'files_written'],
  properties: {
    goal_slug: { type: 'string' },
    pr_url: { type: 'string' },
    files_written: { type: 'integer' },
    files_created: { type: 'integer' },
    pr_error: { type: 'string' },
  },
}

// ── prompt builders ────────────────────────────────────────────────────────────

function importPrompt(roadmapSlug, projectRoot) {
  return [
    'You are importing a hallouminate roadmap into milknado.',
    '',
    `Roadmap slug: ${roadmapSlug}`,
    `Project root: ${projectRoot}`,
    '',
    'Steps:',
    '1. Call milknado_roadmap_import(roadmap_slug="' +
      roadmapSlug +
      '", project_root="' +
      projectRoot +
      '")',
    '   This returns { roadmap_node_id, goal_node_ids, created, reused }.',
    '2. For each goal_node_id, call milknado_get_node(node_id=<id>, project_root="' +
      projectRoot +
      '")',
    '   to retrieve the goal description. Derive the goal_slug from the description:',
    '   lowercase, spaces → hyphens, strip non-alphanumeric except hyphens, max 40 chars.',
    '3. Return IMPORT with roadmap_node_id, goal_node_ids (same order as import result),',
    '   goal_slugs (derived slug for each goal, same order), and goal_descriptions',
    '   (the raw description string for each goal, same order — used to locate goals in partition dbs).',
    '',
    'Confidence: certain (you are reading from the live db).',
  ].join('\n')
}

function partitionPrompt(goal, roadmapSlug, projectRoot, mainBranch) {
  // goal = { id, slug, description }
  // Build the 7-phase chain root-to-leaf (each node's parent_id = its upstream phase).
  // In milknado, children = prerequisites: a node is ready when ALL children are DONE.
  // Chain (leaf→root, dispatched leaf-first): cook ← press ← age1 ← cure1 ← age2 ← cure2 ← age3
  // Build order: age3 first (under partition_goal_id), then each child under the previous.
  const branch = `uf/${goal.slug}`
  const wt = `${projectRoot}/.worktrees/uf-${goal.slug}`
  return [
    'You are building one partition for an ultracook-fleet run.',
    '',
    `Goal id: ${goal.id}`,
    `Goal slug: ${goal.slug}`,
    `Goal description: ${goal.description}`,
    `Project root (primary): ${projectRoot}`,
    `Partition worktree path: ${wt}`,
    `Partition branch: ${branch}`,
    `Base branch: ${mainBranch}`,
    '',
    'Steps (if any step fails, set error in the return and stop):',
    '',
    '1. Create the worktree+branch:',
    `   git -C ${projectRoot} worktree add -b ${branch} ${wt} ${mainBranch}`,
    '   If the worktree already exists (branch already exists or path exists), skip creation.',
    '',
    '2. Copy the milknado.toml worker config into the partition worktree:',
    `   cp ${projectRoot}/claude/workflows/ultracook-fleet-worker.toml ${wt}/milknado.toml`,
    '   (This sets execution_agent and quality_gates for the partition.)',
    '',
    '3. Initialize milknado db in the partition worktree:',
    `   milknado init --project-root ${wt}`,
    '   If .milknado/milknado.db already exists, this is a no-op.',
    '',
    '4. Import the roadmap into the PARTITION db (explicit project_root for isolation):',
    `   milknado_roadmap_import(roadmap_slug="${roadmapSlug}", project_root="${wt}")`,
    '   This seeds ROADMAP + GOAL nodes into the isolated partition db.',
    '',
    '5. Find the goal node id in the PARTITION db:',
    `   milknado_todo_tree(project_root="${wt}") — find the GOAL node whose description`,
    `   matches "${goal.description}" (or is closest to it).`,
    '   Store this as partition_goal_id.',
    '',
    '6. Build the 7-phase linear prerequisite chain (root-to-leaf order, no move_node needed):',
    '   In milknado, children = prerequisites. Build from root down so each parent_id is known.',
    '   IMPORTANT: use the PARTITION db (project_root="' + wt + '") for every milknado call.',
    '',
    '   a. age3_id  = milknado_todo_add(description="Run /age ' + goal.slug + '",',
    '        kind="task", flavor="implement", parent_id=partition_goal_id,',
    `        project_root="${wt}")`,
    '   b. cure2_id = milknado_todo_add(description="Run /cure ' + goal.slug + '",',
    '        kind="task", flavor="implement", parent_id=age3_id,',
    `        project_root="${wt}")`,
    '   c. age2_id  = milknado_todo_add(description="Run /age ' + goal.slug + '",',
    '        kind="task", flavor="implement", parent_id=cure2_id,',
    `        project_root="${wt}")`,
    '   d. cure1_id = milknado_todo_add(description="Run /cure ' + goal.slug + '",',
    '        kind="task", flavor="implement", parent_id=age2_id,',
    `        project_root="${wt}")`,
    '   e. age1_id  = milknado_todo_add(description="Run /age ' + goal.slug + '",',
    '        kind="task", flavor="implement", parent_id=cure1_id,',
    `        project_root="${wt}")`,
    '   f. press_id = milknado_todo_add(description="Run /press ' + goal.slug + '",',
    '        kind="task", flavor="implement", parent_id=age1_id,',
    `        project_root="${wt}")`,
    '   g. cook_id  = milknado_todo_add(description="Run /cook ' + goal.slug + '",',
    '        kind="task", flavor="implement", parent_id=press_id,',
    `        project_root="${wt}")`,
    '      cook has no children — it is the leaf and will be dispatched first.',
    '',
    '   Resulting chain (leaf dispatched first):',
    '   cook (leaf) → press → age1 → cure1 → age2 → cure2 → age3 (root under goal)',
    '',
    '7. Return PARTITION with:',
    `   goal_id=${goal.id}, goal_slug="${goal.slug}", worktree_path="${wt}", branch="${branch}",`,
    '   phase_node_ids={ cook: cook_id, press: press_id, age1: age1_id,',
    '     cure1: cure1_id, age2: age2_id, cure2: cure2_id, age3: age3_id }',
    '   If any step failed, set error to the failure message and omit phase_node_ids.',
  ].join('\n')
}

function launchPrompt(partition) {
  return [
    'Launch a detached milknado run for one fleet partition.',
    '',
    `Partition worktree: ${partition.worktree_path}`,
    `Goal slug: ${partition.goal_slug}`,
    `Branch: ${partition.branch}`,
    '',
    'Steps:',
    '1. Run the detached sub-coordinator:',
    `   nohup milknado run --project-root ${partition.worktree_path} > ${partition.worktree_path}/.milknado/run.log 2>&1 &`,
    '   Capture and record the PID.',
    '2. Verify launch: check that the process started (ps -p <pid> -o pid= or similar).',
    '3. Call milknado_run_list(project_root="' +
      partition.worktree_path +
      '", limit=5) to confirm the run is tracked.',
    '4. Return LAUNCH with goal_slug, launched=true (or false on failure), pid_or_detail,',
    '   and run_list_count (number of runs returned by run_list).',
  ].join('\n')
}

function pollPrompt(partition) {
  return [
    'Poll a fleet partition until all nodes are DONE or at least one is FAILED.',
    '',
    `Partition worktree: ${partition.worktree_path}`,
    `Goal slug: ${partition.goal_slug}`,
    '',
    'Steps (repeat until terminal):',
    '1. Call milknado_todo_tree(project_root="' +
      partition.worktree_path +
      '") to get current node statuses.',
    '2. Extract status for each of the 7 phase nodes.',
    '3. If all are "done": return POLL with all_done=true, any_failed=false.',
    '4. If any are "failed" or "blocked": return POLL with all_done=false, any_failed=true.',
    '5. If still "pending" or "in_progress": wait 30 seconds (Bash: sleep 30),',
    '   then repeat from step 1. Poll at most 120 times (~1 hour).',
    '6. Return POLL with goal_slug, all_done, any_failed, node_statuses (map of',
    '   phase-node-id → status string), run_count (from milknado_run_list limit=10).',
    '',
    'Be patient — each phase runs a full easy-cheese pipeline phase and may take minutes.',
    'If the process appears stalled (no status changes for 10 polls), log a warning',
    'but continue polling until the poll cap is reached.',
  ].join('\n')
}

function harvestPrompt(partition, roadmapSlug, projectRoot, mainBranch, isWip) {
  const titlePrefix = isWip ? '[WIP] ' : ''
  return [
    'Harvest one fleet partition: export execution state to the wiki, then open a PR.',
    '',
    `Partition worktree: ${partition.worktree_path}`,
    `Partition branch: ${partition.branch}`,
    `Goal slug: ${partition.goal_slug}`,
    `Primary project root: ${projectRoot}`,
    `Roadmap slug: ${roadmapSlug}`,
    isWip
      ? 'NOTE: This partition did not fully complete — open as a [WIP] draft PR so reviewers'
      : '',
    isWip
      ? '      know the full cook→…→age chain did not finish (timed out or still in progress).'
      : '',
    '',
    'Steps:',
    '1. Export roadmap state back to the wiki (from the PARTITION db):',
    `   milknado_roadmap_export(roadmap_slug="${roadmapSlug}", project_root="${partition.worktree_path}")`,
    '   This writes execution state (branch, statuses) to the wiki goal files.',
    '',
    '2. Push the partition branch to the remote:',
    `   git -C ${partition.worktree_path} push -u origin ${partition.branch}`,
    '   If the push fails (e.g. nothing to push, no commits beyond main), note the error',
    '   and proceed — some goals may produce no code changes.',
    '',
    '3. Open a PR for this partition:',
    `   gh pr create --base ${mainBranch} --head ${partition.branch}${isWip ? ' --draft' : ''}`,
    `     --title "${titlePrefix}feat(${partition.goal_slug}): easy-cheese pipeline via ultracook-fleet"`,
    `     --body "Automated by /ultracook-fleet roadmap=${roadmapSlug} goal=${partition.goal_slug}.`,
    `            Phases: cook→press→age→cure→age→cure→age (all run as milknado tasks)."`,
    '   Capture the PR URL from the output.',
    '',
    '4. Return HARVEST with goal_slug, pr_url (empty string if PR creation failed),',
    '   files_written, files_created (from the roadmap_export result), and pr_error',
    '   (if PR creation failed).',
  ].join('\n')
}

// ── helpers ────────────────────────────────────────────────────────────────────

function slugify(text) {
  return (text || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40)
}

// ── run ────────────────────────────────────────────────────────────────────────

const rawArg =
  typeof args === 'string'
    ? args
    : args && typeof args === 'object' && typeof args.roadmap_slug === 'string'
      ? args.roadmap_slug
      : ''
const roadmapSlug = rawArg.trim()

if (!roadmapSlug) {
  log('No roadmap slug provided. Usage: /ultracook-fleet <roadmap-slug>')
  return { error: 'No roadmap slug provided. Usage: /ultracook-fleet <roadmap-slug>' }
}

// Resolve project root: this workflow runs in the primary checkout.
// The PRIMARY clone is the one that has .claude/workflows/ symlinked.
// We detect it by finding the git toplevel from the current working directory.
const projectRoot = await agent(
  [
    'Find the primary git checkout root for this project.',
    'Run: git rev-parse --show-toplevel',
    'Return a JSON object with one field: { "root": "<absolute path>" }',
    'Return ONLY the JSON object, nothing else.',
  ].join('\n'),
  { schema: { type: 'object', required: ['root'], properties: { root: { type: 'string' } } }, label: 'detect-root' },
)
const PROJECT_ROOT = (projectRoot && projectRoot.root) || '.'
const MAIN_BRANCH = 'main'

log(`Fleet root: ${PROJECT_ROOT} | roadmap: ${roadmapSlug}`)

// ── Phase: Import ──────────────────────────────────────────────────────────────

phase('Import')
log(`Importing roadmap "${roadmapSlug}" from hallouminate wiki into milknado...`)

const importResult = await agent(importPrompt(roadmapSlug, PROJECT_ROOT), {
  schema: IMPORT_SCHEMA,
  label: 'roadmap-import',
})

if (!importResult || !Array.isArray(importResult.goal_node_ids) || !importResult.goal_node_ids.length) {
  return { error: `Roadmap import failed or returned no goals for slug "${roadmapSlug}".`, importResult }
}
const goals = importResult.goal_node_ids.map((id, i) => ({
  id,
  slug: slugify((importResult.goal_slugs || [])[i] || `goal-${id}`),
  description: (importResult.goal_descriptions || importResult.goal_slugs || [])[i] || `goal-${id}`,
}))

log(`Imported ${goals.length} goal(s): ${goals.map((g) => g.slug).join(', ')}`)

// ── Phase: Partition ───────────────────────────────────────────────────────────

phase('Partition')
log(`Building ${goals.length} partition(s)...`)

const partitions = await parallel(
  goals.map(
    (goal) => () =>
      agent(partitionPrompt(goal, roadmapSlug, PROJECT_ROOT, MAIN_BRANCH), {
        schema: PARTITION_SCHEMA,
        label: `partition-${goal.slug}`,
      }),
  ),
)

const goodPartitions = partitions.filter((p) => p && !p.error)
const badPartitions = partitions.filter((p) => !p || p.error)

if (badPartitions.length) {
  log(`WARNING: ${badPartitions.length} partition(s) failed to initialize:`)
  for (const p of badPartitions) {
    if (p) log(`  ${p.goal_slug}: ${p.error}`)
  }
}

if (!goodPartitions.length) {
  return { error: 'All partitions failed to initialize.', partitions }
}

log(`Partitions ready: ${goodPartitions.map((p) => p.goal_slug).join(', ')}`)

// ── Phase: Run ────────────────────────────────────────────────────────────────

phase('Run')
log(`Launching ${goodPartitions.length} detached milknado sub-coordinator(s)...`)

const launches = await parallel(
  goodPartitions.map(
    (partition) => () =>
      agent(launchPrompt(partition), {
        schema: LAUNCH_SCHEMA,
        label: `launch-${partition.goal_slug}`,
      }),
  ),
)

const launchedPartitions = goodPartitions.filter((_p, i) => launches[i] && launches[i].launched)
const failedLaunches = launches.filter((l) => !l || !l.launched)

if (failedLaunches.length) {
  log(`WARNING: ${failedLaunches.length} sub-coordinator(s) failed to launch.`)
  for (const l of failedLaunches) {
    if (l) log(`  ${l.goal_slug}: ${l.pid_or_detail}`)
  }
}

if (!launchedPartitions.length) {
  return { error: 'No sub-coordinators launched.', launches }
}

log(`Sub-coordinators running: ${launchedPartitions.map((p) => p.goal_slug).join(', ')}`)

// ── Phase: Monitor ────────────────────────────────────────────────────────────

phase('Monitor')
log(`Monitoring ${launchedPartitions.length} partition(s) until all drain...`)

// Poll partitions concurrently; each agent waits until its partition is terminal.
const pollResults = await parallel(
  launchedPartitions.map(
    (partition) => () =>
      agent(pollPrompt(partition), {
        schema: POLL_SCHEMA,
        label: `poll-${partition.goal_slug}`,
      }),
  ),
)

const allDoneCount = pollResults.filter((r) => r && r.all_done).length
const anyFailedCount = pollResults.filter((r) => r && r.any_failed).length
const timedOutCount = pollResults.filter((r) => r && !r.all_done && !r.any_failed).length
log(`Monitor complete: ${allDoneCount} fully done, ${anyFailedCount} with failures, ${timedOutCount} timed-out/in-progress.`)
// Surface run.log paths for failed partitions so the operator can diagnose without
// knowing the worktree layout by hand.
pollResults.forEach((r, i) => {
  if (r && (r.any_failed || !r.all_done)) {
    const wt = launchedPartitions[i].worktree_path
    const label = r.any_failed ? 'FAILED' : 'WIP/TIMED-OUT'
    log(`  ${label} ${r.goal_slug}: run log at ${wt}/.milknado/run.log`)
    if (r.any_failed && r.node_statuses) {
      const failed = Object.entries(r.node_statuses)
        .filter(([, s]) => s === 'failed' || s === 'blocked')
        .map(([id]) => id)
      if (failed.length) log(`    failing nodes: ${failed.join(', ')}`)
    }
  }
})
// ── Phase: Harvest ────────────────────────────────────────────────────────────

phase('Harvest')
log(`Harvesting ${launchedPartitions.length} partition(s) and opening PRs...`)

// Harvest all partitions, including ones that partially failed (partial code may
// still be worth a PR for review). Timed-out partitions get a [WIP] title so
// reviewers know the full chain did not complete.
const harvests = await parallel(
  launchedPartitions.map(
    (partition, i) => () => {
      const pollResult = pollResults[i]
      const isWip = !pollResult || !pollResult.all_done
      return agent(harvestPrompt(partition, roadmapSlug, PROJECT_ROOT, MAIN_BRANCH, isWip), {
        schema: HARVEST_SCHEMA,
        label: `harvest-${partition.goal_slug}`,
      })
    },
  ),
)

const prs = harvests.filter((h) => h && h.pr_url).map((h) => `${h.goal_slug}: ${h.pr_url}`)
const prErrors = harvests.filter((h) => h && h.pr_error).map((h) => `${h.goal_slug}: ${h.pr_error}`)

log(`PRs opened (${prs.length}/${launchedPartitions.length}):`)
for (const pr of prs) log(`  ${pr}`)
if (prErrors.length) {
  log(`PR errors (${prErrors.length}):`)
  for (const e of prErrors) log(`  ${e}`)
}

return {
  roadmap_slug: roadmapSlug,
  goals_total: goals.length,
  partitions_initialized: goodPartitions.length,
  partitions_launched: launchedPartitions.length,
  partitions_fully_done: allDoneCount,
  partitions_with_failures: anyFailedCount,
  partitions_timed_out: timedOutCount,
  prs_opened: prs.length,
  prs,
  pr_errors: prErrors,
  harvests,
}
