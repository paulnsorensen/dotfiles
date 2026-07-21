import { readFile } from 'node:fs/promises'
import { createContext, Script } from 'node:vm'

const GLOBALS = ['agent', 'parallel', 'pipeline', 'phase', 'log', 'workflow', 'args', 'budget', 'Date', 'Math']
const SUPPORTED_SCHEMA_KEYS = new Set(['type', 'required', 'properties', 'items', 'enum', 'description', 'pattern'])

export class SchemaError extends Error {
  constructor(message) {
    super(message)
    this.name = 'SchemaError'
  }
}

function isType(value, type) {
  if (type === 'array') return Array.isArray(value)
  if (type === 'integer') return Number.isInteger(value)
  if (type === 'null') return value === null
  return type === 'object'
    ? value !== null && typeof value === 'object' && !Array.isArray(value)
    : typeof value === type
}

function validateSchema(schema, path) {
  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    throw new SchemaError(path + ': schema must be an object')
  }

  for (const key of Object.keys(schema)) {
    if (!SUPPORTED_SCHEMA_KEYS.has(key)) {
      throw new SchemaError(path + ': unsupported schema keyword "' + key + '"')
    }
  }

  if (schema.properties) {
    for (const [key, child] of Object.entries(schema.properties)) {
      validateSchema(child, path + '.' + key)
    }
  }
  if (schema.items) validateSchema(schema.items, path + '[]')
}

function validateValue(value, schema, path) {
  if (schema.type && !isType(value, schema.type)) {
    const actual = Array.isArray(value) ? 'array' : typeof value
    throw new SchemaError(path + ': expected ' + schema.type + ', got ' + actual)
  }
  if (schema.pattern && typeof value === 'string' && !new RegExp(schema.pattern).test(value)) {
    throw new SchemaError(path + ': expected to match /' + schema.pattern + '/, got ' + JSON.stringify(value))
  }
  if (schema.enum && !schema.enum.includes(value)) {
    throw new SchemaError(path + ': expected one of ' + schema.enum.join(', ') + ', got ' + JSON.stringify(value))
  }
  if (schema.required) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      throw new SchemaError(path + ': expected object, got ' + (Array.isArray(value) ? 'array' : typeof value))
    }
    for (const key of schema.required) {
      if (!Object.hasOwn(value, key)) throw new SchemaError(path + '.' + key + ': required')
    }
  }
  if (schema.properties && value && typeof value === 'object' && !Array.isArray(value)) {
    for (const [key, child] of Object.entries(schema.properties)) {
      if (Object.hasOwn(value, key)) validateValue(value[key], child, path + '.' + key)
    }
  }
  if (schema.items && Array.isArray(value)) {
    value.forEach((item, index) => validateValue(item, schema.items, path + '[' + index + ']'))
  }
}

export function validate(value, schema, path = '$') {
  validateSchema(schema, path)
  validateValue(value, schema, path)
}

function sandboxDate() {
  function WorkflowDate(...values) {
    if (!new.target) throw new Error('Date() is not available in workflow scripts')
    if (!values.length) throw new Error('argless new Date() is not available in workflow scripts')
    return Reflect.construct(Date, values)
  }

  WorkflowDate.prototype = Date.prototype
  WorkflowDate.now = () => { throw new Error('Date.now() is not available in workflow scripts') }
  WorkflowDate.parse = Date.parse
  WorkflowDate.UTC = Date.UTC
  return WorkflowDate
}

function sandboxMath() {
  return new Proxy(Math, {
    get(target, property, receiver) {
      if (property === 'random') {
        return () => { throw new Error('Math.random() is not available in workflow scripts') }
      }
      return Reflect.get(target, property, receiver)
    },
  })
}

export function createRuntime({ respond = () => { throw new Error('agent fixture missing') }, budgetTotal = null, budgetSpent = 0 } = {}) {
  const trace = { agents: [], phases: [], logs: [] }
  const budget = {
    total: budgetTotal,
    spent: () => budgetSpent,
    remaining: () => budgetTotal == null ? null : Math.max(0, budgetTotal - budgetSpent),
  }

  const globals = {
    agent: async (prompt, opts = {}) => {
      const call = { prompt, opts, index: trace.agents.length }
      trace.agents.push(call)
      const response = await respond(call)
      if (opts.schema) validate(response, opts.schema)
      return response
    },
    parallel: (thunks) => Promise.all(thunks.map(async (thunk) => {
      try {
        return await thunk()
      } catch {
        return null
      }
    })),
    pipeline: (items, ...stages) => Promise.all(items.map(async (original) => {
      let value = original
      try {
        for (const stage of stages) {
          if (value == null) return null
          value = await stage(value, original)
        }
        return value
      } catch {
        return null
      }
    })),
    phase: (name) => trace.phases.push(name),
    log: (message) => trace.logs.push(String(message)),
    workflow: () => { throw new Error('workflow() is not supported in the offline harness') },
    args: undefined,
    budget,
    Date: sandboxDate(),
    Math: sandboxMath(),
  }

  return { globals, trace }
}

export async function loadWorkflow(path) {
  const source = await readFile(path, 'utf8')
  const match = source.match(/^\s*export\s+const\s+meta\s*=\s*(\{[\s\S]*?\n\})\s*;?/m)
  if (!match) throw new Error('workflow meta export not found: ' + path)

  const meta = Function('return (' + match[1] + ')')()
  const body = source.slice(0, match.index) + source.slice(match.index + match[0].length)
  const script = new Script('(async () => {\n' + body + '\n})()', { filename: path })

  return {
    meta,
    run: (overrides = {}) => {
      const sandbox = Object.fromEntries(GLOBALS.map((name) => [name, overrides[name]]))
      const context = createContext(sandbox, { codeGeneration: { strings: false, wasm: false } })
      return script.runInContext(context)
    },
  }
}
