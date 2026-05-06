// DISABLED — kept in tree for history. Not registered in claude/settings.json.
// Patterns were over-aggressive (false positives on commit heredocs, gh api,
// tail -c, etc.). Re-enable by adding a PreToolUse Bash entry pointing
// hook-runner.js at this file.

const INSTALL_PATTERNS = [
  { pattern: /\bnpm\s+install\b/, msg: 'npm install' },
  { pattern: /\byarn\s+add\b/, msg: 'yarn add' },
  { pattern: /\bpnpm\s+(add|install)\b/, msg: 'pnpm add/install' },
  { pattern: /\bpip3?\s+install\b/, msg: 'pip install' },
  { pattern: /\bgo\s+get\b/, msg: 'go get' },
  { pattern: /\bcargo\s+add\b/, msg: 'cargo add' },
];

const LEGACY_TOOLS = [
  { pattern: /^\s*(grep|egrep|fgrep)\b/, msg: 'Use cheese-flow:cheez-search for code/content search.' },
  { pattern: /^\s*sed\b/, msg: 'Use cheese-flow:cheez-write or the Edit tool.' },
  { pattern: /\bsed\s+-[^|]*i/, msg: 'Use cheese-flow:cheez-write or the Edit tool.' },
  { pattern: /^\s*awk\b/, msg: 'Use cheese-flow:cheez-write or the Edit tool.' },
  { pattern: /^\s*find\b/, msg: 'Use cheese-flow:cheez-search or the Glob tool.' },
];

const DEP_CACHES = [
  /\.cargo\/registry/,
  /node_modules\//,
  /\.pnpm-store/,
  /site-packages\//,
  /\.venv\/lib\//,
  /\/go\/pkg\/mod\//,
  /GOPATH.*pkg\/mod/,
  /\.m2\/repository\//,
  /\.gradle\/caches\//,
  /\.gem\//,
  /vendor\/bundle\//,
];

