#!/usr/bin/env node
// Checks the plain text and the colours of an interactive-system-diagram widget.
// Usage: node check-widget.mjs <file.html>
// Exit 0 when clean. Exit 1 with one `<key> [rule] message → fix` line per finding.
// Exit 2 on a usage or file error.
// Trusted input only: this script runs the widget's inline script. Run it on a file you wrote.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const ANSWER_WORDS = 20;
const SENTENCE_WORDS = 25;
const FIELD_SENTENCES = 6;
const TEXT_RATIO = 4.5;
const EDGE_RATIO = 3;

const TEXT_PAIRS = [
  ['--fg', '--bg'], ['--muted', '--bg'], ['--fg', '--svg-bg'], ['--muted', '--svg-bg'],
  ['--fg', '--ext-fill'], ['--muted', '--ext-fill'],
  ['--fg', '--entry-fill'], ['--muted', '--entry-fill'],
  ['--fg', '--core-fill'], ['--muted', '--core-fill'],
  ['--fg', '--grp-fill'], ['--amber-text', '--amber-fill'],
  ['--text-accent', '--bg-accent'], ['--text-success', '--bg-success'],
  ['--text-warning', '--bg-warning'], ['--text-danger', '--bg-danger'],
  ['--text-secondary', '--surface-1'],
];
const EDGE_PROPS = ['--edge-v', '--edge-p', '--edge-u', '--edge-m'];

const findings = [];
const report = (key, rule, message, fix) => findings.push(`${key} [${rule}] ${message} → ${fix}`);

const file = process.argv[2];
if (!file) {
  console.error('usage: check-widget.mjs <file.html>');
  process.exit(2);
}
let html;
try {
  html = readFileSync(file, 'utf8');
} catch (error) {
  console.error(`check-widget: cannot read ${file}: ${error.code || error.message}`);
  process.exit(2);
}

function loadModel(source) {
  const noop = () => {};
  const stub = () => ({
    dataset: {}, style: {}, children: [], textContent: '', disabled: false,
    setAttribute: noop, addEventListener: noop, append: noop,
  });
  const document = {
    getElementById: stub, createElement: stub, querySelectorAll: () => [], addEventListener: noop,
  };
  const context = vm.createContext({ document }, { microtaskMode: 'afterEvaluate' });
  vm.runInContext(source, context, { timeout: 1000 });
  return vm.runInContext('({ TABS, G, N, E, T, W })', context);
}

// A period after a common abbreviation does not end a sentence.
const SENTENCE_END = /(?<!\b(?:e\.g|i\.e|etc|vs|approx|U\.S|U\.K|Mr|Ms|Dr)\.)(?<=[.!?])\s+/i;
const sentencesOf = text => text.split(SENTENCE_END).map(s => s.trim()).filter(Boolean);
const wordsOf = sentence => sentence.split(/\s+/).filter(w => /[\p{L}\p{N}]/u.test(w)).length;

// Plain fields render as strings. Report any other value; skip a missing field.
function* textFields(value, key) {
  if (typeof value === 'string') yield [key, value];
  else if (value !== undefined) {
    report(key, 'plain-words', `the field is ${typeof value}, not a string`, 'write the field as one plain string');
  }
}

function checkPlain(key, text) {
  const sentences = sentencesOf(text);
  if (sentences.length > FIELD_SENTENCES) {
    report(key, 'sentence-count', `${sentences.length} sentences, limit ${FIELD_SENTENCES}`,
      `cut the field to ${FIELD_SENTENCES} sentences or fewer`);
  }
  for (const sentence of sentences) {
    const count = wordsOf(sentence);
    if (count > SENTENCE_WORDS) {
      report(key, 'plain-words', `${count} words in one sentence, limit ${SENTENCE_WORDS}`,
        'split the sentence into shorter sentences');
    }
  }
}

