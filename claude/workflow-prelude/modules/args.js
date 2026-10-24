// module: args; provides: parseArgs; requires: none
// Builds a parser for workflow args. spec is {usage, key?, fields}. A bare string argument goes to the field named by key. A string that starts with "{" parses as JSON. A field is {type, required?, default?} with a type of:
//   string (pattern?), boolean, integer (min?, max?, clamp?), enum (values), array (items?: 'string' | 'integer', max?)
// The parser returns {opts} or {error, blocked}. The error text ends with the exact call shape from spec.usage.
function parseArgs(spec) {
  const fields = spec.fields || {}
  const usage = spec.usage || ''
  const fail = (errors) => {
    const error = `${errors.join('; ')}. Call shape: ${usage}`
    return { error, blocked: { status: 'blocked', error, usage } }
  }
  const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)
  const checkField = (name, field, value, opts, errors) => {
    if (field.type === 'string') {
      if (typeof value !== 'string') return void errors.push(`${name} must be a string`)
      if (field.pattern && !new RegExp(field.pattern).test(value)) return void errors.push(`${name} does not match ${field.pattern}`)
      opts[name] = value
    } else if (field.type === 'boolean') {
      if (typeof value !== 'boolean') return void errors.push(`${name} must be a boolean`)
      opts[name] = value
    } else if (field.type === 'integer') {
      if (!Number.isInteger(value)) return void errors.push(`${name} must be an integer`)
      let n = value
      if (field.clamp) {
        if (field.min !== undefined) n = Math.max(field.min, n)
        if (field.max !== undefined) n = Math.min(field.max, n)
      } else if ((field.min !== undefined && n < field.min) || (field.max !== undefined && n > field.max)) {
        return void errors.push(`${name} must be an integer${field.min !== undefined ? ` from ${field.min}` : ''}${field.max !== undefined ? ` to ${field.max}` : ''}`)
      }
      opts[name] = n
    } else if (field.type === 'enum') {
      if (!field.values.includes(value)) return void errors.push(`${name} must be one of ${field.values.join(', ')}`)
      opts[name] = value
    } else if (field.type === 'array') {
      if (!Array.isArray(value)) return void errors.push(`${name} must be an array`)
      if (field.max !== undefined && value.length > field.max) return void errors.push(`${name} holds at most ${field.max} items`)
      const itemType = field.items
      if (itemType && value.some((v) => (itemType === 'integer' ? !Number.isInteger(v) : typeof v !== itemType))) return void errors.push(`${name} must hold only ${itemType} items`)
      opts[name] = value
    } else {
      errors.push(`${name} has the unknown field type ${field.type}`)
    }
  }
  return (raw) => {
    let input = raw
    if (typeof raw === 'string') {
      if (raw.trim().startsWith('{')) {
        try {
          input = JSON.parse(raw)
        } catch (e) {
          return fail([`args is not valid JSON (${e.message})`])
        }
      } else if (spec.key) {
        input = { [spec.key]: raw }
      } else {
        return fail(['args must be an object'])
      }
    }
    if (input === undefined || input === null) input = {}
    if (!isObj(input)) return fail(['args must be an object'])
    const errors = []
    for (const key of Object.keys(input)) if (!Object.hasOwn(fields, key)) errors.push(`unknown key "${key}"`)
    const opts = {}
    for (const [name, field] of Object.entries(fields)) {
      const value = input[name]
      if (value === undefined) {
        if (field.required) errors.push(`${name} is required`)
        else if (field.default !== undefined) opts[name] = field.default
        continue
      }
      checkField(name, field, value, opts, errors)
    }
    return errors.length ? fail(errors) : { opts }
  }
}
