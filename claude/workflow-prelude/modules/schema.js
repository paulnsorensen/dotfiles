// module: schema; provides: str, int, bool, strs, ints, text, oneOf, list, obj, CHECK_KINDS, ADVICE_VERDICTS, FIX_STATUSES, PHASE_STATUSES, FINDING_SEVERITIES, FIX_COSTS; requires: none
// Schema builders: one constant per shape, so a contract reads as data.
const str = { type: 'string' }
const int = { type: 'integer' }
const bool = { type: 'boolean' }
const strs = { type: 'array', items: { type: 'string' } }
const ints = { type: 'array', items: { type: 'integer' } }
const text = (description) => ({ type: 'string', description })
const oneOf = (values) => ({ type: 'string', enum: values })
const list = (items) => ({ type: 'array', items })
const obj = (properties) => ({ type: 'object', required: Object.keys(properties), properties })
// Closed sets that more than one workflow shares.
const CHECK_KINDS = ['command', 'test', 'inspection', 'ci']
const ADVICE_VERDICTS = ['approve', 'revise', 'stop']
const FIX_STATUSES = ['fixed', 'partial', 'blocked']
const PHASE_STATUSES = ['ok', 'partial', 'blocked']
const FINDING_SEVERITIES = ['blocker', 'high', 'medium', 'low']
const FIX_COSTS = ['contained', 'moderate', 'sprawling', 'n/a']