function checkText(model) {
  for (const [tabKey, tabValue] of Object.entries(model.TABS)) {
    for (const [key, text] of textFields(tabValue.a, `TABS.${tabKey}.a`)) {
      const sentences = sentencesOf(text);
      if (sentences.length > 1) {
        report(key, 'answer-words', `${sentences.length} sentences in the answer, limit 1`,
          'state the conclusion in one sentence');
      }
      for (const sentence of sentences) {
        const count = wordsOf(sentence);
        if (count > ANSWER_WORDS) {
          report(key, 'answer-words', `${count} words in the answer, limit ${ANSWER_WORDS}`,
            'state the conclusion in 20 words or fewer');
        }
      }
    }
    for (const [key, text] of textFields(tabValue.x, `TABS.${tabKey}.x`)) checkPlain(key, text);
  }
  const plain = [['G', 'p'], ['N', 'p'], ['E', 'p'], ['T', 'p'], ['T', 'why']];
  for (const [table, field] of plain) {
    for (const [name, entry] of Object.entries(model[table])) {
      for (const [key, text] of textFields(entry[field], `${name}.${field}`)) checkPlain(key, text);
    }
  }
  model.W.forEach((step, index) => {
    for (const [key, text] of textFields(step.cap, `W[${index}]`)) checkPlain(key, text);
  });
}

function parseVars(block) {
  const vars = {};
  for (const match of block.matchAll(/(--[\w-]+)\s*:\s*([^;}]+)/g)) vars[match[1]] = match[2].trim();
  return vars;
}

function parseColour(value) {
  if (!value) return null;
  const hex = value.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if (hex) {
    const digits = hex[1].length === 3 ? [...hex[1]].map(d => d + d).join('') : hex[1];
    return [0, 2, 4].map(i => parseInt(digits.slice(i, i + 2), 16));
  }
  const rgb = value.match(/^rgb\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)\s*\)$/i);
  return rgb ? [Number(rgb[1]), Number(rgb[2]), Number(rgb[3])] : null;
}

function luminance([r, g, b]) {
  const linear = [r, g, b].map(c => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function ratio(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// Follow var(--name) references, with a depth limit against cycles.
function resolveColour(vars, name) {
  let value = vars[name];
  for (let depth = 0; depth < 10 && value; depth++) {
    const ref = value.match(/^var\(\s*(--[\w-]+)\s*(?:,\s*([^)]*))?\)$/);
    if (!ref) break;
    value = vars[ref[1]] ?? ref[2]?.trim();
  }
  return value;
}

function checkContrast(css) {
  const darkMatch = css.match(/@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)\s*\{\s*[^{}]*:root[^{}]*\{([^}]*)\}/);
  const rootMatch = css.replace(darkMatch ? darkMatch[0] : '', '').match(/[^{}]*:root[^{}]*\{([^}]*)\}/);
  if (!rootMatch) {
    report('light', 'contrast', 'no :root block, so no colour is checked', 'define the theme properties in :root');
    return;
  }
  if (!darkMatch) {
    report('dark', 'contrast', 'no dark block found, so no dark colour is checked',
      'add @media (prefers-color-scheme: dark) { :root { ... } }');
  }
  const light = parseVars(rootMatch[1]);
  const schemes = { light };
  if (darkMatch) schemes.dark = { ...light, ...parseVars(darkMatch[1]) };
  for (const [scheme, vars] of Object.entries(schemes)) {
    const where = scheme === 'dark' ? 'the dark block' : ':root';
    const test = (fg, bg, min) => {
      const a = parseColour(resolveColour(vars, fg)), b = parseColour(resolveColour(vars, bg));
      if (!a || !b) {
        report(`${scheme}:${fg}/${bg}`, 'contrast', 'unchecked, a colour is missing or not a hex or rgb() value',
          `set ${fg} and ${bg} to hex or rgb() values in ${where}, or give the var() a hex fallback`);
        return;
      }
      const value = ratio(a, b);
      if (value < min) {
        report(`${scheme}:${fg}/${bg}`, 'contrast', `${value.toFixed(2)}:1, limit ${min}:1`,
          `change ${fg} or ${bg} in ${where}`);
      }
    };
    for (const [fg, bg] of TEXT_PAIRS) test(fg, bg, TEXT_RATIO);
    for (const edge of EDGE_PROPS) test(edge, '--svg-bg', EDGE_RATIO);
  }
}

const scriptMatch = html.match(/<script\b[^>]*>([\s\S]*?)<\/script>/i);
if (scriptMatch) {
  try {
    checkText(loadModel(scriptMatch[1]));
  } catch (error) {
    report('script', 'load', `the widget script fails to run: ${error.message}`, 'fix the script error, or remove DOM calls that check-widget does not stub');
  }
} else {
  report('script', 'load', 'no inline script found', 'add the widget script');
}
checkContrast([...html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)].map(m => m[1]).join('\n'));

if (findings.length) {
  console.log(findings.join('\n'));
  process.exit(1);
}
