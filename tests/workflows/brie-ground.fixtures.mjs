// Fixture builders for the brie-ground offline tests. Each builder returns a value that satisfies the workflow schema.

export const claim = (text, extra = {}) => ({ claim: text, source_kind: 'web', citation: 'https://example.com', confidence: 'speculating', decision_critical: true, ...extra })
export const evidence = (id, route, claims) => ({ sub_question_id: id, route, claims, gaps: [], sources_unavailable: [] })
export const sub = (n, extra = {}) => ({ question: `sub q${n}`, route: 'web', depth: 'shallow', why: '', ...extra })
export const plan = (subs) => ({ restated_question: 'q', loaded_assumptions: [], sub_questions: subs, stop_criteria: 's' })
export const cached = (text) => ({ claim: text, citation: 'notes.md:1', confidence: 'speculating', decision_critical: true })
export const recall = (claims = [], fully = false) => ({ reusable_claims: claims, docs: claims.length ? ['notes.md'] : [], fully_answers: fully, coverage_note: '' })

const spec = { goal: '', what_to_build: '', success_criterion: '', expected_signal: '', language_or_stack: '', est_loc: 0 }
export const synth = (extra = {}) => ({
  answer: 'a', confidence: 'speculating', confidence_justification: '', evidence_table: [], conflicts: [], open_questions: [],
  prototype_decision: { warranted: false, rationale: '', spec }, report_path: '', recommended_next_step: '', ...extra,
})
export const warranted = { warranted: true, rationale: 'r', spec: { ...spec, goal: 'g', what_to_build: 'w' } }
export const prototype = { built: true, scratch_dir: '/tmp/x', what_ran: 'r', observed: 'o', conclusion: 'c', confirms_grounded_answer: 'confirms', cleaned_up: true }

// The JSON lines in a prompt data block whose id starts with prefix.
export const dataItems = (prompt, prefix) => prompt.split('\n').filter((l) => l.startsWith(`{"id":"${prefix}`)).map((l) => JSON.parse(l))
export const verdicts = (prompt, verdict) => ({ verdicts: dataItems(prompt, 'C-').map(({ id }) => ({ id, verdict, note: '', corrected_claim: '' })) })

export function respondWith({ recallOut = recall(), subs = [sub(1)], claims = [], verdict = 'supported', synthOut = synth() } = {}) {
  return ({ opts, prompt }) => {
    const l = opts.label
    if (l === 'recall') return recallOut
    if (l === 'plan') return plan(subs)
    if (l.startsWith('web:')) return evidence(l.slice(4), 'web', claims)
    if (l.startsWith('verify:')) return verdicts(prompt, verdict)
    if (l === 'synthesize') return synthOut
    throw new Error(`unexpected agent ${l}`)
  }
}
