// module: checkpoint; provides: stable, fnv1a, digestOf, matchAnswers, isObject, plain, stateShapeErrors, askCheckpoint, needsInputResult, approveError, digestError, approveUsage; requires: none
// Serializes a value with sorted object keys, so equal values give equal text. A checkpoint question is {id, question, options[], recommended, evidence, initiative?, closed?, kind?}; the next run passes answers back.
function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${stable(value[k])}`).join(',')}}`
  return JSON.stringify(value) ?? 'null'
}

// A 32-bit FNV-1a hash of the text, in 8 hex digits.
function fnv1a(input, seed) {
  let hash = seed >>> 0
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i)
    hash = Math.imul(hash, 16777619) >>> 0
  }
  return hash.toString(16).padStart(8, '0')
}

// A 16-hex digest that detects an edit to the value. It does not stop a hostile caller.
function digestOf(value) {
  const canonical = stable(value)
  return `${fnv1a(canonical, 2166136261)}${fnv1a(canonical, 3735928559)}`
}

// Keys are a question id, the exact question text, or its 1-based number. Returns the answered questions in question order.
function matchAnswers(questions, raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { errors: ['answers must be an object that maps a question or its 1-based number to an answer'], answers: [] }
  const errors = []
  const byIndex = new Map()
  for (const [key, value] of Object.entries(raw)) {
    let index = questions.findIndex((q) => q.id === key)
    if (index < 0) index = /^[1-9][0-9]*$/.test(key) ? Number(key) - 1 : questions.findIndex((q) => q.question === key)
    if (index < 0 || index >= questions.length) errors.push(`answers key ${JSON.stringify(key)} names no open question`)
    else if (typeof value !== 'string' || !value.trim()) errors.push(`the answer to question ${index + 1} must be a non-empty string`)
    else if (byIndex.has(index)) errors.push(`question ${index + 1} has two answers`)
    else byIndex.set(index, value.trim())
  }
  if (!errors.length && !byIndex.size) errors.push('answers holds no answer')
  const answers = [...byIndex.keys()].sort((a, b) => a - b).map((i) => ({ id: questions[i].id, question: questions[i].question, answer: byIndex.get(i) }))
  return { errors, answers }
}

// True for a plain object: not null and not an array.
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)

// A deep copy through JSON, so a checkpoint state holds plain data only.
const plain = (v) => JSON.parse(JSON.stringify(v))

// Checks the shape of a resumed state. shape maps a key to 'array', 'object', 'string', 'boolean', 'integer', a '?' variant of one (null or undefined passes), or {type: 'integer', min, max}. Returns the error texts; none means the shape holds.
function stateShapeErrors(state, shape, prefix = 'args.state') {
  if (!isObject(state)) return [`${prefix} must be an object`]
  const errors = []
  for (const [key, spec] of Object.entries(shape)) {
    const raw = typeof spec === 'string' ? spec : spec.type
    const optional = raw.endsWith('?')
    const type = optional ? raw.slice(0, -1) : raw
    const value = state[key]
    if (optional && value == null) continue
    const where = `${prefix}.${key}`
    if (type === 'array') {
      if (!Array.isArray(value)) errors.push(`${where} must be an array`)
    } else if (type === 'object') {
      if (!isObject(value)) errors.push(`${where} must be an object`)
    } else if (type === 'string') {
      if (typeof value !== 'string') errors.push(optional ? `${where} must be a string or null` : `${where} must be a string`)
    } else if (type === 'boolean') {
      if (typeof value !== 'boolean') errors.push(`${where} must be a boolean`)
    } else if (type === 'integer') {
      const min = typeof spec === 'object' ? spec.min : undefined
      const max = typeof spec === 'object' ? spec.max : undefined
      if (!Number.isInteger(value) || (min !== undefined && value < min) || (max !== undefined && value > max)) {
        const range = min !== undefined && max !== undefined ? ` from ${min} to ${max}` : min !== undefined ? ` of at least ${min}` : max !== undefined ? ` of at most ${max}` : ''
        errors.push(`${where} must be an integer${range}`)
      }
    } else {
      errors.push(`${where} has the unknown shape type ${type}`)
    }
  }
  return errors
}

// Builds a needs-input checkpoint result. A checkpoint with no question cannot resume, so it carries no state or digest. stamp binds the digest to the run.
function askCheckpoint(checkpoint, questions, state, { stamp, usage, extra = {} } = {}) {
  const full = plain({ ...state, checkpoint, questions })
  const resumable = full.questions.length ? { state: full, digest: digestOf({ stamp, checkpoint, state: full }) } : {}
  return { status: 'needs-input', checkpoint, questions: full.questions, ...resumable, usage, ...extra }
}

// Builds a needs-input result for a run that resumes from a plan and its digest. fields come before usage in the result.
function needsInputResult(questions, fields = {}, usage = '') {
  return { status: 'needs-input', questions, ...fields, usage }
}

// The error text when a resumed plan has no approve digest, or an empty string.
function approveError(approve, plan = 'args.plan') {
  return approve ? '' : `${plan} needs args.approve set to the digest that the same result returned`
}

// The error text when approve is not the digest of the value, or an empty string.
function digestError(value, approve, plan = 'args.plan') {
  return digestOf(value) === approve ? '' : `approve does not match the digest of ${plan}; the plan changed after approval`
}

// The usage text for an approval re-run. fields names the argument fields to pass back.
function approveUsage({ fields = 'prs: landing.inputs, plan: landing, approve: digest', land = true, revise = true } = {}) {
  return `To execute, re-run with { ${fields} }.${land ? ' Add land:true to merge.' : ''}${revise ? ` To change the plan first, re-run with the same fields and revise: "<change>".` : ''}`
}
