'use strict';
// tilth-write.js — reroute module: tilth_write API-shape corrector (#345).
//
// ~51 tilth_write calls/month fail on a wrong-shape payload (stale `files`
// top-level array, flat edits without `ops`, `replacement` instead of
// `content`, ops missing the `op` discriminator). The docs already show the
// correct shape, so this is residual wrong-shape model behavior only a
// PreToolUse corrector can catch — DENY with the current shape + a runnable
// example instead of burning the round trip on tilth's server-side error.
//
// Checks are STRUCTURAL only — shapes that are wrong under any tilth version.
// Op NAMES are deliberately not validated against a list: tilth's own error
// teaches unknown ops, and a hardcoded list here would hard-block valid calls
// the day tilth adds an op.

const EXAMPLE = `tilth_write(edits: [{path: "src/a.rs", tag: "1A2B", ops: [{op: "replace", start: 12, end: 14, content: "..."}]}], cwd: "/abs/repo")`;

const FLAT_EDIT_KEYS = ['start', 'end', 'content', 'replacement', 'old', 'new', 'line'];

function reason(problem) {
  return `Blocked: wrong-shape tilth_write call — ${problem}.

Current shape (read first, copy the [path#TAG] and line numbers):
  ${EXAMPLE}

Each edits[] section is {path, tag?, ops}. Line ops ({op: "replace"|"delete", start, end}, {op: "insert_before"|"insert_after", line}) carry integer line numbers from the tagged read and put the new text in "content". {op: "replace_text", old, new} swaps one exact unique string; {op: "create_file", content} seeds a new path (omit tag).`;
}

function isObj(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// The first structural defect in the payload, or null when the shape is
// plausible (tilth still owns full validation — unknown op names, tag drift,
// line bounds all keep their server-side teaching errors).
function shapeProblem(input) {
  if (!isObj(input)) return null;
  if (input.files !== undefined) {
    return 'top-level "files" is the retired API; the sections array is named "edits"';
  }
  if (!Array.isArray(input.edits)) return null; // absent/odd edits → tilth's own error
  for (const edit of input.edits) {
    if (!isObj(edit)) continue;
    if (!Array.isArray(edit.ops)) {
      if (FLAT_EDIT_KEYS.some((k) => edit[k] !== undefined)) {
        return 'edit sections need an "ops" array — flat start/end/content on the section object is not accepted';
      }
      continue; // missing ops with no flat keys → tilth's own error
    }
    for (const op of edit.ops) {
      if (!isObj(op)) continue;
      if (op.op === undefined) {
        return 'every op needs an "op" discriminator (e.g. {op: "replace", start, end, content})';
      }
      if (op.replacement !== undefined) {
        return 'ops carry new text in "content", not "replacement"';
      }
    }
  }
  return null;
}

function detect(toolName, input) {
  if (toolName !== 'mcp__tilth__tilth_write') return null;
  const problem = shapeProblem(input);
  return problem ? { reason: reason(problem) } : null;
}

module.exports = { detect };