const DOC_GREP = [
  { gen: /cargo\s+doc\b/, label: 'cargo doc' },
  { gen: /go\s+doc\b/, label: 'go doc' },
  { gen: /pydoc3?\b/, label: 'pydoc' },
  { gen: /python3?\s+-c\s+.*help\s*\(/, label: 'python help()' },
  { gen: /ri\s+/, label: 'ri (Ruby)' },
];

const HEURISTIC_TRIGGERS = [
  { pattern: /\bcd\s+\S+\s*&&\s*git\b/, msg: 'Use /wt-git or git -C <path> instead.' },
  { pattern: /gh\s+pr\s+create\b[^|]*--body\s*"\$\(cat\b/, msg: 'Use MCP create_pull_request, or write the body to a temp file and pass --body-file.' },
  { pattern: /\bgh\s+[^|]+\|\s*jq\b/, msg: 'Use gh --jq instead of piping to jq.' },
  { pattern: /\bgh\s+[^|]+\|\s*(grep|head|tail|awk|sed|cut|sort|wc)\b/, msg: 'Use gh --json/--jq instead of piping gh output through shell text filters.' },
  { pattern: /(^|\s)([A-Z_]+=.+\s+)*gh\s+api\b/, msg: 'Use /gh or the GitHub MCP instead of raw gh api calls.' },
  { pattern: /\bgit\s+add\b[^|]*&&\s*git\s+commit\b/, msg: 'Use /commit for staging and committing.' },
  { pattern: /\bgit\s+commit\b.*\$\(/, msg: 'Use /commit for commit messages instead of command substitution.' },
];

const PYTHON_AS_TOOL = [
  {
    pattern: /\|\s*python3?\s+.*\bjson[.\s]*(load|loads|dump|dumps)\b/,
    msg: 'Use jq instead of piping to python for JSON processing.',
  },
  {
    pattern: /python3?\s+(-c\s+['"$]|<<).*\bjson[.\s]*(load|loads)\b.*\bopen\s*\(/s,
    msg: 'Use jq instead of python for reading and parsing JSON files.',
  },
  {
    pattern: /python3?\s+(-c\s+['"$]|<<).*\bjson[.\s]*(dump|dumps)\b.*\bopen\s*\(.*['"]\s*w/s,
    msg: 'Use the Write tool or jq for writing JSON transforms.',
  },
  {
    pattern: /python3?\s+-m\s+json\.tool\b/,
    msg: 'Use jq for JSON pretty-printing.',
  },
  {
    pattern: /python3?\s+(-c\s+['"$]|<<).*\bimport\s+re\b.*\b(re\.sub|re\.match|re\.search|re\.findall)\b/s,
    msg: 'Use sd or the Edit tool instead of python regex file manipulation.',
  },
  {
    pattern: /python3?\s+(-c\s+['"$]|<<).*\bimport\s+yaml\b/s,
    msg: 'Use yq instead of python for YAML processing.',
  },
];

function matchInstall(cmd) {
  const match = INSTALL_PATTERNS.find((rule) => rule.pattern.test(cmd));
  if (!match) return null;
  return `Blocked: ${match.msg}. Package installation requires explicit approval.`;
}

function matchLegacyTool(cmd) {
  const match = LEGACY_TOOLS.find((rule) => rule.pattern.test(cmd));
  if (!match) return null;
  return `Blocked: legacy tool via Bash. ${match.msg}`;
}

function matchFileWrite(cmd) {
  const clean = cmd
    .replace(/[12]?>+\s*\/dev\/(null|stderr|stdout)/g, '')
    .replace(/2>&1/g, '');
  if (/\$TMPDIR|\/private\/tmp\/claude|\/tmp\/claude/.test(cmd)) return null;
  if (/\bcat\s*>>?\s/.test(clean)) return 'Blocked: file creation via cat redirect. Use the Write tool.';
  if (/<<[-~]?\s*['"]?\w+/.test(clean) && />>?\s+\S/.test(clean)) {
    return 'Blocked: file creation via heredoc redirect. Use the Write tool.';
  }
  return null;
}

function matchPythonAsTool(cmd) {
  if (/python3?\s+\//.test(cmd) && !/python3?\s+-[cm]/.test(cmd)) return null;
  if (/\$TMPDIR|\/private\/tmp\/claude|\/tmp\/claude/.test(cmd)) return null;

  const norm = cmd.replace(/\n/g, ' ');
  const match = PYTHON_AS_TOOL.find((rule) => rule.pattern.test(norm));
  return match ? match.msg : null;
}

function matchInlineTest(cmd) {
  if (/python3?\s+-c\s+['"].*\bimport\b.*(?:\bassert\b|print\s*\()/.test(cmd)) return true;
  if (/python3?\s+-c\s+\$'/.test(cmd)) return true;
  if (/python3?\s+-c\s+['"][^'"]*\bimport\b[^'"]*;[^'"]*(?:\bassert\b|print\s*\()/.test(cmd)) return true;
  const norm = cmd.replace(/\n/g, ' ');
  return /cat\s+<<[-~]?\s*['"]?\w+/.test(cmd) && /\bimport\b[\s\S]*(?:\bassert\b|print\s*\()/.test(norm);
}

function matchBruteLookup(cmd) {
  for (const { gen, label } of DOC_GREP) {
    if (gen.test(cmd) && /grep|head|tail/.test(cmd)) {
      return `Blocked: ${label} + grep for symbol lookup. Use /lookup or /fetch.`;
    }
  }
  for (const pattern of DEP_CACHES) {
    if (pattern.test(cmd)) return `Blocked: grepping dependency cache (${cmd.match(pattern)[0]}). Use /lookup or /fetch.`;
  }
  if (/target\/doc\//.test(cmd) && /grep/.test(cmd)) return 'Blocked: grepping generated docs. Use /fetch or /lookup.';
  if (/find\s+.*-exec\s+grep/.test(cmd) || /find\s+.*\|\s*xargs\s+grep/.test(cmd)) {
    return 'Blocked: find + grep chain. Use /trace or /lookup.';
  }
  return null;
}

function matchHeuristic(cmd) {
  const match = HEURISTIC_TRIGGERS.find((rule) => rule.pattern.test(cmd));
  if (!match) return null;
  return `Blocked: triggers Claude Code safety heuristic. ${match.msg}`;
}

const ALL_MATCHERS = [matchInstall, matchBruteLookup, matchLegacyTool, matchFileWrite, matchPythonAsTool, matchHeuristic];

module.exports = {
  hooks: [{
    matcher: (toolName, input) => {
      if (toolName !== 'Bash') return false;
      const cmd = input.command || '';
      if (matchInlineTest(cmd)) return true;
      return ALL_MATCHERS.some((fn) => fn(cmd));
    },
    handler: async (_toolName, input) => {
      const cmd = input.command || '';
      if (matchInlineTest(cmd)) {
        return { result: 'Blocked: python3 -c with test pattern. Use /test-sandbox or write a proper test file.' };
      }
      for (const fn of ALL_MATCHERS) {
        const msg = fn(cmd);
        if (msg) return { result: msg };
      }
      return { result: 'Use the dedicated tool instead of shell commands.' };
    },
  }],
};
