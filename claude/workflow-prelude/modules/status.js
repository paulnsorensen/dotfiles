// module: status; provides: STATUS, finish, blockedResult, gapField, report, donePayload, runStatus, countStatuses; requires: none
// The status values that a workflow result carries.
const STATUS = Object.freeze({ ok: 'ok', partial: 'partial', blocked: 'blocked', needsInput: 'needs-input', needsApproval: 'needs-approval' })

// A result with a status. base holds the keys that every result of the workflow carries; extra overrides them.
const finish = (status, extra = {}, base = {}) => ({ ...base, status, ...extra })

// A blocked result. The key reason holds the cause.
const blockedResult = (reason, extra = {}, base = {}) => finish(STATUS.blocked, { reason, ...extra }, base)

// The gaps key of a result, or nothing when there is no gap.
const gapField = (gaps) => (gaps.length ? { gaps } : {})

// A report result. The note is logged and returned, as an empty string when absent. log resolves at call time.
function report(status, note, fields = {}) {
  if (note) log(note)
  return { status, note: note || '', ...fields }
}

// A done payload: fields and extra merged, without the keys whose value is undefined.
function donePayload(fields, extra = {}) {
  const merged = { ...fields, ...extra }
  return Object.fromEntries(Object.entries(merged).filter(([, v]) => v !== undefined))
}

// A run is ok only when something was produced, every row has the clean status, nothing stopped it, and no gap remains.
function runStatus({ stopped = '', gaps = [], produced = 0, rows = [], clean = 'clean' } = {}) {
  return stopped || gaps.length || !produced || rows.some((r) => r.status !== clean) ? STATUS.partial : STATUS.ok
}

// Counts the rows for each status. A status in seed starts at its seed count.
function countStatuses(rows, seed = { clean: 0, dirty: 0, failed: 0 }) {
  const counts = { ...seed }
  for (const r of rows) counts[r.status] = (counts[r.status] || 0) + 1
  return counts
}
