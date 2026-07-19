export const meta = {
  name: 'default-pipeline',
  description: 'The Sonnet top\'s default for multi-step work: a Fable brain plans, cheap Sonnet agents do the bulk in parallel, a Fable brain judges and synthesizes.',
  phases: [
    { title: 'Plan', detail: 'deep-thinker (fable/xhigh) decomposes the problem into file-disjoint subtasks', model: 'fable' },
    { title: 'Work', detail: 'one sonnet agent per subtask, run as a pipeline (no barrier)' },
    { title: 'Judge', detail: 'deep-thinker (fable/xhigh) judges and synthesizes the worker outputs into one answer', model: 'fable' },
  ],
}

// Tracked source: claude/workflows/default-pipeline.js in the dotfiles repo.
// The named workflow the three-rung routing ladder invokes for multi-step or
// decomposable tasks (spec: orchestration-model-tiering). The brain-and-hands
// split: the deep-thinker brain only reasons (plan/judge) — the SCRIPT does the
// fan-out, because a dispatched agent is a level-1 subagent and cannot spawn.
// The plan and judge stages pass agentType:'deep-thinker' with no call-site
// model/effort, so they inherit the agent's fable/xhigh frontmatter pins; the
// work stage pins sonnet explicitly. Returns to the Sonnet top, which relays to
// the user and owns every follow-up question (subagents/stages cannot ask).
//
// Args: a bare problem string, or { problem: string }.

const PLAN = {
  type: 'object',
  required: ['subtasks'],
  properties: {
    approach: { type: 'string', description: 'One or two sentences on the overall approach.' },
    subtasks: {
      type: 'array',
      description: 'Independently-actionable subtasks; keep them file-disjoint where the work touches code.',
      items: {
        type: 'object',
        required: ['brief'],
        properties: {
          label: { type: 'string', description: 'Short label for progress display.' },
          brief: { type: 'string', description: 'Self-contained instruction a single agent can complete on its own.' },
        },
      },
    },
  },
}

const input = typeof args === 'string' ? { problem: args } : (args || {})
const problem = typeof input.problem === 'string' ? input.problem.trim() : ''

if (!problem) {
  log('No problem provided. Usage: /default-pipeline with args = "<problem>" or { problem: "<problem>" }')
  return { error: 'No problem provided.' }
}

phase('Plan')
const plan = await agent(
  `Plan how to solve this problem. Decompose it into independently-actionable subtasks a fan-out of cheaper agents can each complete on its own; keep them file-disjoint where the work touches code. State the approach, then the subtasks.\n\nProblem:\n${problem}`,
  { agentType: 'deep-thinker', label: 'plan', phase: 'Plan', schema: PLAN },
)

const subtasks = plan && Array.isArray(plan.subtasks) ? plan.subtasks : []
if (!subtasks.length) {
  log('The plan produced no subtasks; returning the plan as the answer.')
  return { plan }
}

phase('Work')
const outputs = await pipeline(
  subtasks,
  (t) => agent(t.brief, { model: 'sonnet', label: t.label || t.brief.slice(0, 40), phase: 'Work' }),
)

phase('Judge')
const results = subtasks
  .map((t, i) => ({ subtask: t.label || t.brief, output: outputs[i] }))
  .filter((r) => r.output != null)

if (!results.length) {
  // Every worker failed — nothing to judge. Skip the expensive Fable/xhigh
  // judge pass (mirrors the no-subtasks short-circuit above).
  log('Every worker produced no output; returning the plan and raw outputs without a judge pass.')
  return { plan, outputs }
}

return await agent(
  `Judge and synthesize the worker outputs into a single answer to the original problem. Weigh them, resolve conflicts, and state one coherent result with the reasoning behind it — do not just concatenate.\n\nOriginal problem:\n${problem}\n\nApproach taken:\n${plan.approach || '(none stated)'}\n\nWorker outputs:\n${JSON.stringify(results, null, 2)}`,
  { agentType: 'deep-thinker', label: 'judge', phase: 'Judge' },
)
