// module: checkpoint; provides: stable, fnv1a, digestOf, matchAnswers; requires: none
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
