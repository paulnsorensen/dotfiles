// module: call; provides: form, substance, errorText, schemaErrors, data, prompt, redoPrompt, repairPrompt, isWriter, attempt, typed, unwrapEnvelope, wfxCommandOf; requires: none
const form = (msg) => ({ kind: 'form', msg })
// A substance error needs new facts, so the producer redoes the answer.
const substance = (msg) => ({ kind: 'substance', msg })
// Joins the messages of a list of errors into one line.
const errorText = (errors) => errors.map((e) => e.msg).join('; ')
// Mirrors the runtime schema check, so code does not trust the runtime to enforce it.
function schemaErrors(value, schema, path) {
  const is = {
    array: Array.isArray(value),
    integer: Number.isInteger(value),
    boolean: typeof value === 'boolean',
    string: typeof value === 'string',
    object: value !== null && typeof value === 'object' && !Array.isArray(value),
  }
  if (schema.type && !is[schema.type]) return [`${path} must be ${schema.type}`]
  if (schema.enum && !schema.enum.includes(value)) return [`${path} must be one of ${schema.enum.join(', ')}`]
  if (schema.pattern && !new RegExp(schema.pattern).test(value)) return [`${path} must match ${schema.pattern}`]
  const errors = []
  for (const key of schema.required || []) if (!Object.hasOwn(value, key)) errors.push(`${path}.${key} is required`)
  for (const [key, child] of Object.entries(schema.properties || {})) {
    if (Object.hasOwn(value, key)) errors.push(...schemaErrors(value[key], child, `${path}.${key}`))
  }
  if (schema.items) value.forEach((item, i) => errors.push(...schemaErrors(item, schema.items, `${path}[${i}]`)))
  return errors
}
// Escape '<' so untrusted text cannot close the inert-data fence.
const data = (name, value) => `<data name="${name}">\n${JSON.stringify(value, null, 2).replaceAll('<', '\\u003c')}\n</data>`
// PREAMBLE comes first, then the non-empty parts. PREAMBLE resolves at call time.
const prompt = (...parts) => [PREAMBLE, ...parts.filter(Boolean)].join('\n\n')
// A redo asks the producer to fix every listed error in a fresh answer.
const redoPrompt = (original, errors) => `${original}\n\nYour previous answer failed these checks. Fix each one.\n${data('errors', errors.map((e) => e.msg))}`
// A repair asks a formatter to fix only the listed errors in the object.
const repairPrompt = (value, errors) => prompt(
  'You are a formatter. Fix only the listed errors in the object. Copy every other field verbatim. Add no new facts.',
  data('errors', errors.map((e) => e.msg)),
  data('object', value),
)
// A writer call may change the tree, so a throw from it never retries. A reviewer worktree only holds reports.
const isWriter = (opts) => opts.agentType === 'coder' || (opts.isolation === 'worktree' && opts.agentType !== 'reviewer')
// An agent call can throw, for example at the budget ceiling. The throw becomes a value, so the caller decides what to do.
const attempt = async (text, opts) => {
  try {
    return { value: await agent(text, opts), threw: null }
  } catch (e) {
    const message = e && e.message ? e.message : String(e)
    log(`${opts.label}: agent threw: ${message}`)
    return { value: null, threw: message }
  }
}
// One validated agent call: check the answer, then repair form errors or redo substance errors, each up to LIMITS.fixRounds.
// A throw from a read-only call retries once. A throw from a writer call never retries.
// hooks: normalize(value) cleans an answer before the check.
//   expandShas(value, opts) returns a fixed copy of the value, or null, when the check fails once.
//   onWorktree(value, opts) runs for each answer of a call with isolation 'worktree'.
//   nullIsFinal makes a null answer final at once, with no redo.
//   noRedo makes an answer that fails with substance errors final at once. A formatter repair of form errors still runs.
//   retryOnThrow is a flag, or a predicate on the call options, that replaces the default read-only rule.
//   driftOf(before, after, schema) names a decision field that a formatter repair changed, or returns null.
// Returns { value, errors, lost, threw }. lost is 'threw' or 'missing' when the value is null for that reason.
const typed = async (text, opts, check, hooks = {}) => {
  const { normalize = (v) => v, expandShas, onWorktree, nullIsFinal = false, noRedo = false, retryOnThrow, driftOf } = hooks
  const mayRetry = (o) => (typeof retryOnThrow === 'function' ? retryOnThrow(o) : (retryOnThrow ?? !isWriter(o)))
  let sent = { text, opts }
  let { value, threw } = await attempt(sent.text, sent.opts)
  let retried = false
  let expanded = false
  let repairedFrom = null
  let repairErrors = []
  for (let round = 1; ; round++) {
    if (threw != null) {
      if (retried || !mayRetry(sent.opts)) return { value: null, errors: [substance(`agent threw: ${threw}`)], lost: 'threw', threw: true }
      retried = true
      sent = { text: sent.text, opts: { ...sent.opts, label: `${opts.label}:retry${round}` } }
      ;({ value, threw } = await attempt(sent.text, sent.opts))
      continue
    }
    if (value != null) {
      value = normalize(value)
      if (opts.isolation === 'worktree' && onWorktree) onWorktree(value, opts)
    }
    let errors = value == null ? [substance('agent returned no output')] : check(value)
    if (errors.length && expandShas && !expanded && !nullIsFinal && value != null) {
      expanded = true
      const full = await expandShas(value, opts)
      // A repair or redo then starts from the expanded value, so only the remaining errors drive it.
      if (full) {
        value = full
        errors = check(value)
      }
    }
    // A formatter repairs form only. A repair that rewrites a decision field changes the answer, so the producer redoes the call.
    if (driftOf && repairedFrom && value != null) {
      const changed = driftOf(repairedFrom, value, opts.schema)
      if (changed) errors = [substance(`a formatter repair changed ${changed}; fix the original errors yourself`), ...repairErrors.map((e) => substance(e.msg)), ...errors]
    }
    repairedFrom = null
    if (!errors.length) return { value, errors, lost: null, threw: false }
    if (round > LIMITS.fixRounds || (value == null && nullIsFinal)) return { value: null, errors, lost: value == null ? 'missing' : null, threw: false }
    const formOnly = errors.every((e) => e.kind === 'form')
    if (noRedo && !formOnly) return { value: null, errors, lost: value == null ? 'missing' : null, threw: false }
    repairedFrom = formOnly ? value : null
    repairErrors = formOnly ? errors : []
    sent = formOnly
      ? { text: repairPrompt(value, errors), opts: { label: `${opts.label}:repair${round}`, phase: opts.phase, schema: opts.schema, model: 'haiku', effort: 'low', agentType: 'formatter' } }
      : { text: redoPrompt(text, errors), opts: { ...opts, label: `${opts.label}:redo${round}` } }
    ;({ value, threw } = await attempt(sent.text, sent.opts))
  }
}
// A runner can wrap the envelope that wfx printed in a second envelope of its own.
// Returns the innermost envelope: an object whose data is itself an envelope gives that data.
function unwrapEnvelope(value) {
  let env = value
  while (env && typeof env === 'object' && env.data && typeof env.data === 'object' && typeof env.data.ok === 'boolean' && typeof env.data.cmd === 'string') env = env.data
  return env
}
// The wfx command name in a command line: the word after the last 'wfx '. A wfx envelope carries it as cmd.
function wfxCommandOf(command) {
  const names = [...String(command).matchAll(/(?:^|[\s|&;(])wfx\s+([a-z][a-z-]*)/g)].map((m) => m[1])
  return names.length ? names[names.length - 1] : ''
}
