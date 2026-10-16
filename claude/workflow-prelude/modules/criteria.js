// module: criteria; provides: norm, blank, refError, checkVerdicts, checkCriteria, CRITERIA_SCHEMA, VERDICT_SCHEMA, VERIFY_BATCH_SCHEMA; requires: call, schema, graph
const norm = (id) => String(id).trim().toUpperCase()
const blank = (value) => typeof value !== 'string' || !value.trim()
// A wrong-case id is a form slip. An unknown id is substance. fixOf maps a ref to its canonical form.
function refError(ref, known, where, fixOf = norm) {
  if (known.includes(ref)) return null
  const fix = fixOf(ref)
  return known.includes(fix) ? form(`${where}: '${ref}' should be '${fix}'`) : substance(`${where}: unknown id '${ref}'`)
}
const VERDICT_SCHEMA = {
  type: 'object',
  required: ['criterion', 'passes', 'evidence', 'tree_clean', 'missing_paths'],
  properties: {
    criterion: { type: 'string' },
    passes: { type: 'boolean' },
    evidence: { type: 'string', description: 'Command run and its observed result' },
    tree_clean: { type: 'boolean', description: 'git status --porcelain printed nothing before the check' },
    missing_paths: { type: 'array', items: { type: 'string' }, description: 'Paths that the check reads and that do not exist in the worktree' },
    guard_blocked: { type: 'boolean', description: 'true when a hook or guard denied the check command, so the check never ran' },
  },
}
const VERIFY_BATCH_SCHEMA = { type: 'object', required: ['verdicts'], properties: { verdicts: { type: 'array', items: VERDICT_SCHEMA } } }
const CRITERIA_SCHEMA = {
  type: 'object',
  required: ['criteria'],
  properties: {
    criteria: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'statement', 'check_kind', 'check'],
        properties: {
          id: { type: 'string', pattern: '^AC-[0-9]+$' },
          statement: { type: 'string' },
          check_kind: { type: 'string', enum: CHECK_KINDS },
          check: { type: 'string' },
        },
      },
    },
  },
}
// One verdict for each criterion in the batch, and no other. With requireAll false, a missing id is no error: the Verify phase fails it as unchecked.
function checkVerdicts(result, batch, { requireAll = true } = {}) {
  const ids = batch.map((ac) => ac.id)
  const errors = []
  result.verdicts.forEach((v, n) => {
    errors.push(refError(v.criterion, ids, `verdicts[${n}].criterion`))
    if (blank(v.evidence)) errors.push(substance(`verdicts[${n}].evidence must name the check run and its result`))
  })
  const seen = result.verdicts.map((v) => norm(v.criterion))
  for (const id of duplicates(seen)) errors.push(substance(`verdicts lists ${id} twice`))
  if (requireAll) for (const id of ids) if (!seen.includes(id)) errors.push(substance(`no verdict for ${id}; run its check`))
  return errors.filter(Boolean)
}
// Exact coverage: one criterion per spec AC id. gate(criterion, where) returns the errors for one check.
// The caller passes its own gate for command safety, so this module stays pure. CI-owned checks skip the gate.
const checkCriteria = (acIds, gate = () => []) => (value) => {
  const errors = []
  const seen = new Set()
  value.criteria.forEach((c, i) => {
    const where = `$.criteria[${i}]`
    const idError = refError(c.id, acIds, `${where}.id`)
    if (idError) errors.push(idError)
    else if (seen.has(c.id)) errors.push(substance(`${where}.id: duplicate id '${c.id}'`))
    seen.add(c.id)
    if (blank(c.statement)) errors.push(substance(`${where}.statement must not be blank`))
    if (blank(c.check)) errors.push(substance(`${where}.check must not be blank`))
    else if (c.check_kind !== 'ci') errors.push(...gate(c, where))
  })
  for (const id of acIds) if (!seen.has(id)) errors.push(substance(`${id} has no criterion`))
  return errors
}
