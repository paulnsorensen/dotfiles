// module: fanin; provides: dedupeFindings; requires: none
// Code owns the mechanical fan-in: exact-repeat removal, then a stable order by location.
function dedupeFindings(findings) {
  const byLocation = (a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.dimension.localeCompare(b.dimension) || a.claim.localeCompare(b.claim)
  const seen = new Set()
  return findings.filter((f) => {
    const key = JSON.stringify([f.dimension, f.file, f.line, f.claim])
    if (seen.has(key)) return false
    seen.add(key)
    return true
  }).sort(byLocation)
}
