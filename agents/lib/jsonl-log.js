'use strict';
// jsonl-log.js — shared fail-open JSONL append + size-based rotation, mirroring
// the pattern in turn-budget-guard.js's writeDecision/rotateLogIfLarge (which
// still holds its own copy) so tool-reroute and permission-log can log
// decisions the same way: mkdir 0o700, append 0o600, rotate to a single `.1`
// generation past maxBytes. Observability must never affect enforcement, so
// every failure here is swallowed.

const fs = require('fs');
const path = require('path');

// Matches a credential-shaped token so command/reason strings never persist
// a live secret to disk. Captures the leading marker (kept) and redacts the
// rest of the token.
const SECRET_PATTERN = /(Bearer |ghp_|github_pat_|sk-|[A-Z_]*TOKEN=|[A-Z_]*SECRET=|[A-Z_]*KEY=)\S+/g;

// Redact any credential-shaped substring in `str`, e.g. a Bearer token or an
// inline TOKEN=/SECRET=/KEY= assignment picked up from a logged command.
function scrubSecrets(str) {
  if (typeof str !== 'string') return str;
  return str.replace(SECRET_PATTERN, '$1<redacted>');
}

function rotateIfLarge(file, maxBytes) {
  try {
    if (fs.statSync(file).size > maxBytes) fs.renameSync(file, `${file}.1`);
  } catch {
    /* fail-open */
  }
}

// Append `record` as one JSON line to `${dir}/${file}`, rotating first when
// the file already exceeds maxBytes. Fails open on any error (missing dir
// permissions, disk full, …) — logging must never block the hook.
function appendJsonl(dir, file, record, maxBytes) {
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const full = path.join(dir, file);
    rotateIfLarge(full, maxBytes);
    fs.appendFileSync(full, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  } catch {
    /* fail-open */
  }
}

module.exports = { appendJsonl, scrubSecrets };
