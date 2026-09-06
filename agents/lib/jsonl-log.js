'use strict';
// jsonl-log.js — shared fail-open JSONL append + size-based rotation, mirroring
// the pattern in turn-budget-guard.js's writeDecision/rotateLogIfLarge (which
// still holds its own copy) so tool-reroute and permission-log can log
// decisions the same way: mkdir 0o700, append 0o600, rotate to a single `.1`
// generation past maxBytes. Observability must never affect enforcement, so
// every failure here is swallowed.

const fs = require('fs');
const path = require('path');

const MAX_STRING_LENGTH = 500;

// Redact credential-shaped assignments, bearer values, token arguments, and
// common token prefixes. The replacer below applies this at the write boundary.
function scrubSecrets(str) {
  if (typeof str !== 'string') return str;
  let result = str;
  result = result.replace(
    /((?:[A-Za-z_][A-Za-z0-9_]*(?:TOKEN|SECRET|KEY|PASSWORD)|TOKEN|SECRET|KEY|PASSWORD|API[-_]?KEY)\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s;&|]+)/gi,
    '$1<redacted>',
  );
  result = result.replace(
    /((?:--?)(?:token|secret|password|api[-_]?key)(?:=|\s+))(?:"[^"]*"|'[^']*'|[^\s;&|]+)/gi,
    '$1<redacted>',
  );
  result = result.replace(/(\bBearer\s+)(?:"[^"]*"|'[^']*'|\S+)/gi, '$1<redacted>');
  return result.replace(/(ghp_|github_pat_|sk-)[^\s'";&|]+/gi, '$1<redacted>');
}

function privateDirectory(dir) {
  try {
    const stat = fs.lstatSync(dir);
    return stat.isDirectory() && !stat.isSymbolicLink() && (stat.mode & 0o077) === 0;
  } catch {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const stat = fs.lstatSync(dir);
    return stat.isDirectory() && !stat.isSymbolicLink() && (stat.mode & 0o077) === 0;
  }
}

function privateFile(file) {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() && !stat.isSymbolicLink() && (stat.mode & 0o077) === 0;
  } catch {
    return true;
  }
}

function rotateIfLarge(file, maxBytes) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0) return false;
    if (stat.size <= maxBytes) return true;
    const rotated = `${file}.1`;
    if (!privateFile(rotated)) return false;
    fs.renameSync(file, rotated);
    return true;
  } catch {
    return false;
  }
}

// Append one bounded, sanitized JSON line. Existing paths must be private and
// regular; logging fails open when a path is unsafe.
function appendJsonl(dir, file, record, maxBytes) {
  let fd = null;
  try {
    if (!privateDirectory(dir)) return;
    const full = path.join(dir, file);
    const flags = fs.constants.O_WRONLY |
      fs.constants.O_APPEND |
      fs.constants.O_CREAT |
      fs.constants.O_NOFOLLOW |
      fs.constants.O_NONBLOCK;
    const replacer = (_key, value) => (
      typeof value === 'string' ? scrubSecrets(value).slice(0, MAX_STRING_LENGTH) : value
    );
    const line = `${JSON.stringify(record, replacer)}\n`;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      fd = fs.openSync(full, flags, 0o600);
      const stat = fs.fstatSync(fd);
      if (!stat.isFile() || (stat.mode & 0o077) !== 0) return;
      if (attempt === 0 && stat.size > maxBytes) {
        fs.closeSync(fd);
        fd = null;
        if (!rotateIfLarge(full, maxBytes)) return;
        continue;
      }
      fs.writeSync(fd, line);
      return;
    }
  } catch {
    /* fail-open */
  } finally {
    if (fd !== null) {
      try { fs.closeSync(fd); } catch { /* fail-open */ }
    }
  }
}

module.exports = { appendJsonl, scrubSecrets };
