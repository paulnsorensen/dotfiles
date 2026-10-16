// module: ground; provides: GROUNDING_SCHEMA, GROUND_RESEARCH_SCHEMA, GROUND_RULES, researchRule, BRIE_GROUND_MAX_AGENTS, brieGround; requires: mold
// The Ground contract: wiki decisions and prior research, each tied to the item refs it constrains.
const GROUNDING_SCHEMA = {
  type: 'object',
  required: ['decisions', 'prior_research'],
  properties: {
    decisions: { type: 'array', items: {
      type: 'object',
      required: ['statement', 'kind', 'citation', 'items'],
      properties: {
        statement: { type: 'string', description: 'The recorded decision or constraint, in one sentence' },
        kind: { type: 'string', enum: DECISION_KINDS },
        citation: { type: 'string', description: 'wiki path:line' },
        items: { type: 'array', items: { type: 'string' }, description: 'refs of the items it constrains; empty when it is repo-wide' },
      },
    } },
    prior_research: { type: 'array', items: {
      type: 'object',
      required: ['path', 'topic', 'items'],
      properties: {
        path: { type: 'string', description: 'absolute path of the research document' },
        topic: { type: 'string' },
        items: { type: 'array', items: { type: 'string' } },
      },
    } },
  },
}
// A Ground stage that also collects open external questions for brie-ground.
const GROUND_RESEARCH_SCHEMA = {
  ...GROUNDING_SCHEMA,
  required: [...GROUNDING_SCHEMA.required, 'research_questions'],
  properties: {
    ...GROUNDING_SCHEMA.properties,
    research_questions: { type: 'array', items: { type: 'string' }, description: 'external-fact questions that the inputs, the code, the wiki, and prior research leave open; empty when they settle the work' },
  },
}
// The Ground explorer rules. Each workflow adds its subject line and its item data.
const GROUND_RULES = [
  'Use hallouminate with cwd set to your checkout. Run ground queries for the topics the items share, then read the hits. Cover ADRs and recorded decisions (kind adr), locked contracts and conventions (kind locked), roadmap direction (kind roadmap), gotchas that constrain a fix (kind gotcha), and earlier cheese-board pages under strategy/ (kind strategy).',
  'Return a decision only when a wiki page states it. Cite it as wiki path:line. List the refs of the items it constrains; use an empty list when it is repo-wide. Do not restate an item as a decision.',
  `List prior research: run \`${MOLD} artifact-path research probe\` and list the *.md files in the directory of the returned path, plus any legacy .cheese/research/*.md. Return each document that bears on an item, with its absolute path, its topic, and the item refs.`,
].join('\n')
// The rule for research_questions. max resolves at call time.
const researchRule = (max) => `research_questions: at most ${max} questions about external facts (a library, an API, upstream behavior) that the work needs settled. Ask a question only when the item text, the code, the wiki, and prior research all leave it open. Leave it empty otherwise.`
// Worst case of one brie-ground child (see its fan-out caps): recall 2, plan 2, 3 deep sub-questions x 7, 2 shallow x 3, synthesis 2, prototype 2.
const BRIE_GROUND_MAX_AGENTS = 35
// Runs one brie-ground child, which nests no workflow, and returns { found }, { unsettled }, or { failed }. A capped result also logs and returns its dropped count. workflow and log resolve at call time.
const brieGround = async (question) => {
  let r = null
  try {
    r = await workflow('brie-ground', question)
  } catch (e) {
    log(`brie-ground failed for "${question}": ${e && e.message}`)
  }
  if (!r || r.error || typeof r.answer !== 'string' || !RESEARCH_CONFIDENCE.includes(r.confidence)) return { failed: `research failed: ${question}` }
  const capped = (result, items, max, what) => {
    if (items.length <= max) return result
    log(`brie-ground for "${question}" dropped ${items.length - max} ${what} past the cap of ${max}`)
    return { ...result, dropped: items.length - max }
  }
  // A dont_know answer may be blank. It keeps at most 2 follow-ups, so one child cannot flood the open questions.
  if (r.confidence === 'dont_know') {
    const followUps = Array.isArray(r.open_questions) ? r.open_questions.filter((q) => typeof q === 'string' && q.trim()) : []
    return capped({ unsettled: [question, ...followUps.slice(0, 2)] }, followUps, 2, 'follow-up question(s)')
  }
  if (!r.answer.trim()) return { failed: `research failed: ${question}` }
  const evidence = Array.isArray(r.evidence_table) ? r.evidence_table : []
  const citations = evidence.slice(0, 5).map((e) => e && e.citation).filter(Boolean)
  return capped({ found: { question, answer: r.answer, confidence: r.confidence, report_path: typeof r.report_path === 'string' ? r.report_path : '', citations } }, evidence, 5, 'citation row(s)')
}
